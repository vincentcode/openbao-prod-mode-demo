# Unsealing: scripts with a key file, or manual with the keys held by a person

OpenBao starts **sealed** after every start or restart, and it needs 3 of
the 5 unseal key shares (the default here) before it can do anything. With
no cloud KMS to auto-unseal, a human has to supply those shares. The only
real decision is **where the keys live**. This repo supports two ways.

| | **Option A: scripts + key file** | **Option B: manual, keys held by a person** |
|---|---|---|
| Keys stored on the server | Yes, in `.bao-init.json` | No |
| Root token stored on the server | Yes, in `.bao-init.json` | No |
| Unseal after a restart | `./scripts/init-and-unseal.sh` | Type 3 keys by hand (about a minute) |
| Can it come back up unattended | Yes, if you script it | No, stays sealed until a person unseals it |
| If the server is stolen or compromised | Attacker has everything needed to unseal | Attacker has ciphertext only |
| Good for | Local lab, throwaway instances | A server you care about |

If the data on this server matters, use **Option B**.

---

## Option A: scripts and a key file

This is the lab default described in the README. Nothing extra to set up.

```bash
docker compose up -d
./scripts/init-and-unseal.sh      # first run: init + unseal. Later runs: unseal only
./scripts/enable-transit.sh       # Transit + least-privilege AppRole
```

What it does:
- `init-and-unseal.sh` runs `bao operator init -key-shares=5 -key-threshold=3`
  once and writes the result to `.bao-init.json` (mode 600, gitignored).
  On every later run it detects the instance is initialized and just
  submits 3 of the 5 shares.
- `enable-transit.sh` reads `root_token` from the same file.

After every restart, run `./scripts/init-and-unseal.sh` again.

Things to know:
- The file holds **all 5 shares and the root token**. Anyone who can read it
  has full control, so it is exactly as sensitive as a root password. It is
  gitignored (`.bao-init*`); never commit it.
- Losing the file after init means the data is unrecoverable. The only fix
  is `docker compose down -v` and a fresh init.
- If you keep this on a server, at least `chmod 600` it, restrict SSH
  access to the box, and back the file up somewhere separate.

---

## Option B: manual, keys held by a person

The server never sees the keys in a file. `init-and-unseal.sh` **must not
be used** here, because it writes the file. Note that `enable-transit.sh`
also reads the root token from that file, so use the manual equivalent
below.

### B1. One-time init

```bash
docker compose up -d
docker exec openbao_demo bao operator init -key-shares=5 -key-threshold=3
```

The 5 keys and the root token print to your terminal and **nowhere else**.
Don't redirect the output to a file. OpenBao never shows them again.

1. Copy each key into your password manager or other separate places, plus
   the root token.
2. Run `clear` and close the terminal or scrollback that displayed them.

Choosing shares: if one person holds everything, the 5-of-3 split only
helps when the shares live in **different places** (it lets you lose two).
The alternative is `-key-shares=1 -key-threshold=1`. It is simpler, but
losing that single key means the data is gone, so keep at least two
backups of it.

### B2. Unseal (after every restart)

```bash
docker exec -it openbao_demo bao operator unseal    # paste key 1 (input hidden)
docker exec -it openbao_demo bao operator unseal    # paste key 2
docker exec -it openbao_demo bao operator unseal    # paste key 3
docker exec openbao_demo bao status                 # Sealed should read false
```

- `-it` is needed so the key prompt works.
- Never pass the key as an argument (`bao operator unseal <key>`). It would
  be saved in shell history and visible in the process list. Typed at the
  prompt, it is neither.
- `bao status` shows `Unseal Progress 1/3`, `2/3` while you go.

### B3. Set up Transit and the AppRole (replaces `enable-transit.sh`)

Provide the root token from your own copy without putting it in a file,
shell history, or on a command line:

```bash
read -rs -p "Root token: " BAO_TOKEN; echo
export BAO_TOKEN

docker exec -e BAO_TOKEN openbao_demo bao secrets enable transit
docker exec -e BAO_TOKEN openbao_demo bao write -f transit/keys/demo-app

docker exec -i -e BAO_TOKEN openbao_demo bao policy write demo-transit - <<'EOF'
path "transit/encrypt/demo-app" {
  capabilities = ["update"]
}
path "transit/decrypt/demo-app" {
  capabilities = ["update"]
}
EOF

docker exec -e BAO_TOKEN openbao_demo bao auth enable approle
docker exec -e BAO_TOKEN openbao_demo bao write auth/approle/role/demo-app \
  token_policies=demo-transit token_ttl=1h token_max_ttl=4h \
  secret_id_ttl=0 token_num_uses=0

docker exec -e BAO_TOKEN openbao_demo bao read -field=role_id auth/approle/role/demo-app/role-id
docker exec -e BAO_TOKEN openbao_demo bao write -f -field=secret_id auth/approle/role/demo-app/secret-id
```

`-e BAO_TOKEN` (name only, no value) passes the variable from your shell
into the container without it appearing in the command line.

The last two commands print the `role_id` and `secret_id` for your app.
`secret_id_ttl=0` means the secret never expires, which is fine for a lab
but wrong for a real deployment.

### B4. Get rid of the root token

Once setup is done, revoke the root token so no long-lived all-powerful
credential exists:

```bash
docker exec -e BAO_TOKEN openbao_demo bao token revoke -self
unset BAO_TOKEN
```

### B5. When you need a root token again

A new one requires a quorum of unseal keys, so a stolen token or server is
not enough. Do this only for a specific admin task:

```bash
docker exec openbao_demo bao operator generate-root -init    # note the Nonce and OTP
docker exec -it openbao_demo bao operator generate-root      # prompts for nonce + a key; repeat until 3 keys are in
docker exec openbao_demo bao operator generate-root -decode=<Encoded Token> -otp=<OTP>
```

The last command prints the new root token. Use it, then revoke it again
as in B4.

### What you accept with Option B

- After a restart, crash or host reboot the server stays **sealed** until
  you unseal it, and apps can't log in with AppRole while it is sealed.
- `docker-compose.yaml` has no `restart:` policy, so the container doesn't
  come back on its own after a reboot. If you add `restart: unless-stopped`,
  it comes back automatically, but still sealed.
- The people holding the keys are a real dependency. If they are
  unavailable, so is the vault.

---

## Switching from A to B on an existing instance

If you already initialized with the script and now want the keys held by a
person:

1. Copy `.bao-init.json` off the server (for example `scp` to your machine)
   and put the 5 keys somewhere safe. Confirm you can read them back.
2. Delete `.bao-init.json` from the server.
3. Revoke the old root token (it was also in that file). Use it one last
   time for this, then make a new one with B5 whenever it's needed:
   `bao token revoke -self`.
4. From now on, unseal with B2. **Don't run `init-and-unseal.sh`**: while
   sealed, it stops with an error because the key file is missing, which is
   the correct behavior here.

The unseal keys themselves don't change, so no re-init is needed.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `bao status` shows `Sealed: true` after a restart | Expected. Unseal again (A: run the script, B: B2). |
| Unseal progress stays at `0/3` or a key is rejected | Wrong or mistyped key. Keys are long base64 strings; copy them with no surrounding spaces. |
| `error: sealed, but .bao-init.json doesn't exist` | You're in Option B mode (or the file was lost). Unseal manually with B2. |
| The root token is rejected right after a restart | Normal while sealed. Unseal first, then use the token. |
| Lost too many keys (fewer than 3 left) | The data cannot be recovered. `docker compose down -v` and re-init. |
