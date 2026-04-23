#!/bin/bash
# purge.sh - Stop everything and wipe all local runner state on this machine.
#
# This goes further than stop.sh:
#   - stop.sh       : kills processes, clears per-runner credentials so the
#                     next start.sh can re-register cleanly.
#   - purge.sh (me) : kills processes, deregisters each still-registered
#                     runner from GitHub, then deletes every actions-runner-*
#                     directory, the downloaded tarball, the persisted
#                     .machine-id, and any leftover logs/pid/state files.
#
# Use this when you want a clean slate on this machine (e.g. before
# decommissioning the host or when changing the org / PAT / naming scheme).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

if [ -z "${GH_RUNNER_ORG:-}" ]; then
  echo "Error: GH_RUNNER_ORG environment variable must be set to the GitHub org that owns these runners (e.g. export GH_RUNNER_ORG=my-org)."
  exit 1
fi

echo "=== Purging Bare-Metal Runner State on this machine (org=${GH_RUNNER_ORG}) ==="

# 1. Cleanly stop processes and wipe per-runner credentials.
"$SCRIPT_DIR/stop.sh"

# Give listeners a moment to finish flushing.
sleep 2

# 2. Deregister any still-existing runner configs from GitHub using the
#    config.sh binary inside each runner directory. This requires a
#    removal-token, which we can mint from the PAT. If GH_RUNNER_PAT is
#    missing we skip this step with a warning; the directories themselves
#    will still be wiped below, but you may see "offline" entries linger
#    in the org until you delete them in the UI / via the API.
if [ -n "${GH_RUNNER_PAT:-}" ]; then
  echo "Requesting a one-time removal-token from GitHub..."
  REMOVAL_RES=$(curl -s -L -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_RUNNER_PAT" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/${GH_RUNNER_ORG}/actions/runners/remove-token")
  REMOVAL_TOKEN=$(echo "$REMOVAL_RES" | jq -r .token 2>/dev/null || echo "null")

  if [ "$REMOVAL_TOKEN" = "null" ] || [ -z "$REMOVAL_TOKEN" ]; then
    echo "WARNING: could not obtain removal-token (response: $REMOVAL_RES)"
    echo "         Continuing with local wipe; you may need to delete"
    echo "         offline runner entries in the org settings UI."
  else
    for RUNNER_PATH in "$SCRIPT_DIR"/actions-runner-*/; do
      [ -d "$RUNNER_PATH" ] || continue
      if [ -x "$RUNNER_PATH/config.sh" ]; then
        echo "Deregistering runner in $RUNNER_PATH..."
        (cd "$RUNNER_PATH" && ./config.sh remove --token "$REMOVAL_TOKEN" --unattended) \
          || echo "WARNING: deregister failed for $RUNNER_PATH (likely already removed)"
      fi
    done
  fi
else
  echo "WARNING: GH_RUNNER_PAT is not set. Skipping GitHub-side deregistration."
  echo "         Offline entries will linger in the org until you remove them manually."
fi

# 3. Wipe all extracted runner directories on this machine.
echo "Removing all actions-runner-* directories..."
rm -rf "$SCRIPT_DIR"/actions-runner-*/

# 4. Wipe the downloaded tarball so the next start.sh pulls a fresh one.
echo "Removing downloaded runner tarball(s)..."
rm -f "$SCRIPT_DIR"/actions-runner-*.tar.gz

# 5. Drop the machine identity so the next start.sh stamps a new one.
echo "Removing .machine-id..."
rm -f "$SCRIPT_DIR/.machine-id"

# 6. Sweep leftover ephemeral files (logs, pids, state).
echo "Removing leftover logs / pids / state files..."
rm -f "$SCRIPT_DIR"/*.log "$SCRIPT_DIR"/*.pid "$SCRIPT_DIR"/*.state

echo "=== Purge complete. Next ./start.sh will provision from scratch. ==="
