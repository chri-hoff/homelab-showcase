#!/bin/bash
# Disaster-recovery inventory (#157, step 1): collects everything on this host that is
# NOT in Git, as the input for the Ansible roles. Read-only, changes nothing.
#
# Run:     sudo bash scripts/maintenance/dr-inventory.sh
# Output:  ~<sudo user>/dr-inventory-<host>-<date>.txt (mode 600)
#
# Secrets: file contents pass through redact() (values of password/secret/token/key/...
# lines are replaced). Known credential files (CrowdSec LAPI/bouncer credentials, .env,
# Docker secrets, borg passphrase, SSH host keys) are listed by name only, never read.
# Still look through the file before sharing it.
set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo ausführen."; exit 1; }

OWNER=${SUDO_USER:-root}
OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
OUT=$OWNER_HOME/dr-inventory-$(hostname -s)-$(date +%F).txt
umask 077

sec()  { printf '\n\n########## %s ##########\n' "$*"; }
run()  { printf '\n$ %s\n' "$*"; "$@" 2>&1; }
have() { command -v "$1" >/dev/null 2>&1; }
redact() {
  # 1. values of key=value / key: value lines with a secret-like key
  # 2. secrets inside URLs: Telegram bot tokens (bot<id>:<token>) and user:pass@ credentials
  sed -E -e 's/^([^#]*(pass(word|wd|phrase)?|secret|token|api[_-]?key|apikey|credential|psk|private[_-]?key|bearer|auth(orization)?)[^:=]*[:=][[:space:]]*).+$/\1<redacted>/I' \
         -e 's#bot[0-9]+:[A-Za-z0-9_-]+#bot<redacted>#g' \
         -e 's#(://)[^/@ :]+:[^/@ ]+@#\1<redacted>@#g'
}
showf() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    printf '\n--- %s (%s, %s)\n' "$f" "$(stat -c '%U:%G %a' "$f")" "$(date -r "$f" +%F)"
    redact < "$f"
  done
}
showdir() {  # every regular file below a directory, contents redacted
  [ -d "$1" ] || return 0
  local f
  while IFS= read -r f; do showf "$f"; done < <(find "$1" -type f ! -name '*.dpkg-*' | sort)
}

