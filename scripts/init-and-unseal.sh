#!/usr/bin/env bash
# init-and-unseal.sh -- the manual "bao operator init" + "bao operator
# unseal" x3 dance, automated for local use. Prod mode (unlike -dev)
# does neither of these for you:
#   - init runs exactly ONCE per fresh storage volume. It generates 5
#     unseal key shares (3 needed to unseal) and a root token, printed
#     to stdout exactly once by OpenBao itself -- there is no way to
#     recover them afterward, only to re-init against empty storage.
#   - unseal must run again with 3 of those 5 keys every time the
#     container restarts (a real restart, a host reboot, `docker compose
#     down && up`) -- OpenBao does not remember it was unsealed before.
#
# This script is idempotent: run it any time (after `docker compose
# up -d`, after a restart) and it does whichever of init/unseal is
# still needed, or reports "already unsealed" and exits.
#
# Keys land in .bao-init.json, gitignored (see ../.gitignore) --
# treat that file as exactly as sensitive as a root password, because
# it is one. This whole approach (keys on a plain file on a laptop) is
# fine for local practice; a real deployment auto-unseals via a cloud
# KMS transit key instead, which removes the "human types keys in on
# every restart" step entirely -- see README.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONTAINER=openbao_demo
KEYS_FILE=.bao-init.json

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "error: $CONTAINER is not running -- run 'docker compose up -d' first" >&2
  exit 1
fi

bao() { docker exec "$CONTAINER" bao "$@"; }

if ! bao status -format=json >/tmp/bao-status.json 2>/dev/null; then
  # `bao status` exits non-zero for sealed/uninitialized too (that's
  # normal, not a real error) -- but it still writes valid JSON when it
  # could reach the server at all, so check the file, not the exit code.
  :
fi
INITIALIZED=$(python3 -c "import json; print(json.load(open('/tmp/bao-status.json'))['initialized'])" 2>/dev/null || echo "false")

if [ "$INITIALIZED" != "True" ]; then
  echo "Initializing (fresh storage) -- this happens exactly once."
  bao operator init -key-shares=5 -key-threshold=3 -format=json > "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"
  echo "Wrote unseal keys + root token to $KEYS_FILE (gitignored)."
  echo "This is the ONLY time OpenBao ever shows these -- back the file up somewhere real if you want to keep using this instance."
else
  echo "Already initialized."
fi

bao status -format=json >/tmp/bao-status.json 2>/dev/null || true
SEALED=$(python3 -c "import json; print(json.load(open('/tmp/bao-status.json'))['sealed'])")
if [ "$SEALED" != "True" ]; then
  echo "Already unsealed."
  exit 0
fi

if [ ! -f "$KEYS_FILE" ]; then
  echo "error: sealed, but $KEYS_FILE doesn't exist -- if this instance was initialized before and you lost that file, its data is unrecoverable; wipe the openbao_file volume and start over." >&2
  exit 1
fi

echo "Unsealing with 3 of the 5 key shares..."
for i in 0 1 2; do
  key=$(python3 -c "import json; print(json.load(open('$KEYS_FILE'))['unseal_keys_b64'][$i])")
  bao operator unseal "$key" >/dev/null
done

echo "Unsealed. Root token is in $KEYS_FILE (root_token) -- fine for this local instance's own setup steps, not what a real app should ever authenticate as (see README.md's AppRole section)."
