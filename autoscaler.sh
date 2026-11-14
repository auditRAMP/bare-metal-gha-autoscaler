#!/bin/bash
# autoscaler.sh - Intelligent API-driven bare-metal autoscaler

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

if [ -z "$GH_RUNNER_PAT" ]; then
  echo "[Autoscaler] Critical Error: GH_RUNNER_PAT missing. Cannot query GitHub API."
  exit 1
fi

if [ -z "${GH_RUNNER_ORG:-}" ]; then
  echo "[Autoscaler] Critical Error: GH_RUNNER_ORG missing. Cannot target GitHub org."
  exit 1
fi

# shellcheck source=machine-id.sh
source "$SCRIPT_DIR/machine-id.sh"
MACHINE_HASH=$(ensure_machine_id "$SCRIPT_DIR")
RUNNER_NAME_PREFIX="${GH_RUNNER_NAME_PREFIX:-baremetal-runner}"
RUNNER_NAME_PREFIX_MATCH="${RUNNER_NAME_PREFIX}-"
RUNNER_NAME_SUFFIX="-${MACHINE_HASH}"

# Detect OS/arch so we can provision missing runner directories on demand
# when MAX_RUNNERS is hot-reloaded higher than what start.sh initially created.
OS_RAW=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS_RAW" in
  darwin) OS="osx" ;;
  linux)  OS="linux" ;;
  *) echo "[Autoscaler] Unsupported OS: $OS_RAW"; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)   ARCH_NAME="x64" ;;
  arm64|aarch64)  ARCH_NAME="arm64" ;;
  *) echo "[Autoscaler] Unsupported arch: $(uname -m)"; exit 1 ;;
esac
RUNNER_VERSION="2.333.0"
TARBALL_PATH="$SCRIPT_DIR/actions-runner-${OS}-${ARCH_NAME}-${RUNNER_VERSION}.tar.gz"

# ensure_runner_dir <index>
# Returns 0 if actions-runner-<index> is ready, 1 if it could not be provisioned.
ensure_runner_dir() {
  local idx="$1"
  local path="$SCRIPT_DIR/actions-runner-${idx}"
  if [ -d "$path" ] && [ -x "$path/config.sh" ]; then
    return 0
  fi
  if [ ! -f "$TARBALL_PATH" ]; then
    echo "[Autoscaler] Cannot provision Runner $idx: tarball missing at $TARBALL_PATH"
    return 1
  fi
  echo "[Autoscaler] Provisioning missing directory for Runner $idx from tarball..."
  mkdir -p "$path"
  if ! tar xzf "$TARBALL_PATH" -C "$path"; then
    echo "[Autoscaler] Failed to extract tarball for Runner $idx"
    return 1
  fi
  return 0
}

echo "=== Bare-Metal API Autoscaler Started (machine=${MACHINE_HASH}, prefix=${RUNNER_NAME_PREFIX}) ==="
echo "The daemon uses scaler.properties to hot-reload values dynamically."

HEADERS_FILE=$(mktemp -t autoscaler-headers.XXXXXX)
BODY_FILE=$(mktemp -t autoscaler-body.XXXXXX)
trap 'rm -f "$HEADERS_FILE" "$BODY_FILE"' EXIT

# State for error classification + de-duped logging across iterations.
# We classify each tick into one of: ok / network / ratelimit / auth / http / parse.
# Consecutive identical failures are logged once with a count, so a Wi-Fi blip
# does not flood the log with hundreds of identical "Rate Limit" lines.
LAST_ERROR_KIND=""
LAST_ERROR_REPEAT=0
NETWORK_BACKOFF=15

log_status() {
  local kind="$1"; shift
  local msg="$*"
  if [ "$kind" = "$LAST_ERROR_KIND" ]; then
    LAST_ERROR_REPEAT=$((LAST_ERROR_REPEAT + 1))
    # Log on 1st, 2nd, then every 10th repeat so persistent issues stay visible
    # without flooding.
    if [ $LAST_ERROR_REPEAT -le 2 ] || [ $((LAST_ERROR_REPEAT % 10)) -eq 0 ]; then
      echo "[Autoscaler] $msg (repeat #$LAST_ERROR_REPEAT)"
    fi
  else
    if [ -n "$LAST_ERROR_KIND" ] && [ "$kind" = "ok" ]; then
      echo "[Autoscaler] Recovered from '$LAST_ERROR_KIND' after $LAST_ERROR_REPEAT tick(s)."
    fi
    [ "$kind" != "ok" ] && echo "[Autoscaler] $msg"
    LAST_ERROR_KIND="$kind"
    LAST_ERROR_REPEAT=1
    [ "$kind" = "ok" ] && LAST_ERROR_KIND="" && LAST_ERROR_REPEAT=0
  fi
}

