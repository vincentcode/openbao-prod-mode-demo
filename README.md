# OpenBao, in prod mode, on your laptop

A self-contained, runnable lab for actually understanding how OpenBao
(the open-source Vault fork) works in production mode — not `-dev`
mode, which hides every interesting mechanic behind a flag. Everything
in this repo has been run for real while building it: init, unseal, a
restart that re-seals it, Transit encryption through a least-privilege
AppRole, and a permission check confirming that AppRole genuinely can't
do anything beyond the one thing it's scoped to.

No cloud account, no Kubernetes, no TLS certs to generate — just Docker
and about ten minutes.

## Why prod mode, not `-dev`

`bao server -dev` gives you in-memory storage, an auto-unsealed server,
and a root token printed straight to your terminal. None of that
resembles a real deployment, and more importantly, none of it teaches
you the actual mechanics — the *why* is the whole point here. This repo
runs real persistent storage, a real init-once/unseal-every-restart
lifecycle, and a real least-privilege access setup, all on one Docker
container.

## Quick start

```bash
docker compose up -d              # starts sealed and uninitialized -- normal
./scripts/init-and-unseal.sh      # one-time init, then unseal (needed again after every restart)
./scripts/enable-transit.sh       # wires up Transit + a least-privilege AppRole
```

Then open **http://localhost:8200/ui**, method **Token**, and paste in
the `root_token` from the `.bao-init.json` this just generated.

## The concepts — what's actually happening

### The root key

OpenBao's storage backend is encrypted at rest. Something has to hold
the one key that protects everything else in that store — that key,
the **root key**, is never written to disk in plaintext anywhere. It
exists only transiently, in the running server's memory, after being
reconstructed.

### Sealed vs. unsealed

**Sealed** means the process is running and answering requests, but
does not have the root key in memory — it cannot decrypt a single byte
of its own storage, including facts as basic as which secrets engines
are enabled. It's not "running with reduced permissions"; it doesn't
function as a vault at all yet. Try it yourself: `docker restart
openbao_demo`, then `docker exec openbao_demo bao status` — it comes
back `Sealed: true`, and **the root token itself gets rejected** at
that point, because there's no auth backend loaded yet for any token,
root included, to be checked against.

**Unsealed** means the root key has been reconstructed in memory, so
the server can actually decrypt its storage and do its job. Every
restart re-seals it again — this is the security property working as
intended, not friction to route around: even someone with full disk
access to a stopped server has ciphertext and nothing else.

### Shamir's Secret Sharing — the 5-of-3 split

`init-and-unseal.sh` runs `bao operator init -key-shares=5
-key-threshold=3`. Rather than storing the root key as one value (a
single point of compromise) or handing it to one person (a single
point of trust), Shamir's scheme mathematically splits it into 5
**shares** such that:

- Any 3 shares together reconstruct the original key exactly.
- Any fewer — 2, 1, or any number under the threshold — reveal
  **cryptographically zero information** about it. Not "hard to
  guess": zero, by the math of the scheme itself.

Each `bao operator unseal <share>` submits one share; after the 3rd
valid one lands, OpenBao reconstructs the root key in memory and
unseals. That's exactly what `init-and-unseal.sh`'s loop does.

**Where the shares are meant to live**: not together, and not on any
single server, remote or otherwise — a remote server holding all 5 is
exactly the single point of compromise the split exists to avoid. In a
real deployment, each share goes to a different trusted person, in
separate custody (a personal password manager, a physical safe), so no
single stolen laptop or compromised office gets an attacker to the
threshold. **In this lab, all 5 sit together in one file**
(`.bao-init.json`) — which fully collapses that property (5-of-5 in
one place is strictly more than the 3 needed). That's the right
tradeoff for a single-person local lab with no second person to split
across — not a template for how a real team should run it.

### Root key vs. root token — different jobs

- **Root key** — the Shamir-split cryptographic key. Its only job:
  "can the server decrypt its own storage at all." You never see it
  directly, only its 5 shares.
- **Root token** — the credential you paste into the UI login screen,
  or set as `BAO_TOKEN` for the CLI. It's an *authorization*
  credential — an all-permissions API token, same category as the
  AppRole token a real app gets, just with every permission instead of
  a scoped one.

Unsealing answers *"can this server function at all."* The root token
then answers *"what is this specific caller allowed to do,"* once it
already can. Neither substitutes for the other — a sealed server
rejects the root token (see above), and unsealing the server doesn't
hand you a root token either; a new one requires a separate
`generate-root` ceremony, itself gated by unseal-key quorum, not the
old token.

### Auto-unseal — what actually replaces the manual dance

Paging 3 people to type in key shares every time a node restarts
doesn't scale operationally. **Auto-unseal** replaces this, but not by
relocating the shares somewhere fetchable — it's a different mechanism
entirely:

1. At setup, the **entire root key** (not split into shares at all) is
   encrypted once by a cloud KMS's own key (AWS KMS, GCP, Azure Key
   Vault), producing one encrypted blob.
2. That blob is stored right alongside OpenBao's own data — harmless to
   store, since it's ciphertext.
3. On every startup, OpenBao sends that blob to the KMS and asks it to
   decrypt it — which the KMS does *only* because the server's cloud
   IAM identity is one it's configured to trust. No human, no share.

Trust moves from "3 people must cooperate" to "this one cloud IAM
policy decides who can ever bring this vault up." OpenBao still
generates 5 Shamir shares at init even in auto-unseal mode — they're
called **recovery keys** there, used only for rarer break-glass
operations, not routine unsealing.

