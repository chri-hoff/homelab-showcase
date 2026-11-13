#!/bin/bash
# Disaster-recovery test (#157): fresh Debian 13 VM on KVM/libvirt -> site.yml ->
# site.yml again (must change nothing) -> verify.yml -> measured durations -> VM removed.
#
#   ./dr-test.sh            full run; the VM is kept only if something fails
#   ./dr-test.sh up         only create the VM (prints its address)
#   ./dr-test.sh destroy    remove the VM
#   ./dr-test.sh proxy      run only the egress proxy (for working in a kept VM)
#   ./dr-test.sh restore    rebuild WITH data (Borg, Vault snapshot) -- see restore_test()
#   ./dr-test.sh restore-continue   continue a kept restore VM from the services on
#   KEEP=1 ./dr-test.sh     keep the VM after a successful run
#
# Needs: qemu-system-x86, libvirt-daemon-system, virtinst, genisoimage, ansible; the user
# in the groups libvirt and kvm. No sudo: images live in a libvirt pool (root-owned).
# The VM gets passwordless sudo and a throwaway SSH key -- test VM only.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
export LIBVIRT_DEFAULT_URI=qemu:///system

VM=homelab-drtest
POOL=homelab-drtest
POOL_DIR=/var/lib/libvirt/images/homelab-drtest
# Isolated network (no forwarding): the VM reaches only the laptop. Its only way out is
# drtest-proxy.py on the laptop with an allowlist (Debian, Docker registries, CrowdSec,
# GitHub). The restored homelab inside therefore cannot reach Telegram, smtp, ipv64,
# Let's Encrypt, Gitea, OneDrive ... -- not by configuration, but because there is no route.
NET=homelab-drtest
NET_BRIDGE=virbr-drtest
NET_ADDR=192.0.2.1
PROXY_PORT=8888
PROXY="http://$NET_ADDR:$PROXY_PORT"
NO_PROXY="localhost,127.0.0.1,::1,192.0.2.0/24,172.16.0.0/12"
RAM_MB=${RAM_MB:-4096}
VCPUS=${VCPUS:-2}
DISK_GB=${DISK_GB:-30}
IMAGE_URL=https://cloud.debian.org/images/cloud/trixie/latest
IMAGE=debian-13-genericcloud-amd64.qcow2
BASE_VOL=debian-13-base.qcow2
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/homelab-drtest
LOG_DIR=$STATE/logs

