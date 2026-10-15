# Unsealing: key file, manual, or KMS auto-unseal

OpenBao starts **sealed** after every start or restart, and by default it
needs 3 of 5 Shamir key shares before it can do anything. Who or what
supplies those shares is the real decision here. This repo's lab setup
uses manual Shamir unseal (A or B below) because it has no cloud account
behind it — but if you *do* have a KMS or HSM available, as in a real
deployment, **Option C removes the human from the loop entirely** and is
the one to actually use. A and B remain useful background even then: they
explain the mechanism Option C is replacing.

| | **Option A: scripts + key file** | **Option B: manual, keys held by a person** | **Option C: KMS/HSM auto-unseal** |
|---|---|---|---|
| Keys stored on the server | Yes, in `.bao-init.json` | No | No (an encrypted blob of the root key is; the KMS/HSM holds the real key) |
| Root token stored on the server | Yes, in `.bao-init.json` | No | No |
| Unseal after a restart | `./scripts/init-and-unseal.sh` | Type 3 keys by hand (about a minute) | Automatic -- no human action |
| Can it come back up unattended | Yes, if you script it | No, stays sealed until a person unseals it | Yes, always |
| If the server is stolen or compromised | Attacker has everything needed to unseal | Attacker has ciphertext only | Attacker has ciphertext only, *and* still needs the server's cloud/HSM identity to ever decrypt it |
| Needs | Nothing extra | Nothing extra | A cloud KMS or on-prem HSM, and IAM/identity trust set up for this server |
| Good for | Local lab, throwaway instances | A server you care about, no KMS available | A real deployment -- use this whenever you can |

If a KMS or HSM is available to you, skip straight to **Option C**. Use
B only when none is available and the data still matters.

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

## Option C: auto-unseal via a cloud KMS or on-prem HSM

### C1. The mechanism, briefly

At init, OpenBao generates the root key same as always, but instead of
Shamir-splitting it into shares a person holds, it sends the whole key to
your KMS/HSM to be encrypted once. That encrypted blob is stored right
alongside OpenBao's own data (harmless -- it's ciphertext). On every
startup, OpenBao sends the blob back to the KMS/HSM and asks it to decrypt
it, which only succeeds because the KMS trusts this specific server's
identity (an IAM role, a managed identity, a client cert -- whichever the
backend uses). No person, no typed-in key, every time. See the README's
own "Auto-unseal" section for the full walkthrough of why this is a
different mechanism from Shamir, not just "shares stored somewhere else."

Shamir doesn't disappear -- OpenBao still generates 5 shares at init, but
they're now called **recovery keys**, used only for break-glass operations
(rotating the seal, decommissioning auto-unseal) rather than routine
unsealing.

### C2. What's common to every backend below

- The `seal` stanza goes in `config.hcl`, alongside the existing `storage`
  and `listener` blocks -- nothing else in this repo's config changes.
- The server needs network access to the KMS/HSM endpoint, and needs to
  *authenticate* to it. Wherever possible, use the platform's own identity
  mechanism (IAM role, managed identity, workload identity) instead of a
  long-lived credential sitting in `docker-compose.yaml` -- that credential
  would just become a new "secret on the server" of exactly the kind
  auto-unseal is meant to get rid of.
- `bao operator init` is still run exactly once, same as Options A/B --
  but with auto-unseal configured, you don't need `-key-shares`/
  `-key-threshold` at all; omit them and OpenBao issues 5 recovery keys
  under `-recovery-shares`/`-recovery-threshold` instead (defaults are
  fine for most cases). There is no unseal step afterward -- the server
  comes up unsealed on its own.

### C3. AWS KMS

```hcl
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "arn:aws:kms:us-east-1:123456789012:key/<key-id>"
}
```

- Credentials: don't put an access key in `config.hcl` or the environment
  if this runs on EC2/ECS/EKS -- attach an IAM role to the instance/task
  instead, and let the AWS SDK pick it up automatically. The role needs
  `kms:Encrypt`, `kms:Decrypt`, and `kms:DescribeKey` on that one key --
  nothing broader.
- `kms_key_id` can be a key ID, ARN, or alias; the ARN form above is the
  least ambiguous.

### C4. Azure Key Vault

```hcl
seal "azurekeyvault" {
  tenant_id  = "<tenant-id>"
  vault_name = "<key-vault-name>"
  key_name   = "<key-name>"
}
```

