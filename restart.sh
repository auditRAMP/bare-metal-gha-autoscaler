#!/bin/bash
# restart.sh - Restart bare-metal ephemeral runners

set -e

echo "=== Restarting Bare-Metal Runners ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# Stop any running processes cleanly
"$SCRIPT_DIR/stop.sh"

# Wait a moment for processes to completely die
sleep 2

# Start them up newly
"$SCRIPT_DIR/start.sh"

echo "=== Restart Complete ==="
