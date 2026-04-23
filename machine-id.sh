#!/bin/bash
# machine-id.sh - Stable per-machine short hash for runner naming
#
# First invocation on a given checkout/machine writes a random 6-char hex
# token to "$DIR/.machine-id". Subsequent calls return the cached value so
# the identity is stable across restarts but unique per machine, preventing
# runner-name collisions when this repo is deployed on multiple hosts.

ensure_machine_id() {
  local dir="$1"
  local file="$dir/.machine-id"
  if [ ! -s "$file" ]; then
    od -An -tx1 -N3 /dev/urandom | tr -d ' \n' > "$file"
  fi
  cat "$file"
}
