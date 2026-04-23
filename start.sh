#!/bin/bash
# start.sh - Start the Autoscaler Daemon with dynamic provisioning

set -e

if [ -z "$GH_RUNNER_PAT" ]; then
  echo "Error: GH_RUNNER_PAT environment variable must be set with your PAT."
  exit 1
fi

if [ -z "${GH_RUNNER_ORG:-}" ]; then
  echo "Error: GH_RUNNER_ORG environment variable must be set to the GitHub org that will own these runners (e.g. export GH_RUNNER_ORG=my-org)."
  exit 1
fi

RUNNER_NAME_PREFIX="${GH_RUNNER_NAME_PREFIX:-baremetal-runner}"

echo "=== Starting Bare-Metal Autoscaler ==="

# Get the absolute path of this project directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# Stamp (or read) this machine's stable short id so runner names don't
# collide with other hosts running the same autoscaler.
# shellcheck source=machine-id.sh
source "$SCRIPT_DIR/machine-id.sh"
MACHINE_HASH=$(ensure_machine_id "$SCRIPT_DIR")
echo "Machine identity: ${MACHINE_HASH} (runners will be named ${RUNNER_NAME_PREFIX}-<N>-${MACHINE_HASH})"

# Detect OS
OS_RAW=$(uname -s | tr '[:upper:]' '[:lower:]')
if [[ "$OS_RAW" == "darwin" ]]; then
  OS="osx"
elif [[ "$OS_RAW" == "linux" ]]; then
  OS="linux"
else
  echo "Unsupported operating system: $OS_RAW"
  exit 1
fi

# Detect Architecture
ARCH=$(uname -m)
case $ARCH in
  x86_64|amd64)
    ARCH_NAME="x64"
    ;;
  arm64|aarch64)
    ARCH_NAME="arm64"
    ;;
  *)
    echo "Unknown or unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# Formulate payload variables
RUNNER_VERSION="2.333.0"
TARBALL="actions-runner-${OS}-${ARCH_NAME}-${RUNNER_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"
TARBALL_PATH="$SCRIPT_DIR/$TARBALL"

# Extract maximum provision limit dynamically to ensure the directories support the autoscaler's upper bounds
MAX_RUNNERS=5
if [ -f "$SCRIPT_DIR/scaler.properties" ]; then
  VAL_MAX=$(grep -E "^MAX_RUNNERS=" "$SCRIPT_DIR/scaler.properties" | cut -d '=' -f2 | tr -d '\r')
  [[ "$VAL_MAX" =~ ^[0-9]+$ ]] && MAX_RUNNERS=$VAL_MAX
fi

echo "Detected System: $OS ($ARCH_NAME)"
echo "Target Provisioning Payload: $TARBALL"

# Automatically retrieve tarball if it does not physically exist
if [ ! -f "$TARBALL_PATH" ]; then
  echo "Tarball '$TARBALL' not found natively in the directory."
  echo "Downloading automatically from GitHub Actions Official Release Core..."
  curl -o "$TARBALL_PATH" -L "$DOWNLOAD_URL"
  echo "Download successfully completed."
fi

# Automatically provision missing runners up to the Autoscaler's MAX limit
for i in $(seq 1 $MAX_RUNNERS); do
  RUNNER_PATH="$SCRIPT_DIR/actions-runner-${i}"
  
  if [ ! -d "$RUNNER_PATH" ]; then
    echo "Worker directory $RUNNER_PATH missing. Provisioning fresh runner from tarball..."
    
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
