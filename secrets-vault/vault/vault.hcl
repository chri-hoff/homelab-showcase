storage "raft" {
  path    = "/vault/data"
  node_id = "vault-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

disable_mlock = true
api_addr      = "https://vault.example.com"
cluster_addr  = "https://vault:8201"
ui            = true
