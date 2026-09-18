ui = true

storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao-demo-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

# Single node, no peers -- api_addr/cluster_addr just have to be
# resolvable from inside this container. Real HA (multiple raft peers,
# retry_join, TLS on the client listener) is a later step, not part of
# "get prod mode working locally" -- see README.md.
api_addr     = "http://127.0.0.1:8200"
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
