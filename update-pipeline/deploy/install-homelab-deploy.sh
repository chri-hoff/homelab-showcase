#!/bin/bash
# Sets up the restricted deploy path for Kestra (#100 STEP 1-3):
#   - system user "deploy": no password, NOT in group docker
#   - /usr/local/bin/homelab-deploy (root-owned copy of scripts/deploy/homelab-deploy)
#   - sudoers: deploy may run only that script as root, SSH_ORIGINAL_COMMAND is kept
#   - authorized_keys: one key, forced command, no pty/forwarding, only from
#     Kestra's fixed address
#
# Run:  sudo bash scripts/deploy/install-homelab-deploy.sh            (install/update wrapper)
#       sudo bash scripts/deploy/install-homelab-deploy.sh --new-key  (also generate a key pair)
# Idempotent; re-run after every change to homelab-deploy.
#
# --new-key writes the private key to /root/kestra-deploy-key (600) for loading into
# Vault; delete it afterwards.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo ausführen."; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
FROM_NET=172.22.0.250    # Kestra, fixed address in network backend (services/kestra)
USER_NAME=deploy
HOME_DIR=/var/lib/deploy
SUDOERS=/etc/sudoers.d/homelab-deploy

echo "==> User $USER_NAME"
if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd --system --home-dir "$HOME_DIR" --create-home --shell /bin/sh "$USER_NAME"
fi
passwd -l "$USER_NAME" >/dev/null
if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx docker; then
  echo "!! $USER_NAME ist in der Gruppe docker -- entferne"; gpasswd -d "$USER_NAME" docker
fi

echo "==> Wrapper /usr/local/bin/homelab-deploy"
install -o root -g root -m 0755 "$HERE/homelab-deploy" /usr/local/bin/homelab-deploy

echo "==> sudoers $SUDOERS"
TMP=$(mktemp)
cat > "$TMP" <<EOF
# #100: deploy may only run the wrapper; the SSH command is passed through.
Defaults!/usr/local/bin/homelab-deploy env_keep += "SSH_ORIGINAL_COMMAND SSH_CLIENT"
$USER_NAME ALL=(root) NOPASSWD: /usr/local/bin/homelab-deploy
EOF
visudo -cf "$TMP" >/dev/null
install -o root -g root -m 0440 "$TMP" "$SUDOERS"
rm -f "$TMP"

install -d -o "$USER_NAME" -g "$USER_NAME" -m 0700 "$HOME_DIR/.ssh"
AK=$HOME_DIR/.ssh/authorized_keys
OPTS="command=\"sudo -n /usr/local/bin/homelab-deploy\",from=\"$FROM_NET\",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc"

if [ "${1:-}" = "--new-key" ]; then
  # The private key goes to a root-only file, never to the terminal (output of this
  # script tends to get copied around). Load it into Vault, then delete it.
  echo "==> Neues Schlüsselpaar"
  KEYFILE=/root/kestra-deploy-key
  rm -f "$KEYFILE" "$KEYFILE.pub"
  ssh-keygen -q -t ed25519 -N '' -C "kestra-deploy@$(hostname -s)" -f "$KEYFILE"
  echo "$OPTS $(cat "$KEYFILE.pub")" > "$AK"
  rm -f "$KEYFILE.pub"
  echo "    privater Schlüssel: $KEYFILE (600 root) -- in Vault laden und danach löschen"
elif [ -s "$AK" ]; then
  # Keep the existing key, but re-apply the current options
  KEY=$(grep -oE 'ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$' "$AK" | head -1)
  [ -n "$KEY" ] && echo "$OPTS $KEY" > "$AK"
else
  echo "!! Noch kein Schlüssel hinterlegt -- mit --new-key erneut ausführen"
fi
[ -f "$AK" ] && { chown "$USER_NAME:$USER_NAME" "$AK"; chmod 0600 "$AK"; }

echo
echo "Fertig. Test lokal:   sudo homelab-deploy ps | head -c 200"
echo "Journal:              journalctl -t homelab-deploy -n 20"
