#!/usr/bin/env bash
# Vault-Backup (#101 STEP 3): Raft-Snapshot ziehen, prüfen, mit age verschlüsseln und
# unter /data/backup/<host>/vault ablegen (von dort nimmt Duplicati ihn nach OneDrive mit).
#
# - Snapshot über die API (/v1/sys/storage/raft/snapshot): der von Vault vorgesehene,
#   konsistente Weg bei laufendem Vault. Eine Dateikopie von /vault/data wäre es nicht.
# - AppRole "vault-backup": Policy nur "read" auf sys/storage/raft/snapshot.
# - Klartext existiert nur kurz in einem tmpfs-Verzeichnis unter /run und wird geprüft
#   (tar-Archiv mit SHA256SUMS), dann verschlüsselt und gelöscht.
# - Verschlüsselt mit einem EIGENEN age-Schlüssel (nicht dem SOPS-Schlüssel -- dessen
#   privater Teil liegt in Vault). Auf dem Host liegt nur der öffentliche Teil
#   (scripts/backup/vault-backup.age.pub); der private liegt offline bei den Unseal-Keys.
# - Aufbewahrung: alle Snapshots der letzten 14 Tage, dazu die Sonntags-Snapshots der
#   letzten 8 Wochen.
#
# Aufruf: sudo homelab-deploy backup-vault   (Kestra-Flow backup-vault, täglich)
#         oder direkt: sudo bash scripts/backup/backup_vault_snapshot.sh
# Restore: docs/runbooks/vault-restore.md
set -Eeuo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HOST_SHORT="$(hostname -s)"
TARGET="/data/backup/${HOST_SHORT}/vault"
RECIPIENT_FILE="${HERE}/vault-backup.age.pub"
ROLE_ID_FILE="/opt/docker/secrets/vault_backup_role_id.txt"
SECRET_ID_FILE="/opt/docker/secrets/vault_backup_secret_id.txt"
KEEP_DAYS=14
KEEP_WEEKLY_DAYS=56

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${TARGET}/vault-${STAMP}.snap.age"
START="$(date +%s)"

fail() { echo "FEHLER: $*"; echo "Status: Fehlgeschlagen"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "muss als root laufen"
command -v age >/dev/null || fail "age nicht installiert (apt install age)"
[ -s "$RECIPIENT_FILE" ] || fail "öffentlicher age-Schlüssel fehlt: $RECIPIENT_FILE"
grep -qE '^age1[0-9a-z]+$' "$RECIPIENT_FILE" || fail "$RECIPIENT_FILE ist kein age-Empfänger (age1...)"
[ -r "$ROLE_ID_FILE" ] && [ -r "$SECRET_ID_FILE" ] || fail "AppRole-Dateien vault_backup_* fehlen"

WORK=$(mktemp -d /run/vault-backup.XXXXXX)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "==> Vault-Snapshot $STAMP auf $HOST_SHORT"

VAULT_IP=$(docker inspect vault --format '{{.NetworkSettings.Networks.backend.IPAddress}}') \
  || fail "Vault-Container nicht gefunden"
VAULT="http://${VAULT_IP}:8200"

curl -sf "$VAULT/v1/sys/seal-status" | python3 -c 'import json,sys; sys.exit(1 if json.load(sys.stdin)["sealed"] else 0)' \
  || fail "Vault ist versiegelt oder nicht erreichbar"

TOKEN=$(python3 -c 'import json,sys; print(json.dumps({"role_id": open(sys.argv[1]).read().strip(), "secret_id": open(sys.argv[2]).read().strip()}))' \
          "$ROLE_ID_FILE" "$SECRET_ID_FILE" \
        | curl -sf -X POST --data @- "$VAULT/v1/auth/approle/login" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"]["client_token"])') \
  || fail "AppRole-Login vault-backup fehlgeschlagen"

# Token per Datei an curl (nicht in der Prozessliste sichtbar)
printf 'header = "X-Vault-Token: %s"\n' "$TOKEN" > "$WORK/curl.cfg"
curl -sf -K "$WORK/curl.cfg" -o "$WORK/vault.snap" "$VAULT/v1/sys/storage/raft/snapshot" \
  || fail "Snapshot-Abruf fehlgeschlagen"
curl -sf -K "$WORK/curl.cfg" -X POST "$VAULT/v1/auth/token/revoke-self" >/dev/null || true

SIZE=$(stat -c %s "$WORK/vault.snap")
[ "$SIZE" -gt 1024 ] || fail "Snapshot verdächtig klein ($SIZE Bytes)"
tar -tzf "$WORK/vault.snap" > "$WORK/content.txt" 2>/dev/null || fail "Snapshot ist kein gültiges tar.gz"
grep -q 'SHA256SUMS' "$WORK/content.txt" || fail "Snapshot ohne SHA256SUMS -- unvollständig?"
echo "    Snapshot geprüft: $(numfmt --to=iec "$SIZE"), Inhalt: $(tr '\n' ' ' < "$WORK/content.txt")"

mkdir -p "$TARGET"
chmod 700 "$TARGET"
age -R "$RECIPIENT_FILE" -o "$OUT.tmp" "$WORK/vault.snap" || fail "age-Verschlüsselung fehlgeschlagen"
mv "$OUT.tmp" "$OUT"
chmod 600 "$OUT"
sha256sum "$OUT" | sed "s#  ${TARGET}/#  #" > "$OUT.sha256"
echo "    verschlüsselt: $OUT ($(numfmt --to=iec "$(stat -c %s "$OUT")"))"

# Aufbewahrung: < KEEP_DAYS Tage alles, < KEEP_WEEKLY_DAYS Tage nur Sonntage
DELETED=0
NOW=$(date +%s)
for f in "$TARGET"/vault-*.snap.age; do
  [ -e "$f" ] || continue
  d=$(basename "$f" | sed -E 's/^vault-([0-9]{8})-.*/\1/')
  ts=$(date -d "$d" +%s 2>/dev/null) || continue
  age_days=$(( (NOW - ts) / 86400 ))
  dow=$(date -d "$d" +%u)
  if [ "$age_days" -ge "$KEEP_DAYS" ] && { [ "$dow" != 7 ] || [ "$age_days" -ge "$KEEP_WEEKLY_DAYS" ]; }; then
    rm -f "$f" "$f.sha256"
    DELETED=$((DELETED + 1))
  fi
done

COUNT=$(find "$TARGET" -maxdepth 1 -name 'vault-*.snap.age' | wc -l)
echo "    Aufbewahrung: $COUNT Snapshots vorhanden, $DELETED gelöscht"
echo "Dauer: $(( $(date +%s) - START ))s"
echo "Status: Erfolgreich"
