#!/bin/bash
# smartd warnings via Telegram (#151). The mail to root stays; it was not noticed on 2026-11-04.
# smartd -> smartd-runner -> run-parts /etc/smartmontools/run.d, message in SMARTD_* variables.
#
#   sudo install -m 755 scripts/security/smartd-telegram.sh /etc/smartmontools/run.d/20telegram
#
# Test through smartd itself: add "-M test" to the disk's line in /etc/smartd.conf, run
# "sudo systemctl restart smartmontools", expect a message, then remove "-M test" and restart.
#
# Credentials deliberately not from Vault: a disk warning must also arrive when Vault is down.
# The token never appears on a command line (visible via ps): curl reads the URL from a
# config passed through a pipe, and jq gets chat ID and text via env.
# Always exits 0, so a Telegram problem cannot affect the other run.d scripts.

CRED_FILE="/opt/docker/secrets/vault-unseal-alert.env"

if [ ! -r "$CRED_FILE" ]; then
  logger -t smartd-telegram -p user.err "Credentials nicht lesbar: $CRED_FILE"
  exit 0
fi
# shellcheck disable=SC1090
. "$CRED_FILE"

TEXT="💽 SMART-Warnung auf $(hostname -s)
Platte: ${SMARTD_DEVICESTRING:-${SMARTD_DEVICE:-unbekannt}}
Art: ${SMARTD_FAILTYPE:-unbekannt}
${SMARTD_MESSAGE:-keine Details}"

if ! TG_CHAT="$TELEGRAM_CHAT_ID" TG_TEXT="$TEXT" jq -n '{chat_id: env.TG_CHAT, text: env.TG_TEXT}' \
  | curl -fsS --max-time 30 -K <(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN") \
      -H "Content-Type: application/json" --data-binary @- >/dev/null; then
  logger -t smartd-telegram -p user.err "Telegram-Versand fehlgeschlagen: ${SMARTD_FAILTYPE:-unbekannt}"
fi
exit 0
