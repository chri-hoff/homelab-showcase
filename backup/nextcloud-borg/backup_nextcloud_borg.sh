#!/usr/bin/env bash
# Nextcloud backup with Borg2:
#   1. maintenance mode on
#   2. MariaDB dump to /tmp
#   3. borg create (data + config + DB dump)
#   4. maintenance mode off
#   5. borg prune + compact
#   6. Telegram notification
# Requires: borg2, docker, flock (util-linux), jq; Vault AppRole "backup-nextcloud"

set -Eeuo pipefail

# -----------------------------
# Block 1: variables
# -----------------------------
BACKUP_NAME="nextcloud"
HOST="${HOSTNAME:-$(hostname -s)}"
BACKUPTIME="$(date -u +%Y-%m-%dT%H%M%SZ)"
# Fixed name on purpose: in Borg 2 archives with the same name form a series, and
# both the files cache and prune work per series. A timestamp in the name made every
# run a new series -> no files cache (every file re-chunked, ~4 h for ~760 GB) and
# prune never deleted anything. Borg stores the timestamp itself; the ID is unique.
ARCHIVE="${BACKUP_NAME}"

BORG_REPO="/mnt/bk_nxc_data/${BACKUP_NAME}"
LOG_DIR="/data/backup/${HOST}/log"
LOG="${LOG_DIR}/${BACKUP_NAME}.log"
LOG_ZEILEN_MAX=2000

NC_CONTAINER="nextcloud"
MARIADB_CONTAINER="mariadb"
NC_DATA="/mnt/nextcloud"
NC_CONFIG="/opt/docker/nextcloud"
NC_DB="nextcloud"

DB_DUMP_DIR="/tmp/borg_nc_dump"
DB_DUMP_FILE="${DB_DUMP_DIR}/nextcloud_db.sql.gz"

# Borg passphrase from Vault (AppRole "backup-nextcloud", read-only on this one path).
# Bootstrap credentials are root-only files, same pattern as the containers' Docker secrets.
VAULT_CONTAINER="vault"
VAULT_ROLE_ID_FILE="/opt/docker/secrets/backup_nextcloud_vault_role_id.txt"
VAULT_SECRET_ID_FILE="/opt/docker/secrets/backup_nextcloud_vault_secret_id.txt"
VAULT_BORG_PATH="backup/borg-nextcloud"   # KV v2, mount "homelab", key "passphrase"

LOCKDIR="/var/lock"
LOCKFILE="${LOCKDIR}/backup-${HOST}-${BACKUP_NAME}.lock"

# Telegram: same bot/chat credentials as scripts/vault/check_vault_sealed.sh. Kept
# deliberately outside Vault (root-only file) so failure alerts still arrive when
# Vault is down. Format: TELEGRAM_BOT_TOKEN=... / TELEGRAM_CHAT_ID=...
TELEGRAM_CRED_FILE="/opt/docker/secrets/vault-unseal-alert.env"

START_TIME_EPOCH="$(date +%s)"
START_TIME_HUMAN="$(date '+%F %T')"
ERRORS=0
maintenance_enabled=0

# -----------------------------
# Block 2: Logging
# -----------------------------
json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

log_json() {
  local level="$1" message="$2" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"timestamp":"%s","level":"%s","job":"%s","host":"%s","message":"%s"}\n' \
    "$ts" "$(json_escape "$level")" "$(json_escape "$BACKUP_NAME")" \
    "$(json_escape "$HOST")" "$(json_escape "$message")" >> "$LOG"
}

mail_info()  { printf '[INFO]  %s\n' "$1"; }
mail_warn()  { printf '[WARN]  %s\n' "$1" >&2; }
mail_error() { printf '[ERROR] %s\n' "$1" >&2; }

log_info()  { log_json "INFO"  "$1"; }
log_warn()  { log_json "WARN"  "$1"; }
log_error() { log_json "ERROR" "$1"; }

info() { log_info "$1";  mail_info "$1"; }
warn() { log_warn "$1";  mail_warn "$1"; }

error() {
  ERRORS=$((ERRORS + 1))
  log_error "$1"
  mail_error "$1"
}

fail() {
  error "$1"
  exit "${2:-1}"
}

log_file_trim() {
  local tmp="${LOG}.tmp"
  tail -n "$LOG_ZEILEN_MAX" "$LOG" > "$tmp" && mv "$tmp" "$LOG"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 nicht gefunden (PATH=$PATH)"
}

run_and_log() {
  local desc="$1" fail_level="$2"
  shift 2
  local tmp rc=0 line
  tmp="$(mktemp)"
  "$@" >"$tmp" 2>&1 || rc=$?
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if [ "$rc" -eq 0 ]; then
      log_info "${desc}: ${line}"
    else
      case "$fail_level" in
        WARN) log_warn  "${desc}: ${line}" ;;
        *)    log_error "${desc}: ${line}" ;;
      esac
    fi
  done < "$tmp"
  rm -f "$tmp"
  return "$rc"
}

