#!/bin/bash
# runner-loop.sh
# Usage: ./runner-loop.sh <path-to-runner> <runner-id>

RUNNER_DIR=$1
RUNNER_ID=$2

if [ -z "$RUNNER_DIR" ] || [ -z "$RUNNER_ID" ]; then
  echo "Usage: ./runner-loop.sh <runner-dir> <runner-id>"
  exit 1
fi

if [ -z "$GH_ARC_RUNNERS" ]; then
  echo "Error: GH_ARC_RUNNERS environment variable is not set."
  exit 1
fi

GITHUB_ORG="auditRAMP"
RUNNER_GROUP="Mac Mini K8s Runner Group"

echo "[Runner $RUNNER_ID] Starting ephemeral loop in $RUNNER_DIR"

# Move to the physical runner directory
cd "$RUNNER_DIR" || exit 1

# Clean up any lingering configurations from prior runs just to be absolutely safe
if [ -f ".runner" ]; then
  echo "[Runner $RUNNER_ID] Cleaning up old .runner file"
  rm .runner || true
  rm .credentials || true
  rm .credentials_rsaparams || true
fi

while true; do
  echo "[Runner $RUNNER_ID] Requesting new GitHub registration token..."
  TOKEN_RES=$(curl -s -L -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_ARC_RUNNERS" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/registration-token")

  TOKEN=$(echo "$TOKEN_RES" | jq -r .token)

  if [ "$TOKEN" == "null" ] || [ -z "$TOKEN" ]; then
    echo "[Runner $RUNNER_ID] ERROR: Failed to get token. Details: $TOKEN_RES"
    echo "[Runner $RUNNER_ID] Retrying in 30 seconds..."
    sleep 30
    continue
  fi

  echo "[Runner $RUNNER_ID] Configuring ephemeral runner replacing target 'audit-runner-baremetal-${RUNNER_ID}'..."

  ./config.sh \
    --url "https://github.com/${GITHUB_ORG}" \
    --token "$TOKEN" \
    --name "audit-runner-baremetal-${RUNNER_ID}" \
    --ephemeral \
    --unattended \
    --replace

  if [ $? -ne 0 ]; then
     echo "[Runner $RUNNER_ID] ERROR configuring runner. Retrying in 30 seconds..."
     sleep 30
     continue
  fi

  echo "[Runner $RUNNER_ID] Configuration complete. Listening for one job..."
  
  # When run.sh completes, it naturally exits after exactly 1 job due to --ephemeral
  ./run.sh

  echo "[Runner $RUNNER_ID] Ephemeral run finished! Resetting in 5 seconds..."
  sleep 5
done
