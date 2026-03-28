#!/bin/bash
# start.sh - Start the Autoscaler Daemon with dynamic provisioning

set -e

if [ -z "$GH_ARC_RUNNERS" ]; then
  echo "Error: GH_ARC_RUNNERS environment variable must be set with your PAT."
  exit 1
fi

echo "=== Starting Bare-Metal Autoscaler ==="

# Get the absolute path of this project directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# Detect Architecture and dynamically select tarball
ARCH=$(uname -m)
case $ARCH in
  x86_64)
    TARBALL="actions-runner-osx-x64-2.333.0.tar.gz"
    ;;
  arm64|aarch64)
    TARBALL="actions-runner-osx-arm64-2.333.0.tar.gz"
    ;;
  *)
    echo "Unknown or unsupported architecture: $ARCH"
    exit 1
    ;;
esac

TARBALL_PATH="$SCRIPT_DIR/$TARBALL"

echo "Detected System Architecture: $ARCH"
echo "Target Provisioning Tarball: $TARBALL"

# Automatically provision missing runners up to the Autoscaler's MAX limit (5)
for i in {1..5}; do
  RUNNER_PATH="$SCRIPT_DIR/../actions-runner-${i}"
  
  if [ ! -d "$RUNNER_PATH" ]; then
    echo "Worker directory $RUNNER_PATH missing. Provisioning fresh runner from tarball..."
    
    if [ ! -f "$TARBALL_PATH" ]; then
      echo "CRITICAL ERROR: Target tarball '$TARBALL_PATH' does not exist alongside this script! Please download it to continue provisioning."
      exit 1
    fi
    
    mkdir -p "$RUNNER_PATH"
    tar xzf "$TARBALL_PATH" -C "$RUNNER_PATH"
    echo "Successfully extracted core runner binary payload to Runner $i."
  fi
done

# Ensure the scripts are executable
chmod +x "$SCRIPT_DIR/runner-loop.sh"
chmod +x "$SCRIPT_DIR/autoscaler.sh"

echo "Launching Autoscaler daemon in the background..."

nohup "$SCRIPT_DIR/autoscaler.sh" > "$SCRIPT_DIR/autoscaler.log" 2>&1 &
PID=$!
echo $PID > "$SCRIPT_DIR/autoscaler.pid"

echo "Started Autoscaler (PID: $PID). Tailing logs into -> autoscaler.log"
echo "=== The Autoscaler is now actively managing your runner count! ==="
echo "Tip: Monitor the autoscaler live by running: tail -f autoscaler.log"