- Credentials: prefer a **managed identity** on the VM/container host over
  a client secret. Grant it `Get`, `WrapKey`, and `UnwrapKey` on that one
  key via the Key Vault's access policy (or RBAC role, if the vault uses
  Azure RBAC) -- not Key Vault-wide access.
- If a managed identity genuinely isn't available, `client_id` +
  `client_secret` fields exist on this stanza, but that secret becomes
  exactly the kind of long-lived credential this setup is meant to avoid
  -- treat it with the same care as a root token.

### C5. GCP Cloud KMS

```hcl
seal "gcpckms" {
  project     = "<project-id>"
  region      = "<region>"
  key_ring    = "<key-ring>"
  crypto_key  = "<key-name>"
}
```

- Credentials: on GCE/GKE, prefer the instance's own service account via
  **Workload Identity** over a downloaded JSON key file. If a key file is
  unavoidable, point `GOOGLE_APPLICATION_CREDENTIALS` at it and keep that
  file off the image/volume layers that leave the host.
- The service account needs the `Cloud KMS CryptoKey Encrypter/Decrypter`
  role on that one crypto key, not on the whole key ring or project.

### C6. Generic PKCS#11 (on-prem HSM)

```hcl
seal "pkcs11" {
  lib            = "/usr/lib/softhsm/libsofthsm2.so"   # path to the HSM vendor's PKCS#11 library
  slot           = "0"
  pin            = "<hsm-pin>"
  key_label      = "openbao-root"
  hmac_key_label = "openbao-hmac"
}
```

- The PKCS#11 library is vendor-specific (SoftHSM, Thales/Luna, AWS
  CloudHSM's own PKCS#11 client, etc.) and has to be present *inside* the
  container -- this almost always means building a custom image on top of
  `openbao/openbao` that installs the vendor's client/library, since the
  stock image doesn't ship one.
- The HSM (or its network client) must be reachable from the container;
  for a networked HSM this usually means another volume/socket mount for
  the vendor client's own config, on top of the `lib` path above.
- This is the most operationally heavy option of the four -- reach for a
  cloud KMS instead whenever the server already runs in a cloud account.

### C7. First init, with any of the above configured

```bash
docker compose up -d
docker exec openbao_demo bao operator init   # no -key-shares/-key-threshold
docker exec openbao_demo bao status          # Sealed: false, with no unseal step
```

The 5 recovery keys print once, same rules as Shamir shares in B1: copy
them somewhere safe immediately, then clear the terminal. You won't use
them routinely, but you'll need them for C8 below or for any future seal
rotation.

### C8. Migrating an existing Shamir-sealed instance (A or B) to Option C

No re-init needed -- the root key itself doesn't change, only how it's
protected.

1. Add the `seal` stanza to `config.hcl` (any backend above) with
   `disabled = "false"` implicit (the default).
2. Restart the container: `docker compose up -d --force-recreate`. It
   comes up sealed, same as any config change.
3. Unseal **with the existing Shamir keys**, exactly as in B2 (or run
   `init-and-unseal.sh` if still on Option A). OpenBao detects the seal
   configuration changed and performs the migration automatically as part
   of this unseal -- the root key gets wrapped by the new KMS/HSM seal
   from this point on.
4. Confirm it worked: restart again (`docker compose restart openbao`)
   and check that it comes back up **sealed: false with no unseal step**.
   If it still asks for Shamir keys, the migration didn't complete --
   check `docker logs openbao_demo` for the seal backend's own error
   (almost always a permissions/credentials problem reaching the KMS).
5. Once confirmed, revoke the old root token if you haven't already (B4)
   and retire the old `.bao-init.json` (A) or the Shamir keys from B1's
   storage -- they still work as *recovery* keys, but routine unsealing no
   longer needs them.

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
| Option C: still sealed / still asking for Shamir keys after adding a `seal` stanza | Migration (C8) didn't complete -- check `docker logs openbao_demo` for the seal backend's own error, almost always missing permissions or the server's identity not being trusted by the KMS/HSM yet. |
| Option C: `error fetching seal wrapped keys` or similar at startup | The server can't reach the KMS/HSM, or its credentials don't have decrypt access to the configured key. Confirm network reachability and the IAM role/managed identity/service account's permissions from C2-C6. |
