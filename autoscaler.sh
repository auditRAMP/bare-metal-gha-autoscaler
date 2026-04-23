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
  
  # Poll GitHub backend
  API_RESPONSE=$(curl -s -L \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_RUNNER_PAT" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/${GH_RUNNER_ORG}/actions/runners")

  # Detect rate limiting or API outage
  if ! echo "$API_RESPONSE" | jq -e '.runners' >/dev/null 2>&1; then
      echo "[Autoscaler] API Error or Rate Limit hit. Retrying in 15 seconds..."
      sleep 15
      continue
  fi

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
    # so anchor the pkill regex on the directory/binary path.
    pkill -INT -f "actions-runner-${KILL_INDEX}/bin/Runner.Listener" 2>/dev/null || true

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
    pkill -9 -f "actions-runner-${KILL_INDEX}/bin/Runner.Listener" 2>/dev/null || true
  fi
  
  # Your total authenticated API capacity is natively 5,000 / hour.
  sleep $POLL_INTERVAL
done