# -----------------------------
# Block 3: Telegram
# -----------------------------
# Never fails the backup: a missing credentials file or a failed request only logs a
# warning. The token never appears on a command line (visible via ps): curl reads the
# URL from a config passed through a pipe, and jq gets chat ID and text via env.
send_telegram() {
  local text="$1"
  if [ ! -r "$TELEGRAM_CRED_FILE" ]; then
    log_warn "Telegram-Credentials nicht lesbar (${TELEGRAM_CRED_FILE}) -- keine Benachrichtigung"
    return 0
  fi
  (
    set +e
    # shellcheck disable=SC1090
    . "$TELEGRAM_CRED_FILE"
    TG_CHAT="$TELEGRAM_CHAT_ID" TG_TEXT="$text" \
      jq -n '{chat_id: env.TG_CHAT, text: env.TG_TEXT}' \
      | curl -fsS -K <(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN") \
          -H "Content-Type: application/json" --data-binary @- >/dev/null
  ) || log_warn "Telegram-Benachrichtigung fehlgeschlagen"
}

# -----------------------------
# Block 4: cleanup / EXIT trap
# -----------------------------
cleanup() {
  local rc=$?

  # Make sure maintenance mode gets switched off
  if [ "$maintenance_enabled" -eq 1 ]; then
    if docker exec -u 33 "$NC_CONTAINER" php occ maintenance:mode --off >/dev/null 2>&1; then
      log_warn "Cleanup-Trap: Maintenance-Mode wurde abgeschaltet"
      mail_warn "Cleanup-Trap: Maintenance-Mode wurde abgeschaltet"
    else
      log_error "Cleanup-Trap: Maintenance-Mode konnte NICHT abgeschaltet werden!"
      mail_error "Cleanup-Trap: Maintenance-Mode konnte NICHT abgeschaltet werden!"
    fi
  fi

  # Clean up DB dump
  rm -rf "$DB_DUMP_DIR"

  # Truncate log file
  [ -f "$LOG" ] && log_file_trim || true

  # Send Telegram notification
  local end_epoch end_human duration title status
  end_epoch="$(date +%s)"
  end_human="$(date '+%F %T')"
  duration="$((end_epoch - START_TIME_EPOCH))"

  if [ "$rc" -eq 0 ] && [ "$ERRORS" -eq 0 ]; then
    title="✅ Nextcloud Backup erfolgreich"
    status="Erfolgreich"
  else
    title="❌ Nextcloud Backup fehlgeschlagen"
    status="Fehlgeschlagen (rc=${rc}, Fehler=${ERRORS})"
  fi

  send_telegram "${title}

Host:   ${HOST}
Archiv: ${ARCHIVE} (${BACKUPTIME})
Status: ${status}

Start: ${START_TIME_HUMAN}
Ende:  ${end_human}
Dauer: ${duration}s"

  if [ "$rc" -eq 0 ]; then
    log_info "Skript beendet"
  else
    log_error "Skript beendet mit Fehlercode ${rc}"
  fi

  exit "$rc"
}
trap cleanup EXIT

# -----------------------------
# Block 5: preconditions
# -----------------------------
mkdir -p "$LOG_DIR" "$LOCKDIR"
: > "$LOG"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  fail "Backup läuft bereits (Lock: $LOCKFILE)"
fi

info "=== Start Nextcloud-Backup ==="
info "Host:   ${HOST}"
info "Repo:   ${BORG_REPO}"
info "Archiv: ${ARCHIVE} (${BACKUPTIME})"

require_cmd borg2
require_cmd docker
require_cmd flock
require_cmd jq

# Fetch the Borg passphrase from Vault before maintenance mode, so a sealed Vault fails
# the run without any downtime. Vault has no published port; the CLI inside the vault
# container talks to it on localhost. role_id/secret_id go in as JSON on stdin
# ("vault write ... -"), never as arguments, so they do not show up in ps. The empty-token
# check matters: with an empty VAULT_TOKEN the CLI would fall back to a token file left
# by an interactive "vault login" in that container and read with admin rights.
[ -r "$VAULT_ROLE_ID_FILE" ]   || fail "Vault role_id nicht lesbar: $VAULT_ROLE_ID_FILE"
[ -r "$VAULT_SECRET_ID_FILE" ] || fail "Vault secret_id nicht lesbar: $VAULT_SECRET_ID_FILE"
BORG_PASSPHRASE="$(
  jq -n --rawfile r "$VAULT_ROLE_ID_FILE" --rawfile s "$VAULT_SECRET_ID_FILE" \
    '{role_id: ($r | rtrimstr("\n")), secret_id: ($s | rtrimstr("\n"))}' \
  | docker exec -i -e VAULT_BORG_PATH="$VAULT_BORG_PATH" "$VAULT_CONTAINER" sh -c '
      export VAULT_ADDR=http://localhost:8200
      VAULT_TOKEN="$(vault write -field=token auth/approle/login -)" || exit 1
      [ -n "$VAULT_TOKEN" ] || exit 1
      export VAULT_TOKEN
      exec vault kv get -mount=homelab -field=passphrase "$VAULT_BORG_PATH"'
)" || fail "Borg-Passphrase konnte nicht aus Vault gelesen werden (versiegelt? AppRole?)"
[ -n "$BORG_PASSPHRASE" ] || fail "Borg-Passphrase aus Vault ist leer"
export BORG_PASSPHRASE
info "Borg-Passphrase aus Vault geladen"

