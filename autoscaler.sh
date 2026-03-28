#!/bin/bash
# autoscaler.sh - Intelligent API-driven bare-metal autoscaler

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
MAX_RUNNERS=5
MIN_IDLE=1
GITHUB_ORG="auditRAMP"

if [ -z "$GH_ARC_RUNNERS" ]; then
  echo "[Autoscaler] Critical Error: GH_ARC_RUNNERS missing. Cannot query GitHub API."
  exit 1
fi

echo "=== Bare-Metal API Autoscaler Started ==="
echo "Monitoring $GITHUB_ORG runners up to a maximum capacity of $MAX_RUNNERS."

while true; do
  declare -a ALL_RUNNING_INDEXES=()
  
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
    -H "Authorization: Bearer $GH_ARC_RUNNERS" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners")

  # Detect rate limiting or API outage
  if ! echo "$API_RESPONSE" | jq -e '.runners' >/dev/null 2>&1; then
      echo "[Autoscaler] API Error or Rate Limit hit. Retrying in 15 seconds..."
      sleep 15
      continue
  fi

  # Filter down to exactly the ones named "audit-runner-baremetal-X"
  # Count how many are strictly online and idle (busy = false)
  IDLE_COUNT=$(echo "$API_RESPONSE" | jq '[.runners[] | select(.name | startswith("audit-runner-baremetal-")) | select(.status == "online" and .busy == false)] | length')
  
  # Count total online baremetal runners just for parity logic
  ONLINE_COUNT=$(echo "$API_RESPONSE" | jq '[.runners[] | select(.name | startswith("audit-runner-baremetal-")) | select(.status == "online")] | length')

  # SCALING LOGIC
  
  # SCALE UP: If no idle runners exist on GitHub and we haven't maxed out our process allowance
  if [ "$IDLE_COUNT" -lt "$MIN_IDLE" ] && [ "$TOTAL_RUNNING" -lt "$MAX_RUNNERS" ]; then
    # Find the lowest available index
    for i in $(seq 1 $MAX_RUNNERS); do
      if [[ ! " ${ALL_RUNNING_INDEXES[*]} " =~ " ${i} " ]]; then
        echo "[Autoscaler] GitHub API reports $IDLE_COUNT Idle baremetal runners. Scaling UP Runner $i..."
        RUNNER_PATH="$SCRIPT_DIR/../actions-runner-${i}"
        
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
    
    echo "[Autoscaler] GitHub API reports $IDLE_COUNT Idle baremetal runners. Scaling DOWN Runner $KILL_INDEX..."
    
    if [ -f "$SCRIPT_DIR/runner-${KILL_INDEX}.pid" ]; then
        PID=$(cat "$SCRIPT_DIR/runner-${KILL_INDEX}.pid")
        kill -9 $PID 2>/dev/null || true
        rm -f "$SCRIPT_DIR/runner-${KILL_INDEX}.pid"
        
        # Cleanly signal the actual `.NET` listener to deregister and shutdown gracefully
        pkill -INT -f "Runner.Listener .*actions-runner-${KILL_INDEX}" || true
    fi
  fi
  
  # Polling every 15 seconds consumes exactly 240 API requests / hour.
  # Your total authenticated API capacity is natively 5,000 / hour, so this consumes < 5%.
  sleep 15
done
