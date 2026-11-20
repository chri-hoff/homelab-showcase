#!/usr/bin/env bash
# Off-site copy of the Nextcloud Borg repo to a Hetzner Storage Box (#202).
#   1. take the same lock as backup_nextcloud_borg.sh (never copy a repo Borg is writing)
#   2. rsync pass 1: only new data objects, no deletes
#   3. rsync pass 2: metadata (archives, index, config, keys) + --delete
#   4. dry run: remote must match the local repo
#   5. Telegram notification
#
# Why two passes: after pass 1 every chunk the new archive references is already remote,
# so an interrupted pass 2 never leaves a copy whose archives point at missing data.
# Chunks freed by "borg compact" are deleted only at the very end.
#
# Protection against a mirrored disaster (ransomware, broken repo, --delete) is NOT in this
# script: the Storage Box takes automatic snapshots, which can only be managed in the Hetzner
# Console, not over SSH. This host's key cannot delete them.
#
# No Borg passphrase needed: the repo is copied as-is (encrypted, repokey-aes-ocb).
# Requires: rsync, ssh, flock (util-linux), jq, curl, timeout (coreutils)

set -Eeuo pipefail

# -----------------------------
# Block 1: variables
# -----------------------------
BACKUP_NAME="offsite-nextcloud"
HOST="${HOSTNAME:-$(hostname -s)}"

LOCAL_REPO="/mnt/bk_nxc_data/nextcloud"
# Same lock file as backup_nextcloud_borg.sh (backup-<host>-nextcloud.lock)
LOCKFILE="/var/lock/backup-${HOST}-nextcloud.lock"
LOCK_WAIT=7200   # s; normally the 01:00 backup is long done when this starts

LOG_DIR="/data/backup/${HOST}/log"
LOG="${LOG_DIR}/${BACKUP_NAME}.log"
LOG_ZEILEN_MAX=2000

# Connection settings, root-only, NOT in the repo (Storage Box ID is private):
#   STORAGEBOX_USER=u123456-sub1
#   STORAGEBOX_HOST=u123456.your-storagebox.de
#   STORAGEBOX_DIR=nextcloud           # relative to the sub-account's base directory
#   RSYNC_BWLIMIT=                     # optional, KiB/s (rsync --bwlimit), empty = unlimited
#   MAX_RUNTIME=20h                    # optional, see below
CONF_FILE="/opt/docker/secrets/offsite-storagebox.env"
SSH_KEY="/opt/docker/secrets/offsite_storagebox_ed25519"
KNOWN_HOSTS="/opt/docker/secrets/offsite_storagebox_known_hosts"

# Initial upload (~760 GB) takes more than one night. The run stops after MAX_RUNTIME so the
# lock is free again for the 01:00 Nextcloud backup; the next night continues where this one
# stopped (rsync --partial, already-copied objects are skipped). A stopped run counts as
# NOT successful (no "Skript beendet" line), so the system check keeps reporting until the
# copy is complete -- that is intended.
MAX_RUNTIME_DEFAULT="20h"

TELEGRAM_CRED_FILE="/opt/docker/secrets/vault-unseal-alert.env"

# Tells the Grafana rule "Ungewöhnlich viel ausgehender Traffic" that this upload is a
# known backup (node_exporter textfile collector, dir created by the Ansible role backup).
# Set to 1 while transferring, 0 in the EXIT trap. The rule only trusts it for 24 h after
# the start timestamp, so a run killed with SIGKILL cannot mute the alert for good.
METRIC_DIR="/var/lib/node_exporter/textfile"
METRIC_FILE="${METRIC_DIR}/backup_upload_${BACKUP_NAME}.prom"

START_TIME_EPOCH="$(date +%s)"
START_TIME_HUMAN="$(date '+%F %T')"
ERRORS=0
TIMED_OUT=0
UPLOAD_METRIC_SET=0

# -----------------------------
# Block 2: logging (same JSON format as the other backup scripts -> system-check.py)
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
  local prio=info
  case "$level" in ERROR) prio=err ;; WARN) prio=warning ;; esac
  logger -t "backup-${BACKUP_NAME}" -p "user.${prio}" -- "$message" 2>/dev/null || true
}

info()  { log_json "INFO" "$1"; printf '[INFO]  %s\n' "$1"; }
warn()  { log_json "WARN" "$1"; printf '[WARN]  %s\n' "$1" >&2; }
error() { ERRORS=$((ERRORS + 1)); log_json "ERROR" "$1"; printf '[ERROR] %s\n' "$1" >&2; }
fail()  { error "$1"; exit "${2:-1}"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 nicht gefunden (PATH=$PATH)"
}

