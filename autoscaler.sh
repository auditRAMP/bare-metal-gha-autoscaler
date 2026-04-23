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
        echo "[Autoscaler] Machine ${MACHINE_HASH} has $IDLE_COUNT idle runner(s). Scaling UP Runner $i..."
        RUNNER_PATH="$SCRIPT_DIR/actions-runner-${i}"
        
        nohup "$SCRIPT_DIR/runner-loop.sh" "$RUNNER_PATH" "$i" > "$SCRIPT_DIR/runner-${i}.log" 2>&1 &
        echo $! > "$SCRIPT_DIR/runner-${i}.pid"
        
        # Give GitHub a moment to register the new runner before polling again
        sleep 10
        break # Only launch one per loop iteration
      fi
    done
  fi
  
  # SCALE DOWN: If we have excess runners idling, terminate one
  if [ "$IDLE_COUNT" -gt "$MIN_IDLE" ]; then
    # Grab the highest index we are locally running
    IFS=$'\n' sorted=($(sort -nr <<<"${ALL_RUNNING_INDEXES[*]}")); unset IFS
    KILL_INDEX=${sorted[0]}
    
    echo "[Autoscaler] Machine ${MACHINE_HASH} has $IDLE_COUNT idle runner(s). Scaling DOWN Runner $KILL_INDEX..."
    
    if [ -f "$SCRIPT_DIR/runner-${KILL_INDEX}.pid" ]; then
        PID=$(cat "$SCRIPT_DIR/runner-${KILL_INDEX}.pid")
        kill -9 $PID 2>/dev/null || true
        rm -f "$SCRIPT_DIR/runner-${KILL_INDEX}.pid"
        
        # Cleanly signal the actual `.NET` listener to deregister and shutdown gracefully
        pkill -INT -f "Runner.Listener .*actions-runner-${KILL_INDEX}" || true
    fi
  fi
  
  # Your total authenticated API capacity is natively 5,000 / hour.
  sleep $POLL_INTERVAL
done
