#!/bin/bash
set -euo pipefail

# Checks Vault's sealed status via cron and sends a Telegram message on a
# status change (unsealed->sealed or sealed->unsealed). Alerts ONLY on a
# status change, not on every run -- otherwise the chat would be spammed
# every 5 minutes during longer maintenance windows.
#
# IMPORTANT: the Telegram credentials are deliberately NOT stored in Vault/SOPS.
# This script alerts exactly when Vault can no longer serve secrets -- if it
# had to fetch its own alert secret from Vault, it could never fire in the
# case that matters (Vault sealed). Hence a separate plaintext file
# (600, root-only), analogous to the existing pattern of the AppRole
# role_id/secret_id bootstrap files in /opt/docker/secrets -- same reason:
# you cannot depend on the system you are checking.
#
# Setup on the host before this script runs via cron:
#   1. Create the credentials file (values = the same as in Vault under
#      homelab/services/telegram, just duplicated locally):
#        sudo install -m 600 /dev/null /opt/docker/secrets/vault-unseal-alert.env
#        sudo tee /opt/docker/secrets/vault-unseal-alert.env <<'EOF'
#        TELEGRAM_BOT_TOKEN=...
#        TELEGRAM_CHAT_ID=...
#        EOF
#   2. Crontab entry (every 5 minutes):
#        */5 * * * * /data/gitea/homelab/scripts/vault/check_vault_sealed.sh >> /var/log/check_vault_sealed.log 2>&1

# --- Configuration ---
VAULT_CONTAINER="vault"
VAULT_ADDR="http://localhost:8200"

CRED_FILE="/opt/docker/secrets/vault-unseal-alert.env"

STATE_DIR="/data/vault-alert"
STATE_FILE="${STATE_DIR}/last_state"
LOCKFILE="/tmp/check_vault_sealed.$(id -u).lock"

# --- Logging ---
log() {
    echo "[$(date '+%F %T')] $1"
}

log_error() {
    log "FEHLER: $1" >&2
}

# --- Send Telegram message ---
send_telegram() {
    local text="$1"
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg chat_id "$TELEGRAM_CHAT_ID" --arg text "$text" '{chat_id: $chat_id, text: $text}')" \
        >/dev/null
}

# --- Prevent overlapping runs ---
exec 200>"$LOCKFILE"
flock -n 200 || { log "Vorheriger Lauf noch aktiv, überspringe."; exit 0; }

# --- Load credentials ---
if [ ! -r "$CRED_FILE" ]; then
    log_error "Credential-Datei fehlt oder nicht lesbar: ${CRED_FILE} (siehe Kopf-Kommentar dieses Skripts)"
    exit 1
fi
# shellcheck disable=SC1090
source "$CRED_FILE"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log_error "TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID nicht gesetzt in ${CRED_FILE}"
    exit 1
fi

mkdir -p "$STATE_DIR"

# --- Determine sealed status ---
STATUS_OUTPUT="$(docker exec "$VAULT_CONTAINER" vault status -address="$VAULT_ADDR" 2>&1)" || true
SEALED="$(printf '%s\n' "$STATUS_OUTPUT" | awk '/^Sealed/ {print $2}')"

if [ "$SEALED" != "true" ] && [ "$SEALED" != "false" ]; then
    log_error "Konnte Sealed-Status nicht ermitteln (Container down/unreachable?): ${STATUS_OUTPUT}"
    exit 1
fi

if [ "$SEALED" = "true" ]; then
    CURRENT_STATE="sealed"
else
    CURRENT_STATE="unsealed"
fi

PREVIOUS_STATE="unknown"
if [ -f "$STATE_FILE" ]; then
    PREVIOUS_STATE="$(cat "$STATE_FILE")"
fi

if [ "$CURRENT_STATE" = "$PREVIOUS_STATE" ]; then
    log "Status unveraendert: ${CURRENT_STATE}"
    exit 0
fi

log "Statuswechsel: ${PREVIOUS_STATE} -> ${CURRENT_STATE}"

if [ "$CURRENT_STATE" = "sealed" ]; then
    send_telegram "🔒 Vault ist VERSIEGELT auf $(hostname -s). Bitte manuell unsealen (Fish-Funktion vault-unseal oder siehe services/vault/README.md)."
elif [ "$PREVIOUS_STATE" != "unknown" ]; then
    # On the very first run (no STATE_FILE) don't send an "unsealed again"
    # message -- it was never known to be broken.
    send_telegram "🔓 Vault ist wieder entsiegelt auf $(hostname -s)."
fi

echo "$CURRENT_STATE" > "$STATE_FILE"