while true; do
  declare -a ALL_RUNNING_INDEXES=()
  
  # Hot-Reloading: Read variables dynamically on every tick
  MAX_RUNNERS=5
  MIN_IDLE=1
  POLL_INTERVAL=15
  
  if [ -f "$SCRIPT_DIR/scaler.properties" ]; then
    VAL_MAX=$(grep -E "^MAX_RUNNERS=" "$SCRIPT_DIR/scaler.properties" | cut -d '=' -f2 | tr -d '\r')
    VAL_MIN=$(grep -E "^MIN_IDLE=" "$SCRIPT_DIR/scaler.properties" | cut -d '=' -f2 | tr -d '\r')
    VAL_POLL=$(grep -E "^POLL_INTERVAL=" "$SCRIPT_DIR/scaler.properties" | cut -d '=' -f2 | tr -d '\r')
    
    # Safe regex validation to survive typos
    [[ "$VAL_MAX" =~ ^[0-9]+$ ]] && MAX_RUNNERS=$VAL_MAX
    [[ "$VAL_MIN" =~ ^[0-9]+$ ]] && MIN_IDLE=$VAL_MIN
    [[ "$VAL_POLL" =~ ^[0-9]+$ ]] && POLL_INTERVAL=$VAL_POLL
  fi
  
  # Scan for which shell loops are physically active on this machine
  for i in $(seq 1 $MAX_RUNNERS); do
    if [ -f "$SCRIPT_DIR/runner-${i}.pid" ]; then
      PID=$(cat "$SCRIPT_DIR/runner-${i}.pid")
      if kill -0 $PID 2>/dev/null; then
        ALL_RUNNING_INDEXES+=($i)
      else
        rm -f "$SCRIPT_DIR/runner-${i}.pid"
      fi
    fi
  done
  
  TOTAL_RUNNING=${#ALL_RUNNING_INDEXES[@]}
  
  # Poll GitHub backend. Capture HTTP status + headers separately from the
  # body so we can classify failures honestly (a Wi-Fi blip is not a rate
  # limit, an expired PAT is not a transient error, etc.).
  HTTP_CODE=$(curl -s -L \
    --max-time 20 \
    -o "$BODY_FILE" \
    -D "$HEADERS_FILE" \
    -w "%{http_code}" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_RUNNER_PAT" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/${GH_RUNNER_ORG}/actions/runners")

  if [ "$HTTP_CODE" = "000" ]; then
    # curl could not complete the request: DNS failure, no route to host,
    # connection reset mid-flight, or timeout. Classic Wi-Fi blip signature.
    # Back off exponentially so we do not spam curl during a long outage.
    log_status network "Network unreachable to api.github.com (curl failed). Backing off ${NETWORK_BACKOFF}s."
    sleep $NETWORK_BACKOFF
    NETWORK_BACKOFF=$((NETWORK_BACKOFF * 2))
    [ $NETWORK_BACKOFF -gt 300 ] && NETWORK_BACKOFF=300
    continue
  fi
  NETWORK_BACKOFF=15  # reachable again — reset

  if [ "$HTTP_CODE" = "401" ]; then
    log_status auth "HTTP 401 from GitHub — PAT is invalid or revoked. Sleeping 60s."
    sleep 60
    continue
  fi
  if [ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "429" ]; then
    REMAINING=$(grep -i '^x-ratelimit-remaining:' "$HEADERS_FILE" 2>/dev/null | tr -d '\r' | awk '{print $2}')
    if [ "$REMAINING" = "0" ]; then
      RESET=$(grep -i '^x-ratelimit-reset:' "$HEADERS_FILE" 2>/dev/null | tr -d '\r' | awk '{print $2}')
      NOW=$(date +%s)
      WAIT=$((RESET - NOW + 5))
      [ $WAIT -lt 30 ] && WAIT=30
      log_status ratelimit "GitHub rate limit exhausted. Sleeping ${WAIT}s until window reset."
      sleep $WAIT
    else
      log_status auth "HTTP $HTTP_CODE from GitHub (likely PAT lacks scope or org SSO). Sleeping 60s."
      sleep 60
    fi
    continue
  fi
  if [ "$HTTP_CODE" != "200" ]; then
    log_status http "HTTP $HTTP_CODE from GitHub. Retrying in 15s."
    sleep 15
    continue
  fi

  API_RESPONSE=$(cat "$BODY_FILE")
  if ! echo "$API_RESPONSE" | jq -e '.runners' >/dev/null 2>&1; then
    log_status parse "HTTP 200 but body is not parseable JSON with .runners. Retrying in 15s."
    sleep 15
    continue
  fi

  log_status ok ""

  # Filter down to this machine's runners only: "<prefix>-<N>-<machine-hash>"
  # Count how many are strictly online and idle (busy = false)
  IDLE_COUNT=$(echo "$API_RESPONSE" | jq --arg pfx "$RUNNER_NAME_PREFIX_MATCH" --arg sfx "$RUNNER_NAME_SUFFIX" '[.runners[] | select(.name | startswith($pfx)) | select(.name | endswith($sfx)) | select(.status == "online" and .busy == false)] | length')

  # Count total online runners for this machine only
  ONLINE_COUNT=$(echo "$API_RESPONSE" | jq --arg pfx "$RUNNER_NAME_PREFIX_MATCH" --arg sfx "$RUNNER_NAME_SUFFIX" '[.runners[] | select(.name | startswith($pfx)) | select(.name | endswith($sfx)) | select(.status == "online")] | length')

  # SCALING LOGIC
  
  # SCALE UP: If no idle runners exist on GitHub and we haven't maxed out our process allowance
  if [ "$IDLE_COUNT" -lt "$MIN_IDLE" ] && [ "$TOTAL_RUNNING" -lt "$MAX_RUNNERS" ]; then
    # Find the lowest available index
    for i in $(seq 1 $MAX_RUNNERS); do
      if [[ ! " ${ALL_RUNNING_INDEXES[*]} " =~ " ${i} " ]]; then
        RUNNER_PATH="$SCRIPT_DIR/actions-runner-${i}"

        if ! ensure_runner_dir "$i"; then
          echo "[Autoscaler] Skipping scale-up of Runner $i (provisioning failed). Sleeping before retry."
          sleep 30
          break
        fi

        echo "[Autoscaler] Machine ${MACHINE_HASH} has $IDLE_COUNT idle runner(s). Scaling UP Runner $i..."

        nohup "$SCRIPT_DIR/runner-loop.sh" "$RUNNER_PATH" "$i" > "$SCRIPT_DIR/runner-${i}.log" 2>&1 &
        echo $! > "$SCRIPT_DIR/runner-${i}.pid"

        # Give GitHub a moment to register the new runner before polling again
        sleep 10
        break # Only launch one per loop iteration
      fi
    done
  fi
  
  # SCALE DOWN: If we have excess runners idling, terminate one.
  # Guard on ALL_RUNNING_INDEXES being non-empty — otherwise GitHub-reported
  # idle runners with no local pid file would cause a busy loop of empty
  # "Scaling DOWN Runner " messages.
  if [ "$IDLE_COUNT" -gt "$MIN_IDLE" ] && [ "${#ALL_RUNNING_INDEXES[@]}" -gt 0 ]; then
    # Grab the highest index we are locally running
    IFS=$'\n' sorted=($(sort -nr <<<"${ALL_RUNNING_INDEXES[*]}")); unset IFS
    KILL_INDEX=${sorted[0]}

    echo "[Autoscaler] Machine ${MACHINE_HASH} has $IDLE_COUNT idle runner(s). Scaling DOWN Runner $KILL_INDEX..."

    # Signal the listener to deregister first so GitHub marks it offline.
    # The cmdline is `<script_dir>/actions-runner-N/bin/Runner.Listener run`,
    # so anchor the pkill regex on the full path. Matching from actions-runner-N
    # alone would also hit the same-numbered runner of another fleet on this host.
    pkill -INT -f "$SCRIPT_DIR/actions-runner-${KILL_INDEX}/bin/Runner.Listener" 2>/dev/null || true

    # Give the listener a few seconds to cleanly deregister from GitHub
    sleep 5

    # Stop the supervising loop shell so it does not restart the listener
    if [ -f "$SCRIPT_DIR/runner-${KILL_INDEX}.pid" ]; then
        PID=$(cat "$SCRIPT_DIR/runner-${KILL_INDEX}.pid")
        kill -TERM $PID 2>/dev/null || true
        sleep 1
        kill -9 $PID 2>/dev/null || true
        rm -f "$SCRIPT_DIR/runner-${KILL_INDEX}.pid"
    fi

    # Force-kill any listener still lingering after graceful window.
    # Without this, a SIGKILL on the loop shell would orphan the Runner.Listener
    # child (reparented to init), keeping it online in GitHub's view.
    pkill -9 -f "$SCRIPT_DIR/actions-runner-${KILL_INDEX}/bin/Runner.Listener" 2>/dev/null || true
  fi
  
  # Your total authenticated API capacity is natively 5,000 / hour.
  sleep $POLL_INTERVAL
done
