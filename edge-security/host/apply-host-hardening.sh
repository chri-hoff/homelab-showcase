#!/bin/bash
# Host-side hardening (Traefik configs under /opt/docker, Prometheus, CrowdSec).
# Counterpart of the branch security/traefik-crowdsec-hardening.
#
# Run:      sudo bash scripts/security/apply-host-hardening.sh
# Backups:  /root/hardening-backup-<timestamp>/ (for rollback see the output at the end)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo ausführen."; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
BK=/root/hardening-backup-$TS
TRAEFIK=/opt/docker/traefik/config
PROM=/opt/docker/prometheus/config/prometheus.yml
CS=/etc/crowdsec
BOUNCER=$CS/bouncers/crowdsec-firewall-bouncer.yaml

FILES=(
  $TRAEFIK/traefik.yaml
  $TRAEFIK/conf/middleware-crowdsec.yaml
  $TRAEFIK/conf/middleware-ip-allow-list.yaml
  $TRAEFIK/conf/middleware-chain.yaml
  $PROM
  $BOUNCER
  $CS/acquis.yaml
  $CS/acquis.d/setup.linux.yaml
  $CS/acquis.d/ntfy.yaml
  $CS/profiles.yaml
)

echo "==> Backup nach $BK"
mkdir -p "$BK"
for f in "${FILES[@]}"; do
  [ -e "$f" ] && cp -a --parents "$f" "$BK/"
done

# --- Traefik ---------------------------------------------------------------
echo "==> Traefik: Dashboard-API nicht mehr ungeschützt (api.insecure: false)"
sed -i 's/^\(\s*\)insecure: true/\1insecure: false/' $TRAEFIK/traefik.yaml

echo "==> Traefik: IoT-Netz 198.51.100.0/24 nicht mehr als Proxy vertrauen"
sed -i '/^\s*- "198\.51\.100\.0\/24"/d' $TRAEFIK/traefik.yaml

echo "==> CrowdSec-Plugin: LAN/IoT nicht mehr für X-Forwarded-For vertrauen"
sed -i -e '/^\s*- 192\.0\.2\.0\/24/d' -e '/^\s*- 198\.51\.100\.0\/24/d' $TRAEFIK/conf/middleware-crowdsec.yaml

echo "==> only-internal: Tippfehler 203.0.113.1/24 -> 203.0.113.0/24"
sed -i 's#203\.0\.113\.1/24#203.0.113.0/24#' $TRAEFIK/conf/middleware-ip-allow-list.yaml

echo "==> cadvisor-chain: TCP-Middleware aus HTTP-Chain entfernen (ungültig)"
sed -i '/^\s*- only-internal-tcp\s*$/d' $TRAEFIK/conf/middleware-chain.yaml

echo "==> Prometheus: Traefik-Metrics über backend-Netz statt Host-Port 8082"
sed -i 's/"tc\.lan:8082"/"traefik:8082"/' $PROM

python3 - "$TRAEFIK"/traefik.yaml "$TRAEFIK"/conf/*.yaml "$PROM" <<'EOF'
import sys, yaml
for f in sys.argv[1:]:
    yaml.safe_load(open(f))
print("    YAML-Syntax OK")
EOF

# --- CrowdSec ----------------------------------------------------------------
echo "==> Firewall-Bouncer: Blocklisten auch für Docker-Ports (DOCKER-USER)"
grep -q '^  - DOCKER-USER' $BOUNCER || sed -i 's/^#  - DOCKER-USER/  - DOCKER-USER/' $BOUNCER
grep -q '^  - DOCKER-USER' $BOUNCER || { echo "!! DOCKER-USER konnte nicht gesetzt werden, bitte $BOUNCER prüfen"; exit 1; }

mkdir -p /etc/systemd/system/crowdsec-firewall-bouncer.service.d
cat > /etc/systemd/system/crowdsec-firewall-bouncer.service.d/docker.conf <<'EOF'
# DOCKER-USER only exists once Docker is running
[Unit]
After=docker.service
Requires=docker.service
EOF

echo "==> Acquisition: doppeltes SSH und veraltete Installer-Logquelle entfernen"
cat > $CS/acquis.yaml <<'EOF'
# SSH is read via acquis.d/setup.sshd.yaml (journalctl).
source: docker
use_container_labels: true
EOF

echo "==> Acquisition: nicht existierende Logdateien (kein rsyslog) und ntfy deaktivieren"
for f in $CS/acquis.d/setup.linux.yaml $CS/acquis.d/ntfy.yaml; do
  [ -e "$f" ] && mv "$f" "$f.disabled"
done

echo "==> Profile: Sperrdauer steigt bei Wiederholungstätern (4h, 8h, 12h, ...)"
sed -i 's/^#duration_expr:/duration_expr:/' $CS/profiles.yaml

echo "==> Authentik-Parser installieren"
cscli collections install firix/authentik || echo "!! firix/authentik nicht installiert – bitte 'cscli collections search authentik' prüfen"

echo "==> CrowdSec-Konfiguration testen"
if ! crowdsec -t; then
  echo "!! crowdsec -t fehlgeschlagen – stelle CrowdSec-Dateien wieder her"
  cp -a "$BK$CS/." $CS/
  rm -f $CS/acquis.d/*.disabled
  exit 1
fi

echo "==> Verwaiste traefik-bouncer-Einträge (> 7 Tage ohne Pull) entfernen"
cscli bouncers prune -d 168h --force

echo "==> Dienste neu laden"
systemctl daemon-reload
systemctl restart crowdsec
systemctl restart crowdsec-firewall-bouncer
docker kill -s HUP prometheus >/dev/null && echo "    Prometheus neu geladen"

sleep 5
echo
echo "==> Prüfung"
if iptables -S DOCKER-USER | grep -q CROWDSEC; then
  echo "    OK: DOCKER-USER springt in CROWDSEC_CHAIN"
else
  echo "!! DOCKER-USER enthält keine CrowdSec-Regel – siehe /var/log/crowdsec-firewall-bouncer.log"
fi
systemctl is-active crowdsec crowdsec-firewall-bouncer

cat <<EOF

Fertig. Backup: $BK

Wichtig:
  * traefik.yaml (api.insecure) wird erst beim Neustart von Traefik aktiv.
    Den PR security/traefik-crowdsec-hardening danach mergen – das Redeploy
    startet Traefik mit dem neuen Dashboard-Router (service=api@internal) neu.
  * Middleware-Dateien in conf/ lädt Traefik sofort (watch: true).

Rollback:
  sudo cp -a $BK/. /
  sudo rm -f /etc/crowdsec/acquis.d/*.disabled /etc/systemd/system/crowdsec-firewall-bouncer.service.d/docker.conf
  sudo systemctl daemon-reload && sudo systemctl restart crowdsec crowdsec-firewall-bouncer
EOF