# Check / initialize Borg repo
mkdir -p "$BORG_REPO"
if run_and_log "borg info" "WARN" borg2 --repo "$BORG_REPO" info; then
  info "Borg-Repo vorhanden"
else
  warn "Borg-Repo nicht initialisiert – initialisiere"
  run_and_log "borg repo-create" "ERROR" \
    borg2 repo-create --repo "$BORG_REPO" --encryption=repokey-aes-ocb \
    || fail "Borg-Repo konnte nicht initialisiert werden"
  info "Borg-Repo initialisiert"
fi

# -----------------------------
# Block 6: maintenance mode on
# -----------------------------
info "Nextcloud Maintenance-Mode wird aktiviert"
docker exec -u 33 "$NC_CONTAINER" php occ maintenance:mode --on \
  || fail "Maintenance-Mode konnte nicht aktiviert werden"
maintenance_enabled=1
info "Maintenance-Mode aktiv"

# -----------------------------
# Block 7: MariaDB dump
# -----------------------------
info "Starte MariaDB-Dump der Datenbank '${NC_DB}'"
mkdir -p "$DB_DUMP_DIR"

docker exec "$MARIADB_CONTAINER" test -r /vault-secrets/root_password.txt \
  || fail "Datenbankpasswort konnte nicht gelesen werden"

# The password never leaves the container and never appears on a command line
# (visible via ps): the shell inside the container reads it and hands it to
# mariadb-dump via MYSQL_PWD. gzip runs on the host so pipefail catches a
# failing dump (inside "sh -c" only gzip's exit code would count).
docker exec -e NC_DB="$NC_DB" "$MARIADB_CONTAINER" \
  sh -c 'MYSQL_PWD="$(cat /vault-secrets/root_password.txt)" exec mariadb-dump -u root --single-transaction "$NC_DB"' \
  | gzip > "$DB_DUMP_FILE" \
  || fail "MariaDB-Dump fehlgeschlagen"

[ -s "$DB_DUMP_FILE" ] || fail "DB-Dump ist leer: ${DB_DUMP_FILE}"
gzip -t "$DB_DUMP_FILE"    || fail "DB-Dump beschädigt (gzip-Test fehlgeschlagen)"

info "DB-Dump OK: $(du -h "$DB_DUMP_FILE" | awk '{print $1}')"

# -----------------------------
# Block 8: Borg create
# -----------------------------
info "Borg Backup wird erstellt"
# auto,zstd,3 instead of lzma,6: the first full run (~760 GB, mostly photos/videos) was
# CPU-bound at ~3.6 MB/s while lzma saved only ~7 %. "auto" stores incompressible
# chunks uncompressed. Existing lzma chunks in the repo stay valid.
run_and_log "borg create" "ERROR" \
  borg2 --repo "$BORG_REPO" create \
    "$ARCHIVE" \
    "$NC_DATA" \
    "$NC_CONFIG" \
    "$DB_DUMP_DIR" \
    --compression auto,zstd,3 \
    --exclude-caches \
    --info --show-rc --stats \
  || fail "borg create fehlgeschlagen"
info "Backup-Archiv erstellt"

# -----------------------------
# Block 9: maintenance mode off
# -----------------------------
docker exec -u 33 "$NC_CONTAINER" php occ maintenance:mode --off \
  || error "Maintenance-Mode konnte nicht deaktiviert werden – bitte manuell prüfen!"
maintenance_enabled=0
info "Maintenance-Mode deaktiviert"

# Remove the temporary DB dump (borg has already archived it)
rm -rf "$DB_DUMP_DIR"

# -----------------------------
# Block 10: Prune + Compact
# -----------------------------
info "Alte Archive bereinigen (prune)"
# Explicitly only this series, so archives under other names are never touched.
run_and_log "borg prune" "WARN" \
  borg2 prune --repo "$BORG_REPO" "$ARCHIVE" \
    --keep-within  2d \
    --keep-daily  14  \
    --keep-weekly  8  \
    --keep-monthly 12 \
    --list --show-rc \
  || warn "borg prune fehlgeschlagen"

info "Speicherplatz freigeben (compact)"
run_and_log "borg compact" "WARN" \
  borg2 compact --repo "$BORG_REPO" \
  || warn "borg compact fehlgeschlagen"

# Log the latest archive for verification
run_and_log "borg info letztes Archiv" "WARN" \
  borg2 --repo "$BORG_REPO" info --last 1 \
  || warn "Konnte letztes Archiv nicht auslesen"

info "=== Nextcloud-Backup abgeschlossen ==="
