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

RUNNER_NAME_PREFIX="${GH_RUNNER_NAME_PREFIX:-baremetal-runner}"

echo "=== Purging Bare-Metal Runner State on this machine (org=${GH_RUNNER_ORG}) ==="

# Capture this machine's identity BEFORE stop.sh runs and before we wipe
# anything. We need it to filter which org-side runners belong to this
# host so multi-machine deployments don't delete each other's runners.
MACHINE_HASH=""
if [ -s "$SCRIPT_DIR/.machine-id" ]; then
  MACHINE_HASH=$(cat "$SCRIPT_DIR/.machine-id")
fi

# 1. Cleanly stop processes and wipe per-runner credentials.
"$SCRIPT_DIR/stop.sh"

# Give listeners a moment to finish flushing.
sleep 2

# 2. Deregister this machine's runners from GitHub via the REST API.
#    We use DELETE-by-id instead of `config.sh remove` because stop.sh
#    already wiped the .runner/.credentials files that config.sh would
#    need, and the runner directories may be partially gone from a
#    previous failed purge. The API path has neither dependency.
if [ -z "${GH_RUNNER_PAT:-}" ]; then
  echo "WARNING: GH_RUNNER_PAT is not set. Skipping GitHub-side deregistration."
  echo "         Offline entries will linger in the org until you remove them manually."
elif [ -z "$MACHINE_HASH" ]; then
  echo "WARNING: .machine-id is missing or empty; cannot safely identify which"
  echo "         org runners belong to this host. Skipping GitHub-side deregistration"
  echo "         to avoid affecting other machines' runners."
else
  echo "Listing org runners to deregister ones belonging to machine ${MACHINE_HASH}..."
  RUNNERS_JSON=$(curl -s -L \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_RUNNER_PAT" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/${GH_RUNNER_ORG}/actions/runners?per_page=100")

  if ! echo "$RUNNERS_JSON" | jq -e '.runners' >/dev/null 2>&1; then
    echo "WARNING: could not list org runners (response: $RUNNERS_JSON)"
    echo "         Continuing with local wipe; you may need to delete offline"
    echo "         runner entries in the org settings UI."
  else
    PREFIX_MATCH="${RUNNER_NAME_PREFIX}-"
    SUFFIX_MATCH="-${MACHINE_HASH}"
    MATCHES=$(echo "$RUNNERS_JSON" | jq -r \
      --arg pfx "$PREFIX_MATCH" --arg sfx "$SUFFIX_MATCH" \
      '.runners[] | select(.name | startswith($pfx)) | select(.name | endswith($sfx)) | "\(.id) \(.name)"')

    if [ -z "$MATCHES" ]; then
      echo "No GitHub-side runners matched this machine's naming pattern (nothing to delete)."
    else
      while IFS= read -r LINE; do
        [ -z "$LINE" ] && continue
        RID="${LINE%% *}"
        RNAME="${LINE#* }"
        echo "Deleting runner '$RNAME' (id=$RID)..."
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -L -X DELETE \
          -H "Accept: application/vnd.github+json" \
          -H "Authorization: Bearer $GH_RUNNER_PAT" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "https://api.github.com/orgs/${GH_RUNNER_ORG}/actions/runners/${RID}")
        if [ "$HTTP_CODE" != "204" ]; then
          echo "WARNING: delete returned HTTP $HTTP_CODE for runner '$RNAME' (id=$RID)."
        fi
      done <<< "$MATCHES"
    fi
  fi
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
