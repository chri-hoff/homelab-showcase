# Runbook: restore Vault from a snapshot

Backups: `/data/backup/<host>/vault/vault-YYYYmmdd-HHMMSS.snap.age` (daily, 14 days + 8
Sundays), copied to OneDrive by Duplicati. Created by `scripts/backup/backup_vault_snapshot.sh`.

## What you need (kept offline, NOT in Vault)

| Item | Where |
|---|---|
| age private key of the backup key (`AGE-SECRET-KEY-1...`) | password manager entry "Vault backup age key", next to the unseal keys |
| Unseal keys (threshold) of the production Vault | password manager |
| An admin token of the production Vault (or the unseal keys to generate one) | password manager |

The SOPS age key is **not** needed and would not help: it lives inside Vault.

## Restore test (half-yearly, #101 STEP 4)

Runs a throwaway Vault on the host **without network** (`--network none`), so it can never
be reached by services or confused with production.

```fish
set SNAP (ls -t /data/backup/(hostname -s)/vault/vault-*.snap.age | head -1)
set IMG hashicorp/vault:(yq -r '.services.vault.version' /data/gitea/homelab/config/versions.yaml)
sudo sh -c "cd $(dirname $SNAP) && sha256sum -c $(basename $SNAP).sha256"     # expect: OK

# 1. Decrypt into tmpfs (private key typed/pasted, never written to disk)
sudo mkdir -m 700 /run/vault-restore
read -s -P 'age private key: ' K
printf '%s\n' $K | sudo age -d -i - -o /run/vault-restore/vault.snap $SNAP; set -e K

# 2. Fresh Vault, raft storage, no network
docker run -d --name vault-restore-test --network none --cap-add IPC_LOCK \
  -e 'VAULT_LOCAL_CONFIG={"storage":{"raft":{"path":"/vault/file","node_id":"restore"}},"listener":{"tcp":{"address":"127.0.0.1:8200","tls_disable":true}},"api_addr":"http://127.0.0.1:8200","cluster_addr":"http://127.0.0.1:8201","disable_mlock":true}' \
  $IMG server
function vr; docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 vault-restore-test vault $argv; end
function vrt; docker exec -it -e VAULT_ADDR=http://127.0.0.1:8200 vault-restore-test vault $argv; end   # with TTY for prompts
sleep 5
vr operator init -key-shares=1 -key-threshold=1 -format=json | sudo tee /run/vault-restore/init.json >/dev/null   # temporary keys
vr operator unseal (sudo python3 -c 'import json;print(json.load(open("/run/vault-restore/init.json"))["unseal_keys_b64"][0])')
sudo docker cp /run/vault-restore/vault.snap vault-restore-test:/tmp/vault.snap
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=(sudo python3 -c 'import json;print(json.load(open("/run/vault-restore/init.json"))["root_token"])') vault-restore-test vault operator raft snapshot restore -force /tmp/vault.snap

# 3. After the restore the instance uses the PRODUCTION keyring -> unseal with the real keys
vr status | grep -E 'Sealed|Version'
vrt operator unseal         # repeat until "Sealed false" (production unseal keys)
vrt login                   # production admin token
vr kv list -mount=homelab services | head
vr kv get -mount=homelab -field=webhook_secret services/n8n-webhook >/dev/null; and echo "Secret lesbar"

# 4. Clean up
docker rm -f vault-restore-test
sudo shred -u /run/vault-restore/vault.snap /run/vault-restore/init.json; sudo rmdir /run/vault-restore
```

Expected: `Sealed false` after unsealing with the production keys, the list of service
paths, `Secret lesbar`. The restored node reports `HA Mode standby` with the production node as
"Active Node Address": the Raft peer list in the snapshot still names `vault-1`. Reads work
anyway; `--network none` keeps it from ever contacting production.

First successful test: 2026-10-29 (snapshot `vault-20261029-101002`, 120 KB). Lesson: the
third unseal key must be one not yet entered in this round -- a repeated key is silently
ignored (progress stays at 2/3). Record date and snapshot name in issue #101 (or its successor).

## Real disaster recovery

Same as the test, but on the target machine with the normal compose file
(`services/vault/docker-compose.yaml`, raft path `/vault/data`): start Vault with an empty
data directory, `vault operator init` with throwaway keys, `vault operator raft snapshot
restore -force`, then unseal with the production unseal keys. Keep `node_id = "vault-1"` from `vault.hcl`, so the
restored peer list matches the node; if it still waits as standby, check
`vault operator raft list-peers` and remove stale peers. All AppRoles, policies and
secrets come back as they were at snapshot time; services start normally once Vault is
unsealed. Secrets changed after the snapshot (e.g. rotated AppRole secret IDs) must be
re-issued.