This lab doesn't use auto-unseal — no cloud KMS is configured (check
`.bao-init.json` yourself: `recovery_keys_b64` comes back empty; only
`unseal_keys_b64`, the plain Shamir shares, are populated). Manual
unseal is the honest, correct state for a machine with no cloud account
behind it, and it's the version that actually shows you the mechanism.

## What "prod mode" required, concretely, vs. `-dev`

- **Real persistent storage** — `storage "raft"` in `config.hcl`,
  backed by the `openbao_file` Docker volume. Data survives `docker
  compose down` (not `-v`) and restarts.
- **A real init/unseal lifecycle** — see above.
- **A declarative audit log** — `audit "file"` in `config.hcl`, not the
  API. OpenBao 2.x actually rejects `bao audit enable ...` over the API
  now ("use declarative, config-based audit device management
  instead") — specifically so a compromised admin token can't silently
  turn auditing off at runtime; only editing this file (and restarting)
  can.
- **Least-privilege access** — a real app authenticates via AppRole
  (`role_id` + `secret_id` → a short-lived token), whose policy grants
  *only* `encrypt`/`decrypt` on one named Transit key. Confirmed live
  while building this: a token minted this way can encrypt/decrypt
  through Transit, but gets a flat `403 permission denied` on `bao
  secrets list` — it can't see or touch anything else in the store.

**The one deliberate simplification**: `listener "tcp" { tls_disable =
true }`. A real deployment terminates TLS on this listener (or sits
behind a proxy that does) — skipped here because generating and
trusting a cert adds setup weight without teaching anything about the
storage/init/unseal/policy model that's the actual point. Turning it on
later is a `config.hcl` change (`tls_cert_file`/`tls_key_file`) plus
pointing at `https://`, not a redesign.

## Trying Transit yourself

After `enable-transit.sh` prints a `role_id`/`secret_id`, this proves
the whole chain end to end, authenticated as the app — never as root:

```bash
ROLE_ID="<role_id from enable-transit.sh>"
SECRET_ID="<secret_id from enable-transit.sh>"

APP_TOKEN=$(docker exec openbao_demo bao write -field=token auth/approle/login \
  role_id="$ROLE_ID" secret_id="$SECRET_ID")

# Encrypt
PLAINTEXT_B64=$(echo -n '{"hello":"world"}' | base64)
CIPHERTEXT=$(docker exec -e BAO_TOKEN="$APP_TOKEN" openbao_demo \
  bao write -field=ciphertext transit/encrypt/demo-app plaintext="$PLAINTEXT_B64")
echo "$CIPHERTEXT"        # vault:v1:...

# Decrypt
docker exec -e BAO_TOKEN="$APP_TOKEN" openbao_demo \
  bao write -field=plaintext transit/decrypt/demo-app ciphertext="$CIPHERTEXT" | base64 -d

# Confirm this token can't do anything else
docker exec -e BAO_TOKEN="$APP_TOKEN" openbao_demo bao secrets list   # 403 permission denied
```

## Wiring this into a real app

Any language with an HTTP client can talk to OpenBao's REST API
directly, but the common path in Python is `hvac` (the standard Vault
client — API-compatible with OpenBao):

```python
import base64
import hvac

client = hvac.Client(url="http://localhost:8200")
client.auth.approle.login(role_id=ROLE_ID, secret_id=SECRET_ID)

def encrypt(plaintext: str) -> str:
    encoded = base64.b64encode(plaintext.encode()).decode()
    result = client.secrets.transit.encrypt_data(name="demo-app", plaintext=encoded)
    return result["data"]["ciphertext"]        # store this string, e.g. "vault:v1:..."

def decrypt(ciphertext: str) -> str:
    result = client.secrets.transit.decrypt_data(name="demo-app", ciphertext=ciphertext)
    return base64.b64decode(result["data"]["plaintext"]).decode()
```

The `client.auth.approle.login()` call needs to happen once per process
and again whenever the resulting token expires (`token_ttl=1h` in
`enable-transit.sh`) — worth a small wrapper that re-logs-in on a
failed call, not shown here.

**One thing worth knowing if you ever plan to switch an app between a
local key (e.g. Fernet) and OpenBao Transit**: it isn't a live
migration path. A value encrypted one way cannot be decrypted the
other way — they're different ciphertext formats entirely, not just
different keys. Migrating existing data means decrypting with the old
method and re-encrypting with the new one, row by row, before flipping
which one the app uses to read.

## Common commands

```bash
docker exec openbao_demo bao status      # initialized/sealed state, active node info
docker compose down                      # stops the container, keeps the volumes (data survives)
docker compose down -v                   # wipes everything -- back to a truly fresh instance
```

After any restart, it comes back sealed — re-run
`./scripts/init-and-unseal.sh` (it detects it's already initialized and
just unseals).

## Files here

| File | What it's for |
|---|---|
| `config.hcl` | Server config — raft storage, TCP listener, declarative audit device |
| `docker-compose.yaml` | The OpenBao service, published on `localhost:8200` |
| `scripts/init-and-unseal.sh` | One-time init + unseal-on-every-restart, idempotent |
| `scripts/enable-transit.sh` | Transit engine + key + least-privilege AppRole, idempotent |
| `.bao-init.json` | Generated locally by `init-and-unseal.sh` — unseal keys + root token. Gitignored; never commit this |

## Requirements

- Docker + Docker Compose
- Python 3 (only used by the setup scripts to parse JSON — `bao` itself does the real work)