{
echo "DR-Inventur $(hostname -f 2>/dev/null || hostname) -- $(date -Is)"
echo "Erzeugt von scripts/maintenance/dr-inventory.sh (#157). Werte von Secret-Zeilen sind ersetzt."

sec "1 System"
showf /etc/os-release
run uname -a
run hostnamectl
run timedatectl
run localectl status
run cat /proc/cmdline

sec "2 Disks und Mounts (Festplatten per Seriennummer!)"
run lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,LABEL,MOUNTPOINTS,MODEL,SERIAL
run findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS -t ext4,xfs,btrfs,vfat,nfs,nfs4,cifs,fuse.sshfs,zfs
showf /etc/fstab /etc/crypttab /etc/mdadm/mdadm.conf
run ls -la /mnt /data /opt /opt/docker
run df -h -x tmpfs -x devtmpfs -x overlay

sec "3 Netzwerk"
run ip -br addr
run ip route
showf /etc/hosts /etc/resolv.conf /etc/network/interfaces
showdir /etc/network/interfaces.d
showdir /etc/systemd/network
showdir /etc/netplan
have nmcli && run nmcli -t -f NAME,TYPE,DEVICE connection show
run nft list tables

sec "4 Pakete"
run apt-mark showmanual
run apt-mark showhold
showf /etc/apt/sources.list
showdir /etc/apt/sources.list.d
run ls -la /etc/apt/keyrings /usr/share/keyrings
showdir /etc/apt/apt.conf.d/
have snap && run snap list
have flatpak && run flatpak list
have pipx && run pipx list --short
run ls -la /usr/local/bin /usr/local/sbin /opt

sec "5 /etc: geänderte Paket-Konfigurationen"
echo "(dpkg --verify: Zeilen mit 'c' sind conffiles, die vom Paketstand abweichen)"
run dpkg --verify
have debsums && run debsums -ce
run ls -la /etc/.git /etc/.etckeeper

sec "6 /etc: Dateien, die keinem Paket gehören"
cat /var/lib/dpkg/info/*.list 2>/dev/null | sort -u > /run/dr-owned.$$
find /etc \( -path /etc/.git -o -path /etc/ssl/certs -o -path /etc/alternatives \) -prune \
     -o \( -type f -o -type l \) -print 2>/dev/null | sort > /run/dr-etc.$$
comm -23 /run/dr-etc.$$ /run/dr-owned.$$ \
  | grep -vE '^/etc/(ld\.so\.cache|machine-id|adjtime|mtab|shadow-|gshadow-|passwd-|group-|subuid-|subgid-|\.pwd\.lock|resolv\.conf|hostname|localtime|timezone|ssh/ssh_host_|docker/key\.json|crowdsec/hub/)' \
  | while IFS= read -r f; do printf '%s  (%s, %s)\n' "$f" "$(stat -c '%U:%G %a' "$f" 2>/dev/null)" "$(date -r "$f" +%F 2>/dev/null)"; done
rm -f /run/dr-owned.$$ /run/dr-etc.$$

sec "7 Benutzer, Gruppen, sudo, SSH"
echo "Benutzer mit Login-Shell oder UID >= 1000:"
getent passwd | awk -F: '$3>=1000 && $3<65534 || $7 !~ /(nologin|false|sync)$/ {print "  "$1" uid="$3" home="$6" shell="$7}'
for u in $(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1}') deploy root; do
  id "$u" 2>/dev/null
done
run getent group docker sudo adm systemd-journal
showf /etc/sudoers
showdir /etc/sudoers.d
showf /etc/ssh/sshd_config
showdir /etc/ssh/sshd_config.d
echo
echo "authorized_keys (nur Fingerprint, Kommentar und Optionen):"
for d in /root $(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $6}') $(getent passwd deploy | cut -d: -f6); do
  f=$d/.ssh/authorized_keys
  [ -f "$f" ] || continue
  echo "--- $f"
  while IFS= read -r line; do
    [ -z "$line" ] || [ "${line#\#}" != "$line" ] && continue
    opts=$(printf '%s' "$line" | grep -oE '^[^ ]*(from|command|restrict|no-)[^ ]*' || true)
    printf '  %s  %s\n' "$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | cut -d' ' -f1-4)" "${opts:+opts: $opts}"
  done < "$f"
done

sec "8 Cron und Timer"
for u in $(cut -d: -f1 /etc/passwd); do
  c=$(crontab -l -u "$u" 2>/dev/null) || continue
  printf '\n--- crontab %s\n%s\n' "$u" "$c" | redact
done
showf /etc/crontab
showdir /etc/cron.d
run ls -la /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly
run systemctl list-timers --all --no-pager

sec "9 systemd: eigene Units und Drop-ins"
find /etc/systemd/system -maxdepth 1 -type f -name '*.*' | sort | while IFS= read -r f; do showf "$f"; done
find /etc/systemd/system -mindepth 1 -maxdepth 1 -type d -name '*.d' | sort | while IFS= read -r d; do showdir "$d"; done
run systemctl list-unit-files --state=enabled --no-pager
run systemctl list-unit-files --state=masked --no-pager
run systemctl --failed --no-pager

sec "10 Docker"
run docker version --format 'Client {{.Client.Version}} / Server {{.Server.Version}}'
run docker info --format 'root={{.DockerRootDir}} driver={{.Driver}} cgroup={{.CgroupDriver}} live-restore={{.LiveRestoreEnabled}}'
showf /etc/docker/daemon.json
showdir /etc/systemd/system/docker.service.d
echo
echo "Netzwerke:"
docker network ls --format '{{.Name}}' 2>/dev/null | while IFS= read -r n; do
  docker network inspect -f '  {{.Name}} driver={{.Driver}} internal={{.Internal}} subnet={{range .IPAM.Config}}{{.Subnet}} gw={{.Gateway}} {{end}}' "$n"
done
run docker compose ls -a
echo
echo "Container (Name, Image, Status, Compose-Verzeichnis):"
docker ps -a --format '  {{.Names}}\t{{.Image}}\t{{.Status}}\t{{index .Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null | sort
run docker volume ls --format '{{.Name}}\t{{.Driver}}'
echo
echo "Bind-Mount-Quellen außerhalb von /opt/docker und /data/gitea/homelab:"
docker ps -aq 2>/dev/null | xargs -r docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}} {{.Source}}{{end}}{{end}}' \
  | tr ' ' '\n' | grep -E '^/' | grep -vE '^/(opt/docker|data/gitea/homelab)(/|$)' | sort -u | sed 's/^/  /'
echo
echo "Docker-Secrets-Dateien (nur Namen):"
run ls -la /opt/docker/secrets

sec "11 CrowdSec"
if have cscli; then
  run cscli version
  run cscli hub list
  run cscli bouncers list
  run cscli machines list
  showf /etc/crowdsec/config.yaml /etc/crowdsec/acquis.yaml /etc/crowdsec/profiles.yaml
  showdir /etc/crowdsec/acquis.d
  echo
  echo "Eigene (nicht vom Hub verlinkte) Parser/Szenarien/Postoverflows:"
  find /etc/crowdsec/parsers /etc/crowdsec/scenarios /etc/crowdsec/postoverflows /etc/crowdsec/contexts \
       -type f 2>/dev/null | sort | while IFS= read -r f; do showf "$f"; done
  showdir /etc/crowdsec/notifications
  echo
  echo "Bouncer-Konfiguration:"
  for f in /etc/crowdsec/bouncers/*.yaml /etc/crowdsec/bouncers/*.yaml.local; do showf "$f"; done
  echo
  echo "Credential-Dateien (nur Namen):"
  ls -la /etc/crowdsec/*credentials* 2>/dev/null
else
  echo "cscli nicht gefunden"
fi

sec "12 Alloy, Logrotate, sonstige Dienste"
showdir /etc/alloy
showf /etc/default/alloy
showdir /etc/logrotate.d
showf /etc/smartd.conf
showdir /etc/sysctl.d
showdir /etc/modules-load.d
showdir /etc/udev/rules.d
showdir /etc/audit/rules.d
showdir /etc/homelab-firewall
showf /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/20auto-upgrades
have postconf && run postconf -n

sec "13 Backup"
have borg && run borg --version
have borg2 && run borg2 --version
run ls -la /data/backup /mnt
echo
echo "Root-Home (nur Namen, z. B. Schlüssel/Passphrasen, die gesichert sein müssen):"
run ls -la /root /root/.ssh /root/.config

sec "14 Benutzer-Umgebung ${OWNER}"
run ls -la "$OWNER_HOME" "$OWNER_HOME/.config/fish/functions" "$OWNER_HOME/.config/sops/age"
run ls -la /data/gitea/homelab

} > "$OUT" 2>&1

chown "$OWNER": "$OUT"
chmod 600 "$OUT"
echo "Fertig: $OUT ($(wc -l < "$OUT") Zeilen). Bitte vor dem Weitergeben durchsehen."
