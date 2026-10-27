#!/bin/bash
# Docker daemon baseline (Issue #103, STEP 7): log rotation, live-restore,
# no-new-privileges as default, no inter-container traffic on the default bridge.
#
# Run:      sudo bash scripts/security/apply-docker-daemon.sh
# Source:   scripts/security/docker-daemon.json -> /etc/docker/daemon.json
#
# Order matters: live-restore is reloadable, so it is activated by a reload (SIGHUP)
# first. The restart for the remaining options then keeps all containers running.
# log-opts and no-new-privileges only apply to containers created afterwards.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo ausführen."; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/docker-daemon.json
DST=/etc/docker/daemon.json
BK=/root/docker-daemon-backup-$(date +%Y%m%d-%H%M%S)

echo "==> Konfiguration prüfen"
dockerd --validate --config-file "$SRC"

if [ -e "$DST" ]; then
  mkdir -p "$BK"
  cp -a "$DST" "$BK/"
  echo "==> Backup: $BK/daemon.json"
fi

install -m 0644 -o root -g root "$SRC" "$DST"

echo "==> Reload (aktiviert live-restore)"
systemctl reload docker
sleep 2
if [ "$(docker info --format '{{.LiveRestoreEnabled}}')" != "true" ]; then
  echo "!! live-restore nach Reload nicht aktiv - kein Neustart, damit keine Container stoppen."
  echo "   Rückgängig: sudo rm $DST && sudo systemctl reload docker"
  exit 1
fi
echo "    live-restore aktiv"

RUNNING_BEFORE=$(docker ps -q | wc -l)
echo "==> Neustart dockerd ($RUNNING_BEFORE laufende Container bleiben dank live-restore aktiv)"
systemctl restart docker
sleep 5

echo
echo "==> Prüfung"
docker info --format '    LiveRestore={{.LiveRestoreEnabled}}  LoggingDriver={{.LoggingDriver}}  SecurityOptions={{.SecurityOptions}}'
echo "    laufende Container: vorher $RUNNING_BEFORE, jetzt $(docker ps -q | wc -l)"
# The bouncer is restarted together with dockerd (Requires=docker.service) and
# needs a few seconds before its DOCKER-USER rule is back.
for _ in $(seq 30); do
  iptables -S DOCKER-USER 2>/dev/null | grep -q CROWDSEC && break
  sleep 1
done
systemctl is-active docker crowdsec-firewall-bouncer || true
if iptables -S DOCKER-USER | grep -q CROWDSEC; then
  echo "    OK: DOCKER-USER springt in CROWDSEC_CHAIN"
else
  echo "!! DOCKER-USER ohne CrowdSec-Regel - sudo systemctl restart crowdsec-firewall-bouncer"
fi

cat <<EOT

Fertig. log-opts/no-new-privileges gelten erst für neu erstellte Container
(nächstes sops-update bzw. Update).

Rollback:
  sudo rm $DST$( [ -d "$BK" ] && echo " && sudo cp -a $BK/daemon.json $DST" )
  sudo systemctl restart docker
EOT