log() { printf '\n==> %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

ensure_pool() {
  if ! virsh pool-info "$POOL" >/dev/null 2>&1; then
    log "libvirt-Pool $POOL anlegen ($POOL_DIR)"
    virsh pool-define-as "$POOL" dir --target "$POOL_DIR" >/dev/null
    virsh pool-build "$POOL" >/dev/null
    virsh pool-autostart "$POOL" >/dev/null
  fi
  # pool-list --name lists active pools only (pool-info's state is localized)
  virsh pool-list --name | grep -qx "$POOL" || virsh pool-start "$POOL" >/dev/null
  virsh pool-refresh "$POOL" >/dev/null
}

# Debian cloud image, checked against Debian's SHA512SUMS; re-downloaded when it changes.
ensure_image() {
  mkdir -p "$STATE"
  local sums="$STATE/SHA512SUMS" want
  curl -fsSL "$IMAGE_URL/SHA512SUMS" -o "$sums"
  want=$(awk -v f="$IMAGE" '$2 == f {print $1}' "$sums")
  [ -n "$want" ] || die "$IMAGE nicht in SHA512SUMS"
  if [ ! -f "$STATE/$IMAGE" ] || [ "$(sha512sum "$STATE/$IMAGE" | cut -d' ' -f1)" != "$want" ]; then
    log "Debian-Cloud-Image laden"
    curl -fL --progress-bar "$IMAGE_URL/$IMAGE" -o "$STATE/$IMAGE.part"
    [ "$(sha512sum "$STATE/$IMAGE.part" | cut -d' ' -f1)" = "$want" ] || die "Prüfsumme falsch"
    mv "$STATE/$IMAGE.part" "$STATE/$IMAGE"
    virsh vol-delete "$BASE_VOL" --pool "$POOL" >/dev/null 2>&1 || true
  fi
  if ! virsh vol-info "$BASE_VOL" --pool "$POOL" >/dev/null 2>&1; then
    virsh vol-create-as "$POOL" "$BASE_VOL" "$(stat -c %s "$STATE/$IMAGE")" --format qcow2 >/dev/null
    virsh vol-upload "$BASE_VOL" "$STATE/$IMAGE" --pool "$POOL"
  fi
}

ensure_network() {
  if ! virsh net-info "$NET" >/dev/null 2>&1; then
    log "Isoliertes libvirt-Netz $NET anlegen ($NET_ADDR/24, ohne Weiterleitung)"
    local xml; xml=$(mktemp)
    cat > "$xml" <<NETXML
<network>
  <name>$NET</name>
  <bridge name='$NET_BRIDGE' stp='on' delay='0'/>
  <ip address='$NET_ADDR' netmask='255.255.255.0'>
    <dhcp><range start='192.0.2.10' end='192.0.2.99'/></dhcp>
  </ip>
</network>
NETXML
    virsh net-define "$xml" >/dev/null
    rm -f "$xml"
    virsh net-autostart "$NET" >/dev/null
  fi
  virsh net-list --name | grep -qx "$NET" || virsh net-start "$NET" >/dev/null
  # No <forward> element = isolated. Make sure nobody changed that.
  if virsh net-dumpxml "$NET" | grep -q '<forward'; then
    die "Netz $NET hat eine Weiterleitung -- nicht isoliert!"
  fi
}

# Proxy runs as long as this script; its log shows every allowed and denied host.
start_proxy() {
  if ss -Htln "sport = :$PROXY_PORT" | grep -q "$NET_ADDR:$PROXY_PORT"; then
    return 0
  fi
  mkdir -p "$LOG_DIR"
  python3 "$HERE/drtest-proxy.py" "$NET_ADDR" "$PROXY_PORT" "$LOG_DIR/proxy.log" &
  PROXY_PID=$!
  trap 'kill $PROXY_PID 2>/dev/null; rm -f "${VAULT_PASS_FILE:-}"' EXIT
  sleep 1
  kill -0 "$PROXY_PID" 2>/dev/null || die "Proxy startet nicht (Port $PROXY_PORT belegt?)"
}

ensure_key() {
  [ -f "$STATE/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C "$VM" -f "$STATE/id_ed25519"
}

vm_ip() {
  virsh domifaddr "$VM" --source lease 2>/dev/null | awk '/ipv4/ {sub(/\/.*/, "", $4); print $4; exit}'
}

up() {
  virsh dominfo "$VM" >/dev/null 2>&1 && die "VM $VM existiert schon -- erst: $0 destroy"
  ensure_pool
  ensure_image
  ensure_key
  ensure_network
  start_proxy

  log "VM $VM erstellen (${RAM_MB} MB, ${VCPUS} vCPU, ${DISK_GB} GB)"
  local tmp; tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  cat > "$tmp/user-data" <<EOF
#cloud-config
hostname: drtest
users:
  - name: admin
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - $(cat "$STATE/id_ed25519.pub")
ssh_pwauth: false
# Egress only through the laptop's allowlist proxy: apt and dockerd (image pulls).
# Containers get no proxy -- they have no way out at all.
write_files:
  - path: /etc/apt/apt.conf.d/95drtest-proxy
    content: |
      Acquire::http::Proxy "$PROXY";
      Acquire::https::Proxy "$PROXY";
  - path: /etc/systemd/system/docker.service.d/drtest-proxy.conf
    content: |
      [Service]
      Environment="HTTP_PROXY=$PROXY" "HTTPS_PROXY=$PROXY" "NO_PROXY=$NO_PROXY"
  # CrowdSec logs into its central API on start and exits (FATAL) if that fails.
  - path: /etc/systemd/system/crowdsec.service.d/drtest-proxy.conf
    content: |
      [Service]
      Environment="HTTP_PROXY=$PROXY" "HTTPS_PROXY=$PROXY" "NO_PROXY=$NO_PROXY"
  # The cloud image runs systemd-resolved on 127.0.0.53:53, which would keep AdGuard from
  # binding port 53. The real host has no resolved (NetworkManager, nameserver = AdGuard).
  - path: /etc/systemd/resolved.conf.d/drtest.conf
    content: |
      [Resolve]
      DNSStubListener=no
runcmd:
  - [ln, -sf, /run/systemd/resolve/resolv.conf, /etc/resolv.conf]
  - [systemctl, restart, systemd-resolved]
EOF
  printf 'instance-id: %s-%s\nlocal-hostname: drtest\n' "$VM" "$(date +%s)" > "$tmp/meta-data"
  genisoimage -quiet -output "$tmp/seed.iso" -volid cidata -joliet -rock "$tmp/user-data" "$tmp/meta-data"

  # UEFI like the ThinkCentre; with SeaBIOS the cloud kernel reset-looped right after GRUB
  # on the laptop (2026-11-09).
  virsh vol-create-as "$POOL" "$VM.qcow2" "${DISK_GB}G" --format qcow2 \
    --backing-vol "$BASE_VOL" --backing-vol-format qcow2 >/dev/null
  virsh vol-create-as "$POOL" "$VM-seed.iso" "$(stat -c %s "$tmp/seed.iso")" --format raw >/dev/null
  virsh vol-upload "$VM-seed.iso" "$tmp/seed.iso" --pool "$POOL"

  virt-install --name "$VM" --memory "$RAM_MB" --vcpus "$VCPUS" \
    --osinfo linux2022 --boot uefi --import --noautoconsole --graphics none \
    --disk "vol=$POOL/$VM.qcow2,bus=virtio" \
    --disk "vol=$POOL/$VM-seed.iso,device=cdrom" \
    --network "network=$NET,model=virtio" >/dev/null

  log "Warten auf Adresse und SSH"
  local ip="" i
  for i in $(seq 90); do
    ip=$(vm_ip)
    if [ -n "$ip" ] && ssh "${SSH_OPTS[@]}" "admin@$ip" 'cloud-init status --wait >/dev/null; true' 2>/dev/null; then
      echo "    $VM: $ip"
      echo "$ip" > "$STATE/ip"
      return 0
    fi
    sleep 2
  done
  if [ -z "$ip" ]; then
    die "VM hat keine DHCP-Adresse bekommen. Blockiert eine Laptop-Firewall (ufw) $NET_BRIDGE? Siehe 'sudo ufw status verbose'."
  fi
  die "VM ($ip) nicht per SSH erreichbar"
}

destroy() {
  if virsh dominfo "$VM" >/dev/null 2>&1; then
    log "VM $VM entfernen"
    virsh destroy "$VM" >/dev/null 2>&1 || true
    virsh undefine "$VM" --remove-all-storage --nvram >/dev/null
  fi
  rm -f "$STATE/ip"
}

# Ansible against the VM: throwaway key, no host-key pinning (new VM every time).
# The admin keys from files/ssh plus the throwaway key, so base's exclusive
# authorized_keys does not lock this run out.
playbook() {
  local ip; ip=$(cat "$STATE/ip")
  cat "$HERE/files/ssh/admin.authorized_keys" "$STATE/id_ed25519.pub" > "$STATE/authorized_keys"
  (cd "$HERE" && ansible-playbook "$@" -l drtest \
    -e "ansible_host=$ip" \
    -e "ansible_ssh_private_key_file=$STATE/id_ed25519" \
    -e "ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'" \
    -e "admin_authorized_keys_file=$STATE/authorized_keys")
}

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5
          -o BatchMode=yes -o LogLevel=ERROR)

full() {
  mkdir -p "$LOG_DIR"
  local log_file; log_file="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"
  ensure_key
  SSH_OPTS+=(-i "$STATE/id_ed25519")
  local t0 t1 t2 t3 t4 recap="" ok=0
  t0=$(date +%s)
  destroy
  up
  t1=$(date +%s)

  local failed=""
  rm -f "$STATE/run2.log" "$STATE/run3.log"
  log "Lauf 1: site.yml"
  playbook site.yml 2>&1 | tee -a "$log_file" || failed="site.yml (1. Lauf)"
  t2=$(date +%s)

  if [ -z "$failed" ]; then
    log "Lauf 2: site.yml (idempotent?)"
    playbook site.yml 2>&1 | tee -a "$log_file" | tee "$STATE/run2.log" || failed="site.yml (2. Lauf)"
  fi
  t3=$(date +%s)
  recap=$(grep -E '^drtest +:' "$STATE/run2.log" 2>/dev/null | tail -1 || true)

  # Dry run as it is used against the real host (--check --diff): must work and agree
  # that nothing is left to change.
  if [ -z "$failed" ]; then
    log "Lauf 3: site.yml --check (Trockenlauf wie gegen den echten Host)"
    playbook site.yml --check --diff 2>&1 | tee -a "$log_file" | tee "$STATE/run3.log" || failed="site.yml --check"
    grep -qE '^drtest +:.* changed=0 ' "$STATE/run3.log" || failed="${failed:-site.yml --check meldet Änderungen}"
  fi

  if [ -z "$failed" ]; then
    log "verify.yml"
    playbook verify.yml 2>&1 | tee -a "$log_file" || failed="verify.yml"
  fi
  t4=$(date +%s)

  [ -z "$failed" ] && [[ $recap =~ changed=0\  ]] && ok=1
  {
    echo
    echo "=== DR-Test $(date -Is) ==="
    printf 'VM bereitstellen:      %4ds\n' $((t1 - t0))
    printf 'site.yml (1. Lauf):    %4ds\n' $((t2 - t1))
    printf 'site.yml (2. Lauf):    %4ds   %s\n' $((t3 - t2)) "$recap"
    printf 'verify.yml:            %4ds\n' $((t4 - t3))
    printf 'gesamt:                %4ds\n' $((t4 - t0))
    echo "Ergebnis: $([ $ok = 1 ] && echo "OK, idempotent" || echo "FEHLER: ${failed:-2. Lauf hat noch etwas geändert}")"
    echo "Log: $log_file"
  } | tee -a "$log_file"

  if [ $ok = 1 ] && [ "${KEEP:-0}" != 1 ]; then destroy; else echo "VM bleibt stehen: ssh -i $STATE/id_ed25519 admin@$(cat "$STATE/ip")"; fi
  [ $ok = 1 ]
}

# ---------------------------------------------------------------- restore test
# "System disk dead, data disks survive", with real data: the test data exported on the
# host (scripts/maintenance/dr-test-export.sh) plus this laptop's repo clone and SOPS key
# play the surviving disks. Interactive: vault password of restore-secrets.yml and the
# Vault unseal keys (the playbook pauses).
DATA=$STATE/data

ask_vault_pass() {
  # Ansible-Vault password once, up front, checked right away -- not after 8 minutes of
  # site.yml. Kept only in a tmpfs file for this run (removed on exit).
  VAULT_PASS_FILE=$(mktemp -p "${XDG_RUNTIME_DIR:-/tmp}" drtest-vault.XXXXXX)
  chmod 600 "$VAULT_PASS_FILE"
  trap 'rm -f "$VAULT_PASS_FILE"; kill ${PROXY_PID:-} 2>/dev/null' EXIT
  cat <<'HINT'

Es werden zwei Dinge abgefragt:
  1. jetzt:  das ANSIBLE-VAULT-PASSWORT   -> Vaultwarden-Eintrag "Ansible-Vault"
             (der Schlüssel für files/luks/*.vault und restore-secrets.yml --
              NICHT die Borg-Passphrase, die steht IN restore-secrets.yml)
  2. später: die VAULT-UNSEAL-KEYS         -> in einem zweiten Terminal, wenn der Test anhält

HINT
  local vp
  read -rsp 'Ansible-Vault-Passwort (Vaultwarden "Ansible-Vault"): ' vp; echo
  printf '%s\n' "$vp" > "$VAULT_PASS_FILE"; unset vp
  ansible-vault view --vault-password-file "$VAULT_PASS_FILE" "$HERE/files/luks/hdd.key.vault" >/dev/null 2>&1 \
    || die 'Das ist nicht das Ansible-Vault-Passwort: es öffnet files/luks/hdd.key.vault nicht (Vaultwarden "Ansible-Vault").'
  ansible-vault view --vault-password-file "$VAULT_PASS_FILE" "$HERE/restore-secrets.yml" >/dev/null 2>&1 \
    || die 'restore-secrets.yml ist mit einem ANDEREN Passwort verschlüsselt als die LUKS-Schlüssel.
   Neu anlegen: rm restore-secrets.yml; ansible-vault create restore-secrets.yml
   (Passwort = Vaultwarden "Ansible-Vault", Inhalt: vault_borg_passphrase_docker: "<Borg-Passphrase>")'
  # Parse it exactly like Ansible will (YAML), print only the problem -- never the value.
  local check
  check=$(ansible-vault view --vault-password-file "$VAULT_PASS_FILE" "$HERE/restore-secrets.yml" 2>/dev/null \
    | python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(sys.stdin)
except yaml.YAMLError as e:
    print("YAML-Fehler (fehlt das \" am Zeilenende?): " + str(getattr(e, "problem", e))); sys.exit(1)
v = (d or {}).get("vault_borg_passphrase_docker") if isinstance(d, dict) else None
if not isinstance(v, str) or v in ("", "CHANGE-ME"):
    print("keine Zeile vault_borg_passphrase_docker mit einem Wert"); sys.exit(1)
print("ok")') || die "restore-secrets.yml: $check
   Ändern: env EDITOR=nano ansible-vault edit restore-secrets.yml  (Passwort = Vaultwarden \"Ansible-Vault\")
   Zeile:  vault_borg_passphrase_docker: \"<Borg-Passphrase>\""
  echo "    Ansible-Vault-Passwort ok, Borg-Passphrase in restore-secrets.yml vorhanden"
}

restore_test() {
  [ -f "$DATA/EXPORTED" ] || die "Keine Testdaten in $DATA -- auf dem Host: sudo bash scripts/maintenance/dr-test-export.sh,
   dann hier: rsync -a --delete tc:/data/backup/drtest/ $DATA/"
  [ -f "$HERE/restore-secrets.yml" ] || die "restore-secrets.yml fehlt (siehe restore-secrets.example.yml)"
  local sops_key=$HOME/.config/sops/age/keys.txt
  [ -f "$sops_key" ] || die "SOPS-Schlüssel $sops_key fehlt"
  echo "Testdaten:"; sed 's/^/    /' "$DATA/EXPORTED"

  ask_vault_pass

  RAM_MB=${RAM_MB_RESTORE:-12288}; VCPUS=${VCPUS_RESTORE:-6}; DISK_GB=${DISK_GB_RESTORE:-100}
  mkdir -p "$LOG_DIR"
  local log_file; log_file="$LOG_DIR/restore-$(date +%Y%m%d-%H%M%S).log"
  ensure_key
  SSH_OPTS+=(-i "$STATE/id_ed25519")
  local t0 t1 t2 t3 t4 ip
  t0=$(date +%s)
  destroy
  up
  ip=$(cat "$STATE/ip")
  t1=$(date +%s)

  log "Host-Schicht: site.yml"
  playbook site.yml 2>&1 | tee -a "$log_file" || die "site.yml fehlgeschlagen (Log: $log_file)"
  t2=$(date +%s)

  log "Überlebende Platten simulieren (Borg-Repo, Repo-Checkout, SOPS-Schlüssel, Vault-Snapshot)"
  local vssh=(ssh "${SSH_OPTS[@]}" "admin@$ip")
  "${vssh[@]}" 'sudo install -d -o admin -g admin /data/backup/ThinkCentre /data/gitea /home/admin/.config/sops/age'
  rsync -a --delete -e "ssh ${SSH_OPTS[*]}" "$DATA/docker/" "admin@$ip:/data/backup/ThinkCentre/docker/"
  # Repo clone without decrypted .env files (only the .sops versions are needed)
  rsync -a --delete --exclude '*.env' --exclude '__pycache__' -e "ssh ${SSH_OPTS[*]}" \
    "$HERE/../" "admin@$ip:/data/gitea/homelab/"
  rsync -a -e "ssh ${SSH_OPTS[*]}" "$sops_key" "admin@$ip:/home/admin/.config/sops/age/keys.txt"
  "${vssh[@]}" 'chmod 600 /home/admin/.config/sops/age/keys.txt'
  age -d -i "$sops_key" "$DATA/vault.snap.age" | "${vssh[@]}" 'sudo install -m 600 /dev/stdin /root/vault.snap'
  "${vssh[@]}" 'sudo tar -xf - -C /' < "$DATA/extra.tar"
  t3=$(date +%s)

  log "restore.yml (pausiert zum Entsiegeln von Vault)"
  playbook restore.yml --vault-password-file "$VAULT_PASS_FILE" \
    -e restore_vault_snapshot=/root/vault.snap -e '{"restore_nextcloud_placeholder": true}' \
    2>&1 | tee -a "$log_file" || die "restore.yml fehlgeschlagen -- VM bleibt stehen: ssh -i $STATE/id_ed25519 admin@$ip"
  t4=$(date +%s)

  log "verify.yml"
  playbook verify.yml 2>&1 | tee -a "$log_file" || true
  "${vssh[@]}" 'sudo shred -u /root/vault.snap' || true

  {
    echo
    echo "=== DR-Test mit Daten $(date -Is) ==="
    sed 's/^/Testdaten: /' "$DATA/EXPORTED"
    printf 'VM bereitstellen:            %5ds\n' $((t1 - t0))
    printf 'Host-Schicht (site.yml):     %5ds\n' $((t2 - t1))
    printf 'Daten bereitstellen (Test):  %5ds\n' $((t3 - t2))
    printf 'restore.yml (inkl. Unseal):  %5ds\n' $((t4 - t3))
    printf 'RTO ohne Testdaten-Kopie:    %5ds\n' $((t4 - t0 - (t3 - t2)))
    echo "Log: $log_file"
    echo "VM bleibt stehen zum Prüfen: ssh -i $STATE/id_ed25519 admin@$ip   (Ende: $0 destroy)"
  } | tee -a "$log_file"
  echo "Proxy läuft nur so lange wie dieses Skript -- zum Weiterarbeiten in der VM: $0 proxy"
}

# Continue in the kept VM from the service deployment on (data and Vault already done),
# e.g. after fixing a service. Vault must still be unsealed in the VM.
restore_continue() {
  [ -f "$STATE/ip" ] || die "Keine VM -- erst: $0 restore"
  ensure_key
  SSH_OPTS+=(-i "$STATE/id_ed25519")
  ensure_network
  start_proxy
  ask_vault_pass
  local log_file; log_file="$LOG_DIR/restore-continue-$(date +%Y%m%d-%H%M%S).log"
  log "restore.yml ab den Diensten (restore_from=services)"
  playbook restore.yml --vault-password-file "$VAULT_PASS_FILE" \
    -e restore_from=services -e '{"restore_nextcloud_placeholder": true}' 2>&1 | tee -a "$log_file" \
    || die "restore.yml fehlgeschlagen -- Log: $log_file"
  log "verify.yml"
  playbook verify.yml 2>&1 | tee -a "$log_file" || true
  echo "Log: $log_file"
}

case "${1:-full}" in
  up)      ensure_key; SSH_OPTS+=(-i "$STATE/id_ed25519"); up
           echo "Proxy läuft nur so lange wie dieses Skript -- für Arbeit in der VM: $0 proxy" ;;
  proxy)   ensure_network; start_proxy; echo "Proxy auf $PROXY, Log: $LOG_DIR/proxy.log (Strg+C beendet)"; wait ;;
  destroy) destroy ;;
  full)    full ;;
  restore) restore_test ;;
  restore-continue) restore_continue ;;
  *)       sed -n '2,14p' "$0"; exit 1 ;;
esac
