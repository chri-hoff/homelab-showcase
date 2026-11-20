# ADR 006: Disaster recovery -- Ansible builds the host, services deploy as in daily operation

- **Status:** accepted
- **Date:** 2026-11-10
- **Issue:** #157 (related: ADR 002, ADR 004)

## Context

The homelab runs on one mini PC. Before #157 its host setup existed only on the host itself:
packages, users, SSH, LUKS keys and mounts, Docker networks, firewall, CrowdSec, cron jobs,
smartd, Postfix and auditd had been configured by hand over two years. The services were
already code (one Compose stack per service, secrets in Vault, deployed by `homelab-deploy`,
ADR 002). Losing the system disk would therefore have meant rebuilding the host from memory
before any backup could be used.

The scenario to cover first: the system disk (NVMe) or the whole machine fails, the data disks
survive. Offsite copies of the data come later (cheap cloud storage still to be chosen).

Requirements:

- A rebuild must be possible from the laptop alone, without the homelab's own services
  (Gitea, Vaultwarden, Vault are all on the lost host).
- No secret may be stored in plain text in the repository, and unseal keys must never pass
  through automation.
- The procedure must be testable end to end without touching production, and the test must
  not be able to reach production or the internet freely.
- The recovery must use the same deploy path as daily operation, or it rots between tests.

## Decision

- **Two layers, two tools.** Ansible (`ansible/site.yml`, nine roles) builds the host layer:
  everything below Docker plus the host services around it. The services are deployed with
  `homelab-deploy`, the same forced-command path Kestra uses every day. `restore.yml` adds
  only what that path cannot do on an empty host: the Borg restore of `/opt/docker`, Vault
  (which `homelab-deploy` itself needs) and the stacks `homelab-deploy` refuses on purpose
  (Vault, Traefik, Authentik, Kestra, started with their SOPS env files).
- **Bootstrap secrets in ansible-vault, one password.** The three LUKS key files and the Borg
  passphrase of the docker repository are ansible-vault files in the repository. One password
  opens all of them; it lives in Vaultwarden and on paper, never on a disk of the homelab.
  Everything else comes back with the data: SOPS key and SSH keys from `/home` on the SSD,
  service secrets from Vault (its data disk, or a raft snapshot), CrowdSec and Postfix
  credentials from the restored files.
- **Manual on purpose:** installing Debian, typing the ansible-vault password, unsealing Vault
  (3 of 5 keys, typed into the Vault container, never into Ansible).
- **Tested in an isolated VM.** `ansible/dr-test.sh` runs the whole procedure in a KVM VM on
  the laptop: isolated libvirt network without forwarding, egress only through an allowlist
  proxy (Debian, Docker registries, GitHub, CrowdSec). Test data come from
  `scripts/maintenance/dr-test-export.sh`: a slim Borg repository with only the newest archive
  and a fresh Vault snapshot, encrypted to the laptop's SOPS key.
- **The repository has an offsite copy.** Gitea pushes to a private GitHub mirror on every
  push and every 8 hours; the daily Kestra summary reports the mirror's state.

## Alternatives considered

- **Everything in Ansible, Compose stacks included** (`community.docker.docker_compose_v2`).
  One tool, but a second deploy path next to `homelab-deploy` that would only run during a
  disaster and silently drift from the daily one. Rejected.
- **Disk image of the system disk** (Clonezilla, `dd`). Fast to restore, but a binary snapshot
  of an undocumented state: it reproduces every past mistake, goes stale between runs and
  cannot be reviewed. Rejected.
- **Declarative OS (NixOS).** Would make the host layer fully reproducible, but means
  migrating the running host. Out of scope for a recovery issue.
- **Backup-only, rebuild by hand with a checklist.** Cheapest, but untestable in practice and
  exactly the state #157 started from.

## Consequences

- Measured RTO in the test VM: about 55-60 minutes from an empty VM to 36 running containers
  (host layer 5-6 min, Borg restore 10 min, unseal 3 min, services 33-43 min, mostly image
  pulls). Not included: replacement hardware, installing Debian, fetching the passwords.
- Building and testing found ten problems that would have hit a real recovery (list in
  `ansible/README.md`, section 6), among them backups without group/other permissions, data
  in named volumes outside the backup, owners lost by name-based Borg restore
  (`--numeric-ids`) and a locally built image missing on a fresh host.
- Every host change now has to go through `site.yml`; `ansible-playbook site.yml --check` on
  the real host must stay at zero changes, or the code has drifted.
- The ansible-vault password is a new single point of failure and must stay findable
  (Vaultwarden plus paper).
- Not covered yet: losing the data disks together with the host (no offsite copy of the
  Nextcloud data), and Nextcloud's data in the test (the VM starts it without data).
  *Update 2026-11-20 (#202):* the Nextcloud Borg repository is now mirrored nightly to a Hetzner
  Storage Box (rsync, provider-side snapshots against a mirrored deletion), and a restore
  directly from the box over SFTP was tested (`docs/runbooks/offsite-storagebox.md`). With the
  Docker repository, database dumps and Vault snapshots already off-site via Duplicati, losing
  host and data disks together is covered. Still open: Nextcloud's data in the VM test.
- The restore test runs every six months and after larger changes to the host layer.
