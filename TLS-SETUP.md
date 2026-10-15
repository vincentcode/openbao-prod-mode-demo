# Turning on TLS (HTTPS) with a CA-signed certificate

Out of the box the listener runs with `tls_disable = true`, so everything
travels as plain HTTP on port 8200. This guide switches it to HTTPS using a
certificate **issued by your CA**. You don't create the certificate
yourself. You generate a private key and a **CSR** (certificate signing
request), send only the CSR to whoever runs the CA, and configure OpenBao
with what they send back.

Your existing data, unseal keys and AppRole stay as they are: TLS only
changes how clients reach the server, not what is in storage, so there is
**no re-init**.

## What you'll change

| File | Change |
|---|---|
| `certs/` (new) | `tls.key` + `tls.csr` from step 1; `tls.crt` + `ca.crt` come back from the CA (step 2) |
| `config.hcl` | Listener gets cert/key paths; `api_addr` becomes `https://<your-fqdn>:8200` |
| `docker-compose.yaml` | Mount `certs/`, point `BAO_ADDR` at the FQDN, add `BAO_CACERT`, fix the healthcheck |

The scripts (`init-and-unseal.sh`, `enable-transit.sh`) need **no
changes**. They run `bao` inside the container via `docker exec`, and
`docker exec` inherits the container's `BAO_ADDR` / `BAO_CACERT` from
`docker-compose.yaml`.

## 1. Generate the private key and CSR

Run this on the server, from the repo directory. The private key is created
here and **never leaves this machine**. The CSR contains only the public
half, which is what you send.

```bash
mkdir -p certs
FQDN=openbao.example.com        # <- the real DNS name clients will use to reach this server

openssl req -new -newkey rsa:2048 -nodes \
  -keyout certs/tls.key -out certs/tls.csr \
  -subj "/CN=$FQDN" \
  -addext "subjectAltName=DNS:$FQDN"
```

Notes on the command:
- **The name in `subjectAltName` is what actually gets validated**, not the
  CN. It must be the exact DNS name clients connect with. Add more names
  comma-separated (`DNS:$FQDN,DNS:openbao.internal`).
- If clients also connect by IP and your CA allows IP SANs, add
  `IP:203.0.113.10`. Public CAs won't issue certs for IPs or `localhost`.
- If the CA asks for more subject fields, extend `-subj`, for example
  `"/C=US/ST=State/L=City/O=Company/CN=$FQDN"`.
- `-nodes` leaves the key unencrypted, which the server needs so it can
  start without someone typing a passphrase.
- `-addext` needs OpenSSL 1.1.1 or newer (`openssl version`).
- On **Git Bash for Windows**, run `export MSYS_NO_PATHCONV=1` first, or it
  rewrites `/CN=...` into a file path.

Check the CSR before sending it:

```bash
openssl req -in certs/tls.csr -noout -text | grep -E "Subject:|DNS:"
```

**Keep `tls.key` secret and out of git.** `.gitignore` already covers
`*.key`; also add `certs/` so the whole folder stays local. If you lose the
key, the CA has to issue a new certificate.

## 2. Send the CSR to the CA and collect what comes back

Send **only `certs/tls.csr`**. Ask for the results in **PEM** format:

| You receive | Save as | What it is |
|---|---|---|
| Your server certificate | `certs/tls.crt` | The certificate issued for your FQDN |
| Intermediate certificate(s), if any | append to `certs/tls.crt` | See below |
| Root / issuing CA certificate(s) | `certs/ca.crt` | What clients use to trust the server |

**Build `tls.crt` as a full chain: your server cert first, then the
intermediates.** OpenBao presents this file as-is, and clients that don't
already have the intermediates can't verify a bare leaf.

```bash
cat server.pem intermediate.pem > certs/tls.crt
```

Some CAs hand you a ready-made "fullchain" or "bundle" file. Use that as
`tls.crt`.

Sanity-check what you got before touching the server:

```bash
# Does the certificate match your private key? (the two outputs must be identical)
diff <(openssl x509 -in certs/tls.crt -noout -pubkey) <(openssl pkey -in certs/tls.key -pubout) && echo "key matches"

# Right name, and not expired?
openssl x509 -in certs/tls.crt -noout -subject -dates -ext subjectAltName

# Does it chain to the CA cert?
openssl verify -CAfile certs/ca.crt certs/tls.crt
```

### While you wait for the CA

Issuance can take a while. Until the cert arrives, keep the listener on
`tls_disable = true`, but don't expose it. In `docker-compose.yaml`, publish
the port on loopback only (`"127.0.0.1:8200:8200"`), so nothing off the box
can reach the plain-HTTP listener. Change it back to `"8200:8200"` in step 4.

## 3. Key file permissions

The server process in the container runs as a non-root user, and the key is
mounted read-only from the host. On a **Linux host**, that user must be able
to read `certs/tls.key`, but nobody else should.

```bash
# Find the container user's uid/gid
docker run --rm --entrypoint id openbao/openbao:2.6.2 openbao

sudo chown root:<gid> certs/tls.key
sudo chmod 640 certs/tls.key
```

Docker Desktop on Windows/macOS normally doesn't need this step.

## 4. Update `config.hcl`

Replace the listener block, and change `api_addr` to the FQDN over `https`:

```hcl
listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/openbao/tls/tls.crt"
  tls_key_file    = "/openbao/tls/tls.key"
  tls_min_version = "tls12"
}

api_addr     = "https://openbao.example.com:8200"    # your real FQDN
cluster_addr = "http://127.0.0.1:8201"               # unchanged
```

`tls_disable` is gone; it defaults to `false`. `cluster_addr` is the
node-to-node port, which is irrelevant on a single node, so leave it alone.

## 5. Update `docker-compose.yaml`

```yaml
services:
  openbao:
    ports:
      - "8200:8200"
    # The cert is issued for your FQDN, not 127.0.0.1. Point the name at the
    # container itself so in-container `bao` calls (scripts, healthcheck)
    # connect by a name the cert is valid for.
    extra_hosts:
      - "openbao.example.com:127.0.0.1"
    environment:
      BAO_ADDR: "https://openbao.example.com:8200"
      BAO_CACERT: "/openbao/tls/ca.crt"
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

Replace `openbao.example.com` with your FQDN in all three places
(`extra_hosts`, `BAO_ADDR`, and `config.hcl` above).

The healthcheck changes because the old `wget http://...` check would now
hit an HTTPS port. Using `bao status` also means the check fails if the
cert is broken.

## 6. Apply it

`config.hcl` is a bind mount, so recreate the container to be sure it picks
up both files. It comes back **sealed**, as after any restart.

```bash
docker compose up -d --force-recreate
```

Then unseal, as you normally do (see [UNSEALING.md](UNSEALING.md)).

## 7. Verify

```bash
# Inside the container (uses BAO_ADDR + BAO_CACERT from compose)
docker exec openbao_demo bao status

# From another machine, using the CA cert
curl --cacert certs/ca.crt https://openbao.example.com:8200/v1/sys/health

# Before DNS exists for the name, force it to resolve to this server
curl --cacert certs/ca.crt --resolve openbao.example.com:8200:<server-ip> \
  https://openbao.example.com:8200/v1/sys/health

# See what the server actually presents (chain included)
openssl s_client -connect openbao.example.com:8200 -servername openbao.example.com -showcerts </dev/null

# Plain HTTP should now be refused
curl http://openbao.example.com:8200/v1/sys/health
# -> Client sent an HTTP request to an HTTPS server.
```

## 8. Point clients at HTTPS

Clients need to trust your CA. If it's a public CA, their system trust
store already does. For an internal CA, give them `certs/ca.crt`.

**`bao` CLI on another machine**

```bash
export BAO_ADDR=https://openbao.example.com:8200
export BAO_CACERT=/path/to/ca.crt      # not needed for a publicly trusted CA
```

**Browser UI**: open `https://openbao.example.com:8200/ui`. No warning for
a public CA. For an internal CA, install `ca.crt` into the OS or browser
trust store (usually your IT team already pushes this to managed machines).

**Python (`hvac`)**: use the FQDN, and pass the CA cert as `verify` if the
CA isn't publicly trusted. Never use `verify=False`, which throws away the
protection you just set up.

```python
client = hvac.Client(url="https://openbao.example.com:8200", verify="/path/to/ca.crt")
```

**`enable-transit.sh` output**: it prints `OPENBAO_ADDR=http://localhost:8200`
for your app's env. Use `https://<your-fqdn>:8200` there, and give the app
the CA cert path if needed.

## 9. Renewing the certificate

Certificates expire, so note the `notAfter` date from step 2 and start the
renewal early. Repeat steps 1 to 2 (you can reuse the existing key by
swapping `-newkey rsa:2048 -nodes -keyout certs/tls.key` for
`-key certs/tls.key`, or generate a fresh key, which is the better practice),
replace `certs/tls.crt`, then reload the listener. No restart or re-unseal is
needed:

```bash
docker kill -s HUP openbao_demo
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `x509: certificate signed by unknown authority` | Client doesn't trust the CA. Set `BAO_CACERT` (or `verify=`) to `ca.crt`, or install it in the trust store. |
| `x509: certificate is valid for X, not Y` | The name you connect with isn't in the certificate's SAN. Connect by the FQDN, or generate a new CSR that includes the extra name. |
| Errors mentioning `127.0.0.1` when running the scripts | `BAO_ADDR` still points at the IP, or `extra_hosts` is missing. See step 5. |
| Browsers or clients complain about a missing/incomplete chain | `tls.crt` holds only the leaf. Rebuild it as leaf + intermediates (step 2). |
| `tls: private key does not match public key` at startup | `tls.crt` and `tls.key` aren't a pair (for example, a CSR re-made after the cert was issued). Run the `diff` check in step 2. |
| `server gave HTTP response to HTTPS client` | Client still using `http://`. Check `BAO_ADDR`. |
| `Client sent an HTTP request to an HTTPS server` | Opposite mistake: `http://` used against the TLS listener. |
| Container exits or restarts with a permission error on the key | The container user can't read `tls.key`. See step 3. |
| Container shows `unhealthy` | Run `docker exec openbao_demo bao status`. It prints the real TLS error (usually a missing `BAO_CACERT` or a name mismatch). |
| `openssl` fails with "subject name is expected to be in the format /type0=value0" | Git Bash path mangling. Run `export MSYS_NO_PATHCONV=1` first. |

## What this does and doesn't cover

This encrypts traffic between clients and the server, and lets them verify
they're talking to the right one, using a certificate your CA vouches for.
It is still a single-node setup: `cluster_addr` and multi-node raft TLS
(`retry_join`, peer certificates) are deliberately left out.