# Atomic write (tmp + mv in the same dir), world-readable: node_exporter runs as nobody.
# Never fails the run -- without the file the alert may fire, which is the safe side.
write_upload_metric() {
  local running="$1" tmp
  [ -d "$METRIC_DIR" ] || { log_json "WARN" "Metrik-Verzeichnis fehlt: ${METRIC_DIR}"; return 0; }
  tmp="$(mktemp "${METRIC_DIR}/.backup_upload.XXXXXX")" || return 0
  {
    echo '# HELP homelab_backup_upload_running 1 while a known backup upload is transferring.'
    echo '# TYPE homelab_backup_upload_running gauge'
    echo "homelab_backup_upload_running{backup=\"${BACKUP_NAME}\"} ${running}"
    echo '# HELP homelab_backup_upload_started_timestamp_seconds Start of the current or last run.'
    echo '# TYPE homelab_backup_upload_started_timestamp_seconds gauge'
    echo "homelab_backup_upload_started_timestamp_seconds{backup=\"${BACKUP_NAME}\"} ${START_TIME_EPOCH}"
  } > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$METRIC_FILE" || rm -f "$tmp"
}

# -----------------------------
# Block 3: Telegram (never fails the run; token never on a command line)
# -----------------------------
send_telegram() {
  local text="$1"
  if [ ! -r "$TELEGRAM_CRED_FILE" ]; then
    log_json "WARN" "Telegram-Credentials nicht lesbar (${TELEGRAM_CRED_FILE}) -- keine Benachrichtigung"
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
  ) || log_json "WARN" "Telegram-Benachrichtigung fehlgeschlagen"
}

# -----------------------------
# Block 4: cleanup / EXIT trap
# -----------------------------
cleanup() {
  local rc=$?
  [ "$UPLOAD_METRIC_SET" -eq 1 ] && write_upload_metric 0
  if [ -f "$LOG" ]; then
    tail -n "$LOG_ZEILEN_MAX" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG" || true
  fi

  local end_human duration title status
  end_human="$(date '+%F %T')"
  duration="$(( $(date +%s) - START_TIME_EPOCH ))"

  if [ "$rc" -eq 0 ] && [ "$ERRORS" -eq 0 ]; then
    title="✅ Nextcloud Off-site-Kopie aktuell"
    status="Erfolgreich"
  elif [ "$TIMED_OUT" -eq 1 ]; then
    title="⏸️ Nextcloud Off-site-Kopie unvollständig"
    status="Laufzeitlimit erreicht, wird nächste Nacht fortgesetzt"
  else
    title="❌ Nextcloud Off-site-Kopie fehlgeschlagen"
    status="Fehlgeschlagen (rc=${rc}, Fehler=${ERRORS})"
  fi

  send_telegram "${title}

Host:   ${HOST}
Status: ${status}
${SUMMARY:-}
Start: ${START_TIME_HUMAN}
Ende:  ${end_human}
Dauer: $((duration / 3600))h $((duration % 3600 / 60))m"

  if [ "$rc" -eq 0 ]; then
    log_json "INFO" "Skript beendet"
  else
    log_json "ERROR" "Skript beendet mit Fehlercode ${rc}"
  fi
  exit "$rc"
}
trap cleanup EXIT

# -----------------------------
# Block 5: preconditions
# -----------------------------
mkdir -p "$LOG_DIR"
: > "$LOG"

require_cmd rsync
require_cmd ssh
require_cmd flock
require_cmd jq
require_cmd timeout

[ -r "$CONF_FILE" ]   || fail "Konfiguration nicht lesbar: $CONF_FILE"
[ -r "$SSH_KEY" ]     || fail "SSH-Key nicht lesbar: $SSH_KEY"
[ -s "$KNOWN_HOSTS" ] || fail "known_hosts fehlt oder ist leer: $KNOWN_HOSTS"
# shellcheck disable=SC1090
. "$CONF_FILE"
: "${STORAGEBOX_USER:?STORAGEBOX_USER fehlt in $CONF_FILE}"
: "${STORAGEBOX_HOST:?STORAGEBOX_HOST fehlt in $CONF_FILE}"
STORAGEBOX_DIR="${STORAGEBOX_DIR:-nextcloud}"
MAX_RUNTIME="${MAX_RUNTIME:-$MAX_RUNTIME_DEFAULT}"

# A missing or empty source must never reach "rsync --delete" (it would empty the copy;
# the snapshots would still have it, but that is the last line, not the first).
[ -d "$LOCAL_REPO" ] || fail "Lokales Repo fehlt: $LOCAL_REPO (Platte nicht gemountet?)"
[ -e "$LOCAL_REPO/config" ] \
  || fail "Lokales Repo sieht nicht wie ein Borg-Repo aus (kein config/): $LOCAL_REPO"

exec 9>"$LOCKFILE"
info "Warte auf Lock ${LOCKFILE} (max. ${LOCK_WAIT}s)"
flock -w "$LOCK_WAIT" 9 || fail "Lock nicht bekommen -- läuft das Nextcloud-Backup noch?"

