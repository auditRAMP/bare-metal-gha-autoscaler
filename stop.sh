#!/bin/bash
# stop.sh - Stop all bare metal background runners

echo "=== Stopping Bare-Metal Runners ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# First, kill the autoscaler so it doesn't try to revive runners
echo "Terminating all Autoscaler daemons globally to prevent rogue ghosting..."
pkill -9 -f "autoscaler.sh" || true
rm -f "$SCRIPT_DIR/autoscaler.pid"

# Ensure all potential loop workers are stopped regardless of scalar limits
for PID_FILE in "$SCRIPT_DIR"/runner-*.pid; do
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    echo "Stopping background runner loop (PID: $PID)..."
    
    # Kill the background loop script
    kill -9 $PID 2>/dev/null || true
    rm -f "$PID_FILE" 
    
    # If a state file was lingering, wipe it securely
    STATE_FILE="${PID_FILE%.pid}.state"
    rm -f "$STATE_FILE"
  fi
done

# Now we need to terminate actual runner listener binaries that might be orphaned by the hard kill
echo "Terminating any lingering GitHub Runner Listeners..."
pkill -f "Runner.Listener" || true

# Extract max limit to ensure we purge all possible configured directories
MAX_RUNNERS=5
if [ -f "$SCRIPT_DIR/scaler.properties" ]; then
  VAL_MAX=$(grep -E "^MAX_RUNNERS=" "$SCRIPT_DIR/scaler.properties" | cut -d '=' -f2 | tr -d '\r')
  [[ "$VAL_MAX" =~ ^[0-9]+$ ]] && MAX_RUNNERS=$VAL_MAX
fi

# Clean up any partial state
echo "Cleaning up local runner configuration caches just in case..."
for i in $(seq 1 $MAX_RUNNERS); do
  RUNNER_PATH="$SCRIPT_DIR/actions-runner-${i}"
  if [ -d "$RUNNER_PATH" ]; then
      rm -f "$RUNNER_PATH/.runner" "$RUNNER_PATH/.credentials" "$RUNNER_PATH/.credentials_rsaparams" 2>/dev/null || true
  fi
done

echo "=== All bare-metal processes stopped ==="
