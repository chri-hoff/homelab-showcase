# Disaster recovery

Rebuilding the homelab host from nothing but a fresh Debian install, the surviving data disks
and the backups -- and a test that runs the whole procedure in an isolated VM.

**Measured RTO: about 55-60 minutes** from an empty VM to 36 running containers.

## How it is built

| Layer | Tool | What |
|---|---|---|
| Host | Ansible [`site.yml`](ansible/site.yml), nine roles | packages, users, SSH, LUKS disks and mounts, Docker and its networks, nftables firewall, CrowdSec, deploy user, cron, smartd, Postfix, auditd |
| Data | Ansible [`restore.yml`](ansible/restore.yml) | newest Borg archive back to `/opt/docker`, Vault from its data disk or a raft snapshot, then a pause to unseal by hand |
| Services | `homelab-deploy` | the same forced-command deploy path the update pipeline uses every day, in dependency order, with a health check at the end |

Why two tools instead of putting the Compose stacks into Ansible as well: a recovery-only deploy
path would drift from the daily one between tests. The reasoning and the alternatives are in
[ADR 006](006-disaster-recovery-ansible-host-layer.md).

**Secrets:** three LUKS key files and one Borg passphrase are ansible-vault files (not part of
this export). One password opens them; it is kept in a password manager and on paper. All other
secrets come back with the data. Vault unseal keys are typed by hand and never pass through
Ansible.

## The restore test

[`dr-test.sh`](ansible/dr-test.sh) runs on the laptop in KVM/libvirt:

- an **isolated network without forwarding**; the only way out is
  [`drtest-proxy.py`](ansible/drtest-proxy.py), an allowlist proxy (Debian, Docker registries,
  GitHub, CrowdSec) that logs every allowed and denied host -- the restored homelab cannot reach
  Telegram, mail, DNS providers or the real backups
- test data from [`dr-test-export.sh`](scripts/dr-test-export.sh): a slim Borg repository with
  only the newest archive and a fresh Vault snapshot encrypted to the laptop's key
- modes: host layer only (fresh VM, apply twice -- the second run must change nothing, check
  mode, verify), full restore with real data, continue after a fix

Building and testing found ten problems that would have hit a real recovery, from backups that
had lost their file permissions to data living in named volumes outside the backup. They are
listed at the end of the [runbook](ansible/README.md#6-lessons-from-the-tests).

## Files

| Path | Content |
|---|---|
| [`ansible/README.md`](ansible/README.md) | the runbook: structure, where everything is, step by step, testing, lessons |
| [`ansible/`](ansible/) | playbooks, roles, inventory (test VM only), restore tasks |
| [`ansible/drift-check.yml`](ansible/drift-check.yml) | the same roles without `storage` (needs the ansible-vault password), run weekly in check mode on the host itself; any change it would make is a finding (see [`system-checks/`](../system-checks/)) |
| [`scripts/`](scripts/) | test data export, host inventory script used to write the roles |
| [`dr-restore-test.md`](dr-restore-test.md) | test checklist, every six months (German, pasted into my task app) |
| [`006-disaster-recovery-ansible-host-layer.md`](006-disaster-recovery-ansible-host-layer.md) | ADR |

Losing the data disks together with the host is covered since November 2026: the Nextcloud
repository is mirrored to a storage box (see [`backup/`](../backup/)), the other backups go
off-site with Duplicati. Not covered in the VM test: Nextcloud's data itself (too large for
the laptop).
