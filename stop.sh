#!/bin/bash
# stop.sh - Stop all bare metal background runners

echo "=== Stopping Bare-Metal Runners ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# First, kill the autoscaler so it doesn't try to revive runners
AUTOSCALER_PID_FILE="$SCRIPT_DIR/autoscaler.pid"
if [ -f "$AUTOSCALER_PID_FILE" ]; then
  AUTOSCALER_PID=$(cat "$AUTOSCALER_PID_FILE")
  echo "Stopping Autoscaler daemon (PID: $AUTOSCALER_PID)..."
  kill -9 $AUTOSCALER_PID 2>/dev/null || true
  rm -f "$AUTOSCALER_PID_FILE"
fi

# Ensure all 5 potential workers are stopped
for i in {1..5}; do
  PID_FILE="$SCRIPT_DIR/runner-${i}.pid"
  
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    echo "Stopping runner loop $i (PID: $PID)..."
    
    # Kill the background loop script
    kill -9 $PID 2>/dev/null || true
    rm -f "$PID_FILE" "$SCRIPT_DIR/runner-${i}.state"
    
    echo "Runner loop $i stopped."
  fi
done

# Now we need to terminate actual runner listener binaries that might be orphaned by the hard kill
echo "Terminating any lingering GitHub Runner Listeners..."
pkill -f "Runner.Listener" || true

# Clean up any partial state
echo "Cleaning up local runner configuration caches just in case..."
for i in {1..5}; do
  RUNNER_PATH="$SCRIPT_DIR/../actions-runner-${i}"
  if [ -d "$RUNNER_PATH" ]; then
      rm -f "$RUNNER_PATH/.runner" "$RUNNER_PATH/.credentials" "$RUNNER_PATH/.credentials_rsaparams" 2>/dev/null || true
  fi
done

echo "=== All bare-metal processes stopped ==="
