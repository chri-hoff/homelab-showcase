#!/bin/bash
# Switch CrowdSec notifications from ntfy to Telegram.
#
# Run:  sudo bash scripts/security/crowdsec-telegram.sh
# Prompts for bot token and chat ID (same bot as Kestra/n8n, stored in
# Vault under homelab/services/telegram). None of it ends up in the repo.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo ausführen."; exit 1; }

CS=/etc/crowdsec
NOTIF=$CS/notifications
TS=$(date +%Y%m%d-%H%M%S)
BK=/root/crowdsec-telegram-backup-$TS

read -rsp "Telegram Bot-Token: " TOKEN; echo
read -rp  "Telegram Chat-ID:   " CHAT_ID
[[ "$TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { echo "Token-Format ungültig"; exit 1; }
[[ "$CHAT_ID" =~ ^-?[0-9]+$ ]] || { echo "Chat-ID-Format ungültig"; exit 1; }

echo "==> Backup nach $BK"
mkdir -p "$BK"
cp -a "$NOTIF" "$CS/profiles.yaml" "$BK/"

echo "==> Telegram-Benachrichtigung anlegen ($NOTIF/telegram.yaml)"
umask 077
# Values from alerts are *string pointers; toJson dereferences and escapes them,
# trimPrefix/trimSuffix strips the outer quotes so they can be safely inserted
# into the JSON string "text".
cat > "$NOTIF/telegram.yaml" <<'EOF'
type: http
name: telegram
log_level: info

format: |
  {
    "chat_id": "__CHAT_ID__",
    "disable_web_page_preview": true,
    "text": "
  {{- range . -}}
  {{- $alert := . -}}
  {{- range .Decisions -}}
  🚫 CrowdSec-Sperre (homelab)\nIP: {{ .Value | toJson | trimPrefix "\"" | trimSuffix "\"" }}\nAktion: {{ .Type | toJson | trimPrefix "\"" | trimSuffix "\"" }} für {{ .Duration | toJson | trimPrefix "\"" | trimSuffix "\"" }}\nSzenario: {{ .Scenario | toJson | trimPrefix "\"" | trimSuffix "\"" }}\nHerkunft: {{ $alert.Source.Cn | toJson | trimPrefix "\"" | trimSuffix "\"" }} / {{ $alert.Source.AsName | toJson | trimPrefix "\"" | trimSuffix "\"" }}\n\n
  {{- end -}}
  {{- end -}}
    "
  }

url: https://api.telegram.org/bot__TOKEN__/sendMessage
method: POST
headers:
  Content-Type: application/json
EOF
sed -i -e "s|__CHAT_ID__|$CHAT_ID|" -e "s|__TOKEN__|$TOKEN|" "$NOTIF/telegram.yaml"
chmod 600 "$NOTIF/telegram.yaml"
unset TOKEN

echo "==> Alte ntfy-Benachrichtigung deaktivieren"
for f in $(grep -l 'name: *ntfy_crowdsec' "$NOTIF"/*.yaml 2>/dev/null || true); do
  mv "$f" "$f.disabled" && echo "    $f -> $f.disabled"
done

echo "==> Profile auf Telegram umstellen"
sed -i 's/^\(\s*\)- ntfy_crowdsec\s*$/\1- telegram/' "$CS/profiles.yaml"
grep -q 'ntfy_crowdsec' "$CS/profiles.yaml" && { echo "!! ntfy_crowdsec noch in profiles.yaml"; exit 1; }

echo "==> ntfy-Collection und Logquelle entfernen (ntfy läuft nicht mehr)"
cscli collections remove Jgigantino31/ntfy || echo "    (Collection nicht installiert)"
rm -f "$CS/acquis.d/ntfy.yaml.disabled"

echo "==> CrowdSec-Konfiguration testen"
if ! crowdsec -t; then
  echo "!! crowdsec -t fehlgeschlagen – stelle Backup wieder her"
  rm -rf "$NOTIF" && cp -a "$BK/notifications" "$NOTIF"
  cp -a "$BK/profiles.yaml" "$CS/profiles.yaml"
  exit 1
fi

systemctl restart crowdsec
sleep 5
systemctl is-active crowdsec

echo "==> Testnachricht senden"
cscli notifications test telegram && echo "    Testnachricht sollte jetzt in Telegram angekommen sein."

cat <<EOF

Fertig. Backup: $BK
Rollback:
  sudo rm -rf $NOTIF && sudo cp -a $BK/notifications $NOTIF
  sudo cp -a $BK/profiles.yaml $CS/profiles.yaml && sudo systemctl restart crowdsec
EOF
