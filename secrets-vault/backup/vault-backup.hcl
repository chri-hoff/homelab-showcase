# AppRole "vault-backup" (#101 STEP 3): may only take Raft snapshots.
# Used by scripts/backup/backup_vault_snapshot.sh (via homelab-deploy backup-vault).
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
