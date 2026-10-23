#!/bin/bash
# Host firewall + disabling unused host services.
#
#   sudo bash scripts/security/host-firewall.sh apply     # disable services, load firewall on trial (auto-rollback after 3 min)
#   sudo bash scripts/security/host-firewall.sh confirm   # after a successful test in a 2nd SSH session: make it permanent
#   sudo bash scripts/security/host-firewall.sh rollback  # remove and disable the firewall immediately
#   sudo bash scripts/security/host-firewall.sh status
#
# Ruleset: scripts/security/host-firewall.nft (copied to /etc/homelab-firewall/)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo ausführen."; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
NFT=/usr/sbin/nft
RULES_SRC=$HERE/host-firewall.nft
RULES_DST=/etc/homelab-firewall/host-firewall.nft
UNIT=/etc/systemd/system/host-firewall.service
ROLLBACK_UNIT=host-firewall-rollback
ROLLBACK_SECONDS=180

disable_services() {
  local bk=/root/host-services-backup-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$bk"
  cp -a /etc/postfix/main.cf "$bk/"
  echo "==> Backup Postfix-Config nach $bk"

  echo "==> rpcbind abschalten (kein NFS in Benutzung)"
  systemctl disable --now rpcbind.service rpcbind.socket 2>/dev/null || true
  systemctl mask rpcbind.service rpcbind.socket

  echo "==> cups-browsed abschalten (cups selbst bleibt, lauscht nur auf localhost)"
  systemctl disable --now cups-browsed.service 2>/dev/null || true
  systemctl mask cups-browsed.service

  echo "==> avahi (mDNS) abschalten"
  systemctl disable --now avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
  systemctl mask avahi-daemon.service avahi-daemon.socket

  echo "==> Postfix nur noch auf localhost"
  postconf -e 'inet_interfaces = loopback-only'
  systemctl restart postfix

  # /etc/nftables.conf starts with "flush ruleset" -- if nftables.service were
  # ever enabled, all Docker and CrowdSec rules would be gone.
  echo "==> nftables.service maskieren (Schutz vor 'flush ruleset')"
  systemctl disable --now nftables.service 2>/dev/null || true
  systemctl mask nftables.service
}

load_rules() {
  install -D -m 644 "$RULES_SRC" "$RULES_DST"
  $NFT -c -f "$RULES_DST"
  $NFT -f "$RULES_DST"
}

case "${1:-}" in
  apply)
    disable_services

    echo "==> Firewall testweise laden"
    load_rules
    systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
    systemctl reset-failed "$ROLLBACK_UNIT.service" 2>/dev/null || true
    systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="$ROLLBACK_SECONDS" \
      $NFT delete table inet host-firewall

    cat <<EOF

Firewall ist aktiv – wird in $ROLLBACK_SECONDS Sekunden AUTOMATISCH wieder entfernt.

Jetzt testen (diese Sitzung offen lassen!):
  1. NEUE SSH-Sitzung öffnen:   ssh admin@198.51.100.10
  2. Webdienste kurz prüfen (z.B. Nextcloud, AdGuard-UI über Traefik)
  3. Wenn alles geht:           sudo bash $0 confirm

Kommst du nicht rein: einfach warten, nach $ROLLBACK_SECONDS s ist die Firewall weg.
EOF
    ;;

  confirm)
    $NFT list table inet host-firewall >/dev/null 2>&1 || {
      echo "Firewall ist nicht geladen (Rollback schon gelaufen?) – erst 'apply' ausführen."; exit 1; }
    systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
    echo "==> Auto-Rollback gestoppt"

    cat > "$UNIT" <<EOF
[Unit]
Description=Homelab Host-Firewall (nftables, nur Tabelle inet host-firewall)
Wants=network-pre.target
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NFT -f $RULES_DST
ExecReload=$NFT -f $RULES_DST
ExecStop=$NFT delete table inet host-firewall

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable host-firewall.service
    systemctl start host-firewall.service
    echo "==> host-firewall.service aktiviert – Regeln bleiben nach Neustart erhalten."
    ;;

  rollback)
    systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
    systemctl disable --now host-firewall.service 2>/dev/null || true
    $NFT delete table inet host-firewall 2>/dev/null || true
    echo "==> Firewall entfernt und deaktiviert."
    echo "    Dienste wieder einschalten (falls nötig):"
    echo "      sudo systemctl unmask --now rpcbind.socket rpcbind.service cups-browsed.service avahi-daemon.socket avahi-daemon.service"
    echo "      sudo postconf -e 'inet_interfaces = all' && sudo systemctl restart postfix"
    ;;

  status)
    $NFT list table inet host-firewall 2>/dev/null || echo "Firewall-Tabelle nicht geladen"
    systemctl is-enabled host-firewall.service 2>/dev/null || true
    systemctl list-timers "$ROLLBACK_UNIT.timer" --no-pager 2>/dev/null | head -3
    ss -tulpn | grep -vE '127\.0\.0\.1|\[::1\]' | grep LISTEN
    ;;

  *)
    sed -n '2,9p' "$0"; exit 1 ;;
esac
