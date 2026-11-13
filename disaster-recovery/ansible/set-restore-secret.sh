#!/bin/bash
# Writes restore-secrets.yml (#157): asks for the Borg passphrase (hidden), quotes it
# correctly for YAML whatever characters it contains, and encrypts the file with
# ansible-vault. The plain text exists only in a pipe, never in a file or on screen.
#
#   cd ansible; ./set-restore-secret.sh
#
# Two prompts:
#   "Borg-Passphrase"       -> the Borg passphrase (Vaultwarden entry of the Borg repo, or
#                              HashiCorp Vault homelab/backup/borg-docker)
#   "New Vault password"    -> the ANSIBLE-VAULT password (Vaultwarden "Ansible-Vault")
set -euo pipefail
cd "$(dirname "$0")"

read -rsp 'Borg-Passphrase (wird nicht angezeigt): ' BP; echo
[ -n "$BP" ] || { echo "leer -- abgebrochen"; exit 1; }
read -rsp 'Borg-Passphrase noch einmal: ' BP2; echo
[ "$BP" = "$BP2" ] || { echo "stimmt nicht überein -- abgebrochen"; exit 1; }
unset BP2

echo "Jetzt zweimal das ANSIBLE-VAULT-Passwort (Vaultwarden \"Ansible-Vault\"):"
rm -f restore-secrets.yml.new
printf '%s' "$BP" \
  | python3 -c 'import sys, yaml; sys.stdout.write(yaml.safe_dump({"vault_borg_passphrase_docker": sys.stdin.read()}, width=10000))' \
  | ansible-vault encrypt --output restore-secrets.yml.new -
unset BP
mv restore-secrets.yml.new restore-secrets.yml
echo "restore-secrets.yml geschrieben (verschlüsselt). Prüfen: ansible-vault view restore-secrets.yml | sed -E 's/:.*/: …/'"
