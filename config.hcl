ui = true

storage "raft" {
  path    = "/openbao/file"
  # Unique, stable ID for this node within the raft cluster -- tied to
  # the server's own hostname so it stays identifiable if peers are
  # ever added (`bao operator raft list-peers`). Changing this later
  # means rejoining as a new node, not a rename -- pick it deliberately.
  node_id = "openbao-xxx"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/openbao/tls/tls.crt"
  tls_key_file    = "/openbao/tls/tls.key"
  tls_min_version = "tls12"
}

# Single node, no peers -- cluster_addr just has to be resolvable from
# inside this container. Real HA (multiple raft peers, retry_join, TLS
# on the client listener) is a later step, not part of "get prod mode
# working locally" -- see README.md.
#
# api_addr uses xxx, not 127.0.0.1, because that's the name the TLS
# cert in ./certs was issued for (see docker-compose.yaml's BAO_ADDR
# and extra_hosts, which point that name back at this container).
api_addr     = "https://xxx:8200"
cluster_addr = "http://127.0.0.1:8201"

# Prod mode wants to mlock secrets out of swap; the IPC_LOCK capability
# that requires isn't something most local Docker setups grant (and
# doesn't matter much for a laptop that isn't swapping to a shared
# disk), so this is disabled deliberately, not an oversight.
disable_mlock = true

# OpenBao 2.x moved audit-device configuration out of the API (`bao
# audit enable ...` now fails with "use declarative, config-based audit
# device management instead") and into here, specifically so an
# attacker with a root/admin token can no longer silently disable
# auditing at runtime -- only someone who can edit this file and
# restart the server can. Path matches Transit's own audit log, inside
# the already-writable /openbao/file volume (see docker-compose.yaml).
audit "file" {
  type = "file"
  path = "file/"

  options = {
    file_path = "/openbao/file/audit.log"
  }
}
