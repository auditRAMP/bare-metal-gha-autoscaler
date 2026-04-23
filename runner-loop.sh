#!/bin/bash
# runner-loop.sh
# Usage: ./runner-loop.sh <path-to-runner> <runner-id>

RUNNER_DIR=$1
RUNNER_ID=$2

if [ -z "$RUNNER_DIR" ] || [ -z "$RUNNER_ID" ]; then
  echo "Usage: ./runner-loop.sh <runner-dir> <runner-id>"
  exit 1
fi

if [ -z "$GH_RUNNER_PAT" ]; then
  echo "Error: GH_RUNNER_PAT environment variable is not set."
  exit 1
fi

if [ -z "${GH_RUNNER_ORG:-}" ]; then
  echo "Error: GH_RUNNER_ORG environment variable is not set."
  exit 1
fi

RUNNER_NAME_PREFIX="${GH_RUNNER_NAME_PREFIX:-baremetal-runner}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=machine-id.sh
source "$SCRIPT_DIR/machine-id.sh"
MACHINE_HASH=$(ensure_machine_id "$SCRIPT_DIR")
RUNNER_NAME="${RUNNER_NAME_PREFIX}-${RUNNER_ID}-${MACHINE_HASH}"

echo "[Runner $RUNNER_ID] Starting ephemeral loop in $RUNNER_DIR (name=$RUNNER_NAME)"

# Move to the physical runner directory
cd "$RUNNER_DIR" || exit 1

while true; do
  # Clean up any lingering configuration from a prior iteration.
  # --ephemeral removes the GitHub-side registration, but leaves the local
  # .runner/.credentials files on disk. config.sh refuses to reconfigure
  # while those exist, so clear them at the top of every iteration.
  if [ -f ".runner" ]; then
    echo "[Runner $RUNNER_ID] Cleaning up stale local runner config"
    rm -f .runner .credentials .credentials_rsaparams || true
  fi

  echo "[Runner $RUNNER_ID] Requesting new GitHub registration token..."
  TOKEN_RES=$(curl -s -L -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_RUNNER_PAT" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/${GH_RUNNER_ORG}/actions/runners/registration-token")

  TOKEN=$(echo "$TOKEN_RES" | jq -r .token)

  if [ "$TOKEN" == "null" ] || [ -z "$TOKEN" ]; then
    echo "[Runner $RUNNER_ID] ERROR: Failed to get token. Details: $TOKEN_RES"
    echo "[Runner $RUNNER_ID] Retrying in 30 seconds..."
    sleep 30
    continue
  fi

  echo "[Runner $RUNNER_ID] Configuring ephemeral runner replacing target '${RUNNER_NAME}'..."

  CONFIG_ARGS=(
    --url "https://github.com/${GH_RUNNER_ORG}"
    --token "$TOKEN"
    --name "${RUNNER_NAME}"
    --ephemeral
    --unattended
    --replace
  )
  if [ -n "${GH_RUNNER_GROUP:-}" ]; then
    CONFIG_ARGS+=(--runnergroup "$GH_RUNNER_GROUP")
  fi

  ./config.sh "${CONFIG_ARGS[@]}"

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
