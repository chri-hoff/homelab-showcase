#!/bin/bash
# Installs auditd with watches on security-relevant files (Issue #123, STEP 3).
# auditd's syslog plugin forwards its records to the journal (identifier
# audisp-syslog), Alloy ships the journal to Loki, the Grafana rule
# "Kritische Datei geändert" alerts on key homelab-critical.
#
# Not systemd-journald-audit.socket: it cannot be started while journald runs, and it
# would put every kernel audit event into the journal, not only auditd's records.
#
# Run:  sudo bash scripts/security/apply-auditd.sh
# Idempotent. Paths that do not exist on this host are skipped (auditctl refuses them).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo ausführen."; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/homelab-audit.rules
DST=/etc/audit/rules.d/homelab.rules

echo "==> auditd installieren"
command -v auditctl >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq auditd >/dev/null
PLUGIN=/etc/audit/plugins.d/syslog.conf
if [ ! -f "$PLUGIN" ]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq audispd-plugins >/dev/null
fi
[ -f "$PLUGIN" ] || { echo "!! $PLUGIN fehlt auch nach audispd-plugins"; exit 1; }

echo "==> Regeln nach $DST (nicht vorhandene Pfade werden ausgelassen)"
TMP=$(mktemp)
while IFS= read -r line; do
  if [[ $line =~ ^-w\ ([^ ]+) ]] && [ ! -e "${BASH_REMATCH[1]}" ]; then
    echo "    übersprungen: ${BASH_REMATCH[1]}"
    continue
  fi
  printf '%s\n' "$line"
done < "$SRC" > "$TMP"
install -o root -g root -m 0640 "$TMP" "$DST"
rm -f "$TMP"

echo "==> syslog-Plugin aktivieren (auditd -> journal)"
sed -i 's/^active *= *.*/active = yes/' "$PLUGIN"
grep -q '^active = yes' "$PLUGIN" || { echo "!! active = yes in $PLUGIN nicht gesetzt"; exit 1; }

echo "==> Regeln laden, auditd neu starten (übernimmt das Plugin)"
augenrules --load >/dev/null 2>&1 || { echo "!! augenrules --load fehlgeschlagen"; exit 1; }
systemctl enable auditd >/dev/null 2>&1
service auditd restart >/dev/null   # auditd refuses "systemctl restart" (RefuseManualStop)

echo "==> Test: chmod mit unveränderten Rechten (timestamp-only changes are not audited)"
TEST=/etc/docker/daemon.json
[ -e "$TEST" ] || TEST=/etc/sudoers
chmod "$(stat -c '%a' "$TEST")" "$TEST"
sleep 3
if journalctl --since "-1min" -t audisp-syslog -g 'homelab-critical' -q --no-pager | grep -q homelab-critical; then
  echo "    OK: Audit-Eintrag mit key homelab-critical im Journal"
else
  echo "!! Kein Audit-Eintrag im Journal -- 'auditctl -l' und 'systemctl status systemd-journald-audit.socket' prüfen"
fi

echo
auditctl -l | grep -c homelab-critical | xargs echo "    aktive Watches:"
echo "Rückgängig: sudo rm $DST && sudo augenrules --load"
