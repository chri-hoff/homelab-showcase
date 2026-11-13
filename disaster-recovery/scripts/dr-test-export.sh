#!/bin/bash
# Test data for the DR test with data (#157), run on the homelab host. Produces in
# /data/backup/drtest (owned by the repo user, so the laptop can fetch it):
#
#   docker/            slim Borg repo with ONLY the last archive of the docker series
#                      (borg2 transfer; same passphrase as the real repo)
#   vault.snap.age     fresh Raft snapshot of Vault, encrypted to the SOPS age recipient
#                      from .sops.yaml -- the laptop decrypts it with the key it already has
#                      for the .env.sops files. The snapshot itself is barrier-encrypted;
#                      without the unseal keys it is useless.
#   extra.tar          the small bits that live outside /opt/docker on surviving disks:
#                      /data/kestra-state, Kestra's storage on wd-750
#   EXPORTED           timestamp and archive info
#
# The DR test simulates "system disk dead, data disks survive" with these files plus the
# laptop's own repo clone. Nextcloud data and Loki are deliberately not exported.
#
# Run:   sudo bash scripts/maintenance/dr-test-export.sh
# Fetch (laptop): rsync -a --delete tc:/data/backup/drtest/ ~/.local/state/homelab-drtest/data/
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo ausführen."; exit 1; }

# Repo checkout: next to this script, or the host clone if the script was copied
# elsewhere (e.g. "git show ... > /tmp/dr-test-export.sh" from a branch).
HERE=$(cd "$(dirname "$0")/../.." && pwd)
[ -f "$HERE/.sops.yaml" ] || HERE=/data/gitea/homelab
[ -f "$HERE/.sops.yaml" ] || { echo "FEHLER: Repo-Checkout nicht gefunden"; exit 1; }
HOST=$(hostname -s)
SRC=/data/backup/$HOST/docker
OUT=/data/backup/drtest
REPO_USER=$(stat -c %U "$HERE")
SECRETS=/opt/docker/secrets

fail() { echo "FEHLER: $*" >&2; exit 1; }
command -v borg2 >/dev/null || fail "borg2 fehlt"
command -v age >/dev/null || fail "age fehlt"

WORK=$(mktemp -d /run/dr-test-export.XXXXXX)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

vault_ip() { docker inspect vault --format '{{.NetworkSettings.Networks.backend.IPAddress}}'; }
approle_token() {   # $1 = prefix of the role_id/secret_id files in /opt/docker/secrets
  python3 -c 'import json,sys; print(json.dumps({"role_id": open(sys.argv[1]).read().strip(), "secret_id": open(sys.argv[2]).read().strip()}))' \
      "$SECRETS/${1}_role_id.txt" "$SECRETS/${1}_secret_id.txt" \
    | curl -sf -X POST --data @- "http://$(vault_ip):8200/v1/auth/approle/login" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"]["client_token"])'
}

# --- Borg passphrase (same AppRole as the nightly backup) ---
TOKEN=$(approle_token backup_docker_vault) || fail "AppRole backup-docker: Login fehlgeschlagen (Vault versiegelt?)"
printf 'header = "X-Vault-Token: %s"\n' "$TOKEN" > "$WORK/curl.cfg"
BORG_PASSPHRASE=$(curl -sf -K "$WORK/curl.cfg" "http://$(vault_ip):8200/v1/homelab/data/backup/borg-docker" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["data"]["passphrase"])') \
  || fail "Borg-Passphrase nicht lesbar"
curl -sf -K "$WORK/curl.cfg" -X POST "http://$(vault_ip):8200/v1/auth/token/revoke-self" >/dev/null || true
export BORG_PASSPHRASE BORG_OTHER_PASSPHRASE="$BORG_PASSPHRASE"
# The test repo is created as docker.new and then renamed; without this Borg asks
# interactively ("previously located at ...") -- and the prompt is hidden below.
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

# --- Slim Borg repo: only the newest archive ---
read -r LAST_ID LAST < <(borg2 --repo "$SRC" repo-list --last 1 --json \
  | python3 -c 'import json,sys; a=json.load(sys.stdin)["archives"][0]; print(a["id"], a["time"], a["name"])')
echo "==> Letztes Archiv: $LAST"
# Archives made before #164 have no group/other permissions anywhere -- a restore from
# them breaks services. Directories of /opt/docker are normally 755: look for any.
DIRS_OK=$(borg2 --repo "$SRC" list "aid:$LAST_ID" --format '{mode}{NL}' | grep -c '^d......r.x' || true)
[ "$DIRS_OK" -gt 0 ] || fail "Archiv ohne group/other-Rechte (vor dem Fix #164) -- neues Backup abwarten oder von Hand starten"
echo "    Rechte im Archiv ok ($DIRS_OK Verzeichnisse mit r-x für andere)"

mkdir -p "$OUT"
chmod 750 "$OUT"
HAVE_ID=$(borg2 --repo "$OUT/docker" repo-list --last 1 --json 2>/dev/null </dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["archives"][0]["id"])' 2>/dev/null || true)
if [ "$HAVE_ID" = "$LAST_ID" ]; then
  echo "    Test-Repo enthält dieses Archiv schon -- kein Transfer"
else
  rm -rf "$OUT/docker.new"
  borg2 --repo "$OUT/docker.new" repo-create --other-repo "$SRC" --encryption repokey-aes-ocb
  borg2 --repo "$OUT/docker.new" transfer --other-repo "$SRC" --last 1
  borg2 --repo "$OUT/docker.new" check --repository-only
  rm -rf "$OUT/docker"
  mv "$OUT/docker.new" "$OUT/docker"
fi

# --- Vault snapshot, encrypted to the SOPS recipient ---
RECIPIENT=$(python3 -c 'import re,sys; print(re.search(r"age1[0-9a-z]+", open(sys.argv[1]).read()).group(0))' "$HERE/.sops.yaml")
TOKEN=$(approle_token vault_backup) || fail "AppRole vault-backup: Login fehlgeschlagen"
printf 'header = "X-Vault-Token: %s"\n' "$TOKEN" > "$WORK/curl.cfg"
curl -sf -K "$WORK/curl.cfg" -o "$WORK/vault.snap" "http://$(vault_ip):8200/v1/sys/storage/raft/snapshot" \
  || fail "Vault-Snapshot fehlgeschlagen"
curl -sf -K "$WORK/curl.cfg" -X POST "http://$(vault_ip):8200/v1/auth/token/revoke-self" >/dev/null || true
tar -tzf "$WORK/vault.snap" | grep -q SHA256SUMS || fail "Snapshot unvollständig"
age -r "$RECIPIENT" -o "$OUT/vault.snap.age" "$WORK/vault.snap"

# --- Small state outside /opt/docker on surviving disks ---
tar -cf "$OUT/extra.tar" -C / data/kestra-state mnt/wd-750/docker/data/kestra/storage

printf 'exported=%s\nhost=%s\narchive=%s\n' "$(date -Is)" "$HOST" "$LAST" > "$OUT/EXPORTED"
chown -R "$REPO_USER": "$OUT"
echo "==> Fertig: $(du -sh "$OUT" | cut -f1) in $OUT"
cat "$OUT/EXPORTED"