info "=== Start Off-site-Kopie Nextcloud ==="
write_upload_metric 1
UPLOAD_METRIC_SET=1
info "Quelle: ${LOCAL_REPO}"
info "Ziel:   Storage Box, Verzeichnis ${STORAGEBOX_DIR}"
info "Limit:  ${MAX_RUNTIME}${RSYNC_BWLIMIT:+, ${RSYNC_BWLIMIT} KiB/s}"

# Storage Box: SSH/rsync on port 23. BatchMode = never prompt; StrictHostKeyChecking with
# our own known_hosts = a changed host key fails the run instead of being accepted.
SSH_CMD="ssh -p 23 -i ${SSH_KEY} -o IdentitiesOnly=yes -o BatchMode=yes"
SSH_CMD+=" -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${KNOWN_HOSTS}"
SSH_CMD+=" -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
REMOTE="${STORAGEBOX_USER}@${STORAGEBOX_HOST}:${STORAGEBOX_DIR}/"

RSYNC_OPTS=(-a --partial --partial-dir=.rsync-partial --timeout=600
            --exclude=/locks/ --exclude=/.rsync-partial/ -e "$SSH_CMD")
if [ -n "${RSYNC_BWLIMIT:-}" ]; then RSYNC_OPTS+=(--bwlimit="$RSYNC_BWLIMIT"); fi

# One deadline for both passes. MAX_RUNTIME: seconds, or with suffix m / h.
to_seconds() {
  case "$1" in
    *[!0-9hm]* | "" | h | m) return 1 ;;
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *)  echo "$1" ;;
  esac
}
MAX_RUNTIME_S="$(to_seconds "$MAX_RUNTIME")" || fail "MAX_RUNTIME ungültig: ${MAX_RUNTIME}"
DEADLINE=$(( START_TIME_EPOCH + MAX_RUNTIME_S ))

# Runs rsync with the remaining time; rc 124 = time limit -> TIMED_OUT, ends the run.
run_rsync() {
  local desc="$1" left rc=0 tmp line
  shift
  left=$(( DEADLINE - $(date +%s) ))
  if [ "$left" -le 60 ]; then
    TIMED_OUT=1
    fail "Laufzeitlimit vor ${desc} erreicht" 3
  fi
  tmp="$(mktemp)"
  timeout --signal=TERM --kill-after=120 "$left" rsync "${RSYNC_OPTS[@]}" "$@" >"$tmp" 2>&1 || rc=$?
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if [ "$rc" -eq 0 ]; then log_json "INFO" "${desc}: ${line}"; else log_json "ERROR" "${desc}: ${line}"; fi
  done < "$tmp"
  rm -f "$tmp"
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    TIMED_OUT=1
    fail "${desc}: Laufzeitlimit (${MAX_RUNTIME}) erreicht" 3
  fi
  [ "$rc" -eq 0 ] || fail "${desc} fehlgeschlagen (rsync rc=${rc})"
}

# -----------------------------
# Block 6: pass 1 -- new data objects only
# -----------------------------
if [ -d "$LOCAL_REPO/data" ]; then
  info "Durchlauf 1: neue Datenobjekte"
  run_rsync "rsync data" --stats --ignore-existing "$LOCAL_REPO/data" "$REMOTE"
else
  warn "Kein data/-Verzeichnis im Repo -- nur ein Durchlauf"
fi

# -----------------------------
# Block 7: pass 2 -- everything, with deletes
# -----------------------------
info "Durchlauf 2: Metadaten + gelöschte Objekte"
run_rsync "rsync full" --stats --delete --delete-after "$LOCAL_REPO/" "$REMOTE"

# -----------------------------
# Block 8: verify -- remote must match (file list, size, mtime)
# -----------------------------
# Attribute-only changes on directories (".d..t......") are ignored: --delete-after removes
# files after rsync has set the directory times, so the remote dir mtimes may differ.
info "Abgleich: Unterschiede zwischen lokal und Storage Box"
DIFF_FILE="$(mktemp)"
timeout 1800 rsync "${RSYNC_OPTS[@]}" --dry-run --delete --itemize-changes \
  "$LOCAL_REPO/" "$REMOTE" > "$DIFF_FILE" 2>&1 \
  || { rm -f "$DIFF_FILE"; fail "Abgleich fehlgeschlagen"; }
DIFFS="$(command grep -cv '^\.d' "$DIFF_FILE" || true)"
if [ "$DIFFS" -ne 0 ]; then
  command grep -v '^\.d' "$DIFF_FILE" | head -n 20 | while IFS= read -r line; do log_json "ERROR" "Abgleich: ${line}"; done
  rm -f "$DIFF_FILE"
  fail "Storage Box weicht vom lokalen Repo ab (${DIFFS} Einträge)"
fi
rm -f "$DIFF_FILE"
info "Abgleich OK: Storage Box entspricht dem lokalen Repo"

SUMMARY="Repo:   $(du -sh "$LOCAL_REPO" 2>/dev/null | cut -f1) gespiegelt, Abgleich OK
"
info "=== Off-site-Kopie Nextcloud abgeschlossen ==="
