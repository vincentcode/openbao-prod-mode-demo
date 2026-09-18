# Turning on TLS (HTTPS) for this lab

Out of the box the listener runs with `tls_disable = true`, so everything
travels as plain HTTP on `localhost:8200`. This guide switches it to HTTPS
using a certificate you generate yourself. Your existing data, unseal keys
and AppRole stay as they are: TLS only changes how clients reach the
server, not what is in storage, so there is **no re-init**.

The scripts (`init-and-unseal.sh`, `enable-transit.sh`) need **no
changes**. They run `bao` inside the container via `docker exec`, and
`docker exec` inherits the container's `BAO_ADDR` / `BAO_CACERT` from
`docker-compose.yaml`.

## What you'll change

| File | Change |
|---|---|
| `certs/` (new) | `tls.crt` + `tls.key`, generated in step 1 |
| `config.hcl` | Listener gets cert/key paths; `api_addr` becomes `https://` |
| `docker-compose.yaml` | Mount `certs/`, point `BAO_ADDR` at `https://`, add `BAO_CACERT`, fix the healthcheck |

## 1. Generate a certificate

The certificate must list every name you'll connect with in its
**Subject Alternative Names (SAN)**. That includes `127.0.0.1`, because the
scripts and healthcheck connect to that address from inside the container.
A cert without a matching SAN fails verification even when you trust it.

```bash
mkdir -p certs

# Git Bash on Windows rewrites "/CN=..." into a file path. This flag turns that off.
export MSYS_NO_PATHCONV=1

openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout certs/tls.key -out certs/tls.crt \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,DNS:openbao,IP:127.0.0.1"
```

This produces a self-signed certificate, valid for one year, that acts as
its own CA. Clients trust it by being pointed at `tls.crt` directly.

Optional: `mkcert` makes a cert your browser trusts without warnings.

```bash
mkcert -install
mkcert -cert-file certs/tls.crt -key-file certs/tls.key localhost 127.0.0.1 ::1
```

With mkcert the leaf isn't self-signed, so clients need mkcert's root CA
(`mkcert -CAROOT` shows where it lives) as their `BAO_CACERT`, not `tls.crt`.
The rest of this guide assumes the openssl route.

**Keep the key out of git.** `.gitignore` already covers `*.key`. Also add
`certs/` so the whole folder stays local.

## 2. Update `config.hcl`

Replace the listener block, and change only the scheme of `api_addr`:

```hcl
listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/openbao/tls/tls.crt"
  tls_key_file    = "/openbao/tls/tls.key"
  tls_min_version = "tls12"
}

api_addr     = "https://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"   # unchanged
```

`tls_disable` is gone; it defaults to `false`. `cluster_addr` is the
node-to-node port, which is irrelevant on a single node, so leave it alone.

## 3. Update `docker-compose.yaml`

```yaml
services:
  openbao:
    environment:
      BAO_ADDR: "https://127.0.0.1:8200"
      BAO_CACERT: "/openbao/tls/tls.crt"
    volumes:
      - ./config.hcl:/openbao/config/config.hcl:ro
      - ./certs:/openbao/tls:ro
      - openbao_file:/openbao/file
      - openbao_logs:/openbao/logs
    healthcheck:
      # `bao status` exits 1 on a connection/TLS failure, 2 when sealed.
      # Sealed still means "up", so only exit code 1 is unhealthy.
      # `$$` is compose's escape for a literal `$`.
      test: ["CMD-SHELL", "bao status >/dev/null 2>&1; [ $$? -ne 1 ]"]
      interval: 5s
      timeout: 5s
      retries: 10
```

The healthcheck changes because the old `wget http://...` check would now
hit an HTTPS port. Using `bao status` also means the check fails if the cert
is broken.

## 4. Apply it

`config.hcl` is a bind mount, so recreate the container to be sure it picks
up both files. It comes back **sealed**, as after any restart.

```bash
docker compose up -d --force-recreate
./scripts/init-and-unseal.sh      # detects "already initialized", just unseals
```

## 5. Verify

```bash
# Inside the container (uses BAO_ADDR + BAO_CACERT from compose)
docker exec openbao_demo bao status

# From the host, trusting your cert explicitly
curl --cacert certs/tls.crt https://localhost:8200/v1/sys/health

# See what the server actually presents
openssl s_client -connect localhost:8200 -servername localhost </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates -ext subjectAltName

# Plain HTTP should now be refused
curl http://localhost:8200/v1/sys/health
# -> Client sent an HTTP request to an HTTPS server.
```

## 6. Point clients at HTTPS

**Host-side `bao` CLI**

```bash
export BAO_ADDR=https://localhost:8200
export BAO_CACERT="$PWD/certs/tls.crt"
```

**Browser UI**: open `https://localhost:8200/ui`. You'll get a warning
because the cert is self-signed. Either click through it, or trust it once
for your Windows user (PowerShell):

```powershell
certutil -addstore -user Root certs\tls.crt
```

**Python (`hvac`)**: change the URL and pass the cert as `verify`. Never
use `verify=False`, which throws away the protection you just set up.

```python
client = hvac.Client(url="https://localhost:8200", verify="certs/tls.crt")
```

**`enable-transit.sh` output**: it prints `OPENBAO_ADDR=http://localhost:8200`
for your app's env. Use `https://` there and give the app the cert path
(commonly `VAULT_CACERT` / `BAO_CACERT`, or `verify=` as above).

## 7. Renewing the certificate

The cert above expires after 365 days. To rotate it, regenerate
`certs/tls.crt` and `certs/tls.key` with the same command, then reload the
listener. No restart or re-unseal is needed:

```bash
docker kill -s HUP openbao_demo
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `x509: certificate signed by unknown authority` | Client doesn't trust the cert. Set `BAO_CACERT` (or `verify=`) to `tls.crt`. |
| `x509: certificate is valid for X, not Y` | The name you connect with isn't in the SAN. Add it to `subjectAltName` and regenerate. |
| `server gave HTTP response to HTTPS client` | Client still using `http://`. Check `BAO_ADDR`. |
| `Client sent an HTTP request to an HTTPS server` | Opposite mistake: `http://` used against the TLS listener. |
| Container exits or restarts with a permission error on the key | On a Linux host, the container user must be able to read `tls.key` (e.g. `chmod 644 certs/tls.key` for this lab). Docker Desktop on Windows normally isn't affected. |
| Container shows `unhealthy` | Run `docker exec openbao_demo bao status`. It prints the real TLS error (usually a missing `BAO_CACERT` or a SAN mismatch). |
| `openssl` fails with "subject name is expected to be in the format /type0=value0" | Git Bash path mangling. Run `export MSYS_NO_PATHCONV=1` first. |

## What this does and doesn't give you

This encrypts traffic between clients and the server and lets them verify
they're talking to the right one. It is still a lab setup. A real
deployment would use a certificate from a proper CA (an internal PKI or a
public CA such as Let's Encrypt) instead of a self-signed one, and would
also revisit `cluster_addr` and multi-node raft TLS, which this
single-node lab deliberately skips.
