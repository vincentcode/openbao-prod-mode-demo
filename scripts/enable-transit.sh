#!/usr/bin/env bash
# enable-transit.sh -- one-time setup of the actual thing this instance
# is for: Transit encryption-as-a-service, reached via an AppRole a
# real app would authenticate with (never the root token -- see
# init-and-unseal.sh's own note). Safe to re-run: every step is
# idempotent (enable/create calls are no-ops if already done, `-force`
# isn't needed anywhere here).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONTAINER=openbao_demo
KEYS_FILE=.bao-init.json
TRANSIT_KEY=demo-app
POLICY_NAME=demo-transit
ROLE_NAME=demo-app

if [ ! -f "$KEYS_FILE" ]; then
  echo "error: $KEYS_FILE not found -- run init-and-unseal.sh first" >&2
  exit 1
fi

ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('$KEYS_FILE'))['root_token'])")
bao() { docker exec -e BAO_TOKEN="$ROOT_TOKEN" "$CONTAINER" bao "$@"; }

echo "== audit device =="
echo "enabled declaratively in config.hcl (OpenBao 2.x rejects "'`bao audit enable`'" via the API -- see config.hcl's own comment on why)"

echo "== transit secrets engine =="
if bao secrets list -format=json | python3 -c "import json,sys; sys.exit(0 if 'transit/' in json.load(sys.stdin) else 1)"; then
  echo "already enabled"
else
  bao secrets enable transit
fi

echo "== transit key: $TRANSIT_KEY =="
if bao read -field=name "transit/keys/$TRANSIT_KEY" >/dev/null 2>&1; then
  echo "already exists"
else
  bao write -f "transit/keys/$TRANSIT_KEY"
fi

echo "== policy: $POLICY_NAME (encrypt/decrypt on this one key only) =="
cat <<EOF | docker exec -i -e BAO_TOKEN="$ROOT_TOKEN" "$CONTAINER" bao policy write "$POLICY_NAME" -
path "transit/encrypt/$TRANSIT_KEY" {
  capabilities = ["update"]
}
path "transit/decrypt/$TRANSIT_KEY" {
  capabilities = ["update"]
}
EOF

echo "== approle auth method =="
if bao auth list -format=json | python3 -c "import json,sys; sys.exit(0 if 'approle/' in json.load(sys.stdin) else 1)"; then
  echo "already enabled"
else
  bao auth enable approle
fi

echo "== approle role: $ROLE_NAME =="
bao write "auth/approle/role/$ROLE_NAME" \
  token_policies="$POLICY_NAME" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \
  token_num_uses=0

ROLE_ID=$(bao read -field=role_id "auth/approle/role/$ROLE_NAME/role-id")
SECRET_ID=$(bao write -f -field=secret_id "auth/approle/role/$ROLE_NAME/secret-id")

cat <<EOF

Done. Put these in your app's env (never in a repo):
  OPENBAO_ADDR=http://localhost:8200
  OPENBAO_ROLE_ID=$ROLE_ID
  OPENBAO_SECRET_ID=$SECRET_ID
  OPENBAO_TRANSIT_KEY=$TRANSIT_KEY

secret_id_ttl=0 above means this secret_id never expires on its own --
fine for a local instance you fully control, wrong for a real
deployment (see README.md). A real app exchanges role_id+secret_id for
a short-lived token (token_ttl=1h) via POST auth/approle/login, then
uses that token for the actual transit/encrypt and transit/decrypt
calls -- it never holds a long-lived credential capable of those calls
directly.
EOF
