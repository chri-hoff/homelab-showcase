# Disaster recovery: rebuilding the homelab host with Ansible

Runbook for rebuilding the ThinkCentre after a failure (issue #157). Ansible builds the
host; the data comes from the disks that survived and from the backups. A test VM on the
laptop runs the same procedure end to end (`dr-test.sh`).

**Scenario this covers:** the system disk (NVMe) or the whole machine is lost, the data
disks survive. Other scenarios: see [Other failures](#other-failures).

---

## 1. How the recovery is built

```
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ 0. Debian 13 installed by hand (new NVMe or new machine), SSH key for admin  │
  └───────────────┬────────────────────────────────────────────────────────────┘
                  ▼   from the laptop
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ 1. site.yml     host layer: packages, users, SSH, disks (LUKS + mounts),    │
  │                 Docker + networks, firewall, CrowdSec, deploy user, cron,   │
  │                 smartd, Postfix, auditd                                     │
  └───────────────┬────────────────────────────────────────────────────────────┘
                  ▼   the surviving disks are mounted again now
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ 2. restore.yml  data + services:                                            │
  │                 Borg archive -> /opt/docker                                 │
  │                 Vault start (data on wd-750, or from a snapshot)            │
  │                 ── PAUSE: unseal Vault by hand ──                           │
  │                 all stacks in dependency order, health check                │
  │                 runs site.yml again at the end                              │
  └───────────────┬────────────────────────────────────────────────────────────┘
                  ▼
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ 3. Checks       verify.yml, Telegram + mail test, service spot checks       │
  └────────────────────────────────────────────────────────────────────────────┘
```

Two tools on purpose: **Ansible builds the host**, the services are deployed the same way
as in daily operation (`homelab-deploy`, the path Kestra uses, #100). `restore.yml` only
adds what the daily path cannot do on an empty host: the Borg restore, Vault (which
`homelab-deploy` itself needs) and the services `homelab-deploy` refuses on purpose
(Traefik, Authentik, Kestra).

**Manual steps, by design:** installing Debian, typing the Ansible-Vault password, and
unsealing Vault. Unseal keys never pass through Ansible.

**Run `site.yml` twice** (once before, once at the end of `restore.yml`): some host roles
read files that only exist after the restore (CrowdSec's Telegram token and the Traefik
bouncer key, Postfix's smtp credentials).

---

## 2. Where everything is

### Secrets you need

| What | Needed for | Where |
|---|---|---|
| **Ansible-Vault password** | opens `files/luks/*.vault` and `restore-secrets.yml` | Vaultwarden entry **"Ansible-Vault"** + **paper** with the unseal keys |
| **Vault unseal keys** (3 of 5) | unsealing Vault during `restore.yml` | password manager + paper |
| **Vault admin token** | reading/changing secrets by hand | password manager + paper |
| SSH key of the laptop (`~/.ssh/p52`) | Ansible connects as `admin` | laptop; FIDO keys `main`/`backup` as fallback |
| sudo password of `admin` | `-K` / "BECOME password" | the one you set during the Debian install |
| **Vault backup age key** (`AGE-SECRET-KEY-1…`) | only if wd-750 is lost too (snapshot) | password manager "Vault backup age key" + paper |

Do not mix up the two "vault" things: the **Ansible-Vault password** locks files in this
repo; **HashiCorp Vault** is the secret store of the homelab (unseal keys, admin token).
The **Borg passphrase** is not typed anywhere -- it is the *content* of
`restore-secrets.yml` (also in Vaultwarden and in HashiCorp Vault
`homelab/backup/borg-docker`).

### Secrets that come back by themselves

| What | Comes from |
|---|---|
| LUKS keyfiles of the data disks | `files/luks/*.key.vault` (repo, ansible-vault) |
| Borg passphrase `/opt/docker` | `restore-secrets.yml` (repo, ansible-vault) |
| SOPS age key (decrypts every `*.env.sops`) | `/home/admin/.config/sops/age/keys.txt` (SSD, survives) |
| AppRole IDs, smtp login, Telegram token for alerts | `/opt/docker/secrets/` (Borg restore) |
| Traefik bouncer key, Traefik/Vault configs | `/opt/docker/...` (Borg restore) |
| everything in HashiCorp Vault | Vault's Raft data on wd-750 (or the snapshot) |

### Data

| What | Where | Disk (serial) |
|---|---|---|
| Borg repo of `/opt/docker` | `/data/backup/ThinkCentre/docker` | SSD `sda`, Samsung 870 QVO `<DISK_SERIAL>` |
| This repo (host clone, incl. gitignored configs) | `/data/gitea/homelab` | SSD `sda` |
| This repo, off-site (tracked files only) | private GitHub mirror `owner/homelab-mirror` (Gitea push mirror, on push + every 8 h) | GitHub |
| `/home` (SOPS key, admin's SSH keys) | `/home` | SSD `sda` |
| Loki logs, `kestra-state` | `/data/loki`, `/data/kestra-state` | SSD `sda` |
| Vault Raft data, Kestra storage | `/mnt/wd-750/docker/data/{vault,kestra}` | LUKS `wd-750`, WD7500BPKT `<DISK_SERIAL>` |
| Vault snapshots (daily, age-encrypted) | `/data/backup/ThinkCentre/vault/` + OneDrive (Duplicati) | SSD `sda` |
| Nextcloud data | `/mnt/nextcloud` | LUKS `nextcloud_crypt`, WD50NDZW `<DISK_SERIAL>` |
| Nextcloud Borg repo | `/mnt/bk_nxc_data` | LUKS `bk_nxc_data`, WD50NDZW `<DISK_SERIAL>` |
| Lost with the NVMe, **not** needed back | `/`, `/var` (`/var/lib/docker`: images, CrowdSec DB), `/tmp` | NVMe Samsung 970 EVO Plus `<DISK_SERIAL>` |

Always identify disks by **serial**, never by `sdX` -- the letters change between boots.

### This directory

| File | Purpose |
|---|---|
| `site.yml` | host layer (roles in `roles/`) |
| `restore.yml`, `tasks/restore-*.yml` | data and services |
| `drift-check.yml` | `site.yml` ohne `storage`, läuft wöchentlich (freitags) im Check-Modus auf dem Host selbst (Systemcheck, ADR 007) – Änderungen am Host außerhalb von Ansible fallen so auf |
| `verify.yml` | read-only checks, also against the real host |
| `inventory/host_vars/thinkcentre.yml` | disks (UUIDs, labels), smartd, mail sender |
| `inventory/host_vars/drtest.yml` | the test VM: no disks, proxy, isolation switches |
| `files/luks/*.key.vault` | LUKS keyfiles (ansible-vault) |
| `files/ssh/` | `admin.authorized_keys`, Kestra's `deploy.pub` |
| `restore-secrets.yml` | Borg passphrase (ansible-vault); write it with `set-restore-secret.sh` |
| `dr-test.sh`, `drtest-proxy.py` | the automated test (section 5) |

---

## 3. Recovery step by step

### 0. Preparation on the laptop

```fish
cd ~/Dokumente/projekte/gitea/homelab        # or a fresh clone from the mirror
git pull
cd ansible
ansible-galaxy collection install -r requirements.yml
ssh-add ~/.ssh/p52
```

If Gitea is gone with the host, the repo is still on the laptop and on the host's SSD
(`/data/gitea/homelab`, readable once the SSD is mounted). Off-site there is the private
GitHub mirror (needs a GitHub login on the laptop):
`git clone https://github.com/owner/homelab-mirror.git homelab`. It holds the tracked
files only -- the gitignored configs (`services/*/config`, READMEs) come back with Borg.
The daily Kestra summary reports the mirror's state; its token (fine-grained, Contents
read/write on that one repo) expires yearly -- regenerate it and re-add the mirror in Gitea.

### 1. Install Debian 13

- netinst, **UEFI**, hostname `ThinkCentre`, user `admin` (sudo), tasksel: only
  *SSH server* and *standard system utilities*.
- Partition the **new** NVMe only. Do not touch the SSD and the WD disks. The layout of
  the old NVMe was `/boot/efi`, `/`, swap, `/tmp`, `/opt`, `/var`; `/opt` needs room for
  `/opt/docker` (about 20 GB), `/var` for the Docker images.
- Network: DHCP; the router hands out `198.51.100.10` (check that the reservation follows
  the new MAC if the machine was replaced).
- From the laptop: `ssh-copy-id -i ~/.ssh/p52 admin@198.51.100.10`

### 2. Host layer

```fish
ansible-playbook site.yml -l thinkcentre -K --ask-vault-pass
```
Prompts: `BECOME password` = sudo password of admin on the new host; `Vault password` =
**Ansible-Vault password**.

Afterwards the data disks are open and mounted: `ssh tc 'findmnt /data /home /mnt/wd-750 /mnt/nextcloud'`.
`/home` is now the old one from the SSD (with the SOPS key and admin's authorized_keys).

### 3. Data and services

```fish
ansible-playbook restore.yml -l thinkcentre -K --ask-vault-pass
```
- Refuses to run if `/opt/docker` is not empty (it never overwrites a running host) or if
  the newest archive was made before the permission fix of 2026-11-09 (#164).
- **Pause:** Vault is up and sealed. In a second terminal:
  ```fish
  ssh tc
  docker exec -it vault vault operator unseal -address=http://127.0.0.1:8200   # 3x, three different keys
  ```
  until `Sealed false`, then Enter in the first terminal.
- Order of the stacks: Vault → docker-socket-proxy → Postgres, MariaDB, Redis → Traefik,
  Authentik → Gitea, AdGuard, Vaultwarden → Kestra (creates the network `supabase-hooks`)
  → Supabase → monitoring → the rest.
- Ends with a summary (duration, containers that are not healthy) and runs `site.yml`
  again.

**wd-750 lost too** (Vault data gone): restore Vault from the newest snapshot instead.
Decrypt it with the offline age key into tmpfs on the host (see
`docs/runbooks/vault-restore.md`, step 1), then:
```fish
ansible-playbook restore.yml -l thinkcentre -K --ask-vault-pass -e restore_vault_snapshot=/run/vault-restore/vault.snap
```
Secrets changed after the snapshot (e.g. rotated AppRole secret IDs) must be re-issued.

### 4. Checks

```fish
ansible-playbook verify.yml -l thinkcentre -K
```
On the host:
```fish
docker ps --format '{{.Names}} {{.Status}}' | grep -v healthy          # should be empty
sudo cscli notifications test telegram -a '{"decisions":[{"value":"192.0.2.1","type":"ban","duration":"1m","scenario":"homelab/dr-test","origin":"cscli"}],"source":{"cn":"XX","as_name":"Test"}}'
echo "Recovery-Test" | mail -s "ThinkCentre wieder da" root
sudo homelab-deploy crowdsec-asn-sync                                # ASN bans now, not at 04:15
```
Then: log in to Authentik, open Nextcloud, Vaultwarden, Grafana (alerts), Uptime Kuma
(all green?), check that Kestra's flows run.

What does not come back: CrowdSec's alert history and current bans (local DB on `/var`;
the ASN bans return with the sync, the rest builds up again), Docker images (pulled
again), the CrowdSec console enrollment (`cscli console enroll` if wanted).

---

## 4. Other failures

| Lost | What to do |
|---|---|
| only wd-750 (Vault data) | host keeps running; new disk, Vault from snapshot (`docs/runbooks/vault-restore.md`) |
| SSD `sda` (`/data`, `/home`) | Borg repo and Vault snapshots are gone locally -- restore them from OneDrive with Duplicati first; the SOPS key is also on the laptop; then as above |
| Nextcloud disk | Borg repo on `/mnt/bk_nxc_data` (`scripts/backup/backup_nextcloud_borg.sh`) |
| both Nextcloud disks | no offsite copy yet (open point) |

---

## 5. Testing: `dr-test.sh`

Runs on the laptop in KVM/libvirt. The VM sits in an **isolated network without
forwarding**; its only way out is `drtest-proxy.py` on the laptop with an allowlist
(Debian, Docker registries, CrowdSec, GitHub). The restored homelab in the VM can
therefore not reach Telegram, smtp, ipv64, Let's Encrypt, Gitea or OneDrive. The proxy
log (`~/.local/state/homelab-drtest/logs/proxy.log`) lists every allowed and denied host.

| Command | What it tests |
|---|---|
| `./dr-test.sh` | host layer: fresh VM → `site.yml` → again (must change nothing) → `--check` → `verify.yml` → VM removed |
| `./dr-test.sh restore` | full recovery with real data (interactive: Ansible-Vault password, unseal keys) |
| `./dr-test.sh restore-continue` | continue a kept restore VM from the services on (after a fix) |
| `./dr-test.sh destroy` / `proxy` | remove the VM / run only the proxy |

Test data for `restore` (on the host, then fetch):
```fish
sudo bash scripts/maintenance/dr-test-export.sh          # on the ThinkCentre
rsync -a --delete tc:/data/backup/drtest/ ~/.local/state/homelab-drtest/data/
```
The export holds a slim Borg repo with only the newest archive, a fresh Vault snapshot
(encrypted to the SOPS key the laptop already has) and `kestra-state`. The VM restores
Vault from that snapshot, so the test also covers the "wd-750 lost" path. Nextcloud
starts with an empty data directory (container only): it then reports "Environment not
properly prepared" and stays unhealthy -- expected, its `appdata_*` lives on the data
disk. Loki starts empty.

### Measured RTO (2026-11-10, first clean full run, archive of 2026-11-09)

| Phase | Time |
|---|---|
| VM ready (cloud-init) | 0:25 |
| Host layer (`site.yml`) | 5:53 |
| Borg restore (docker archive) | 10:37 |
| Vault up incl. unseal by hand | 3:12 |
| All services started (image pulls included) | 33:22 |
| `site.yml` again + `verify.yml` | 6:26 |
| **RTO (without copying the test data)** | **≈ 60 min** |

Second run (2026-11-10 afternoon, after rotating the Borg passphrases, archive of
2026-11-10 12:28): host layer 4:57, Borg restore 10:19, services done after 43:30,
**RTO ≈ 55 min**, same result. This also proved the new passphrase in
`restore-secrets.yml`.

Result (both runs): 36 containers running (+3 one-shot vault-agent sidecars exited 0), all healthy
except Nextcloud (expected, see above); `restore.yml` and `verify.yml` with `failed=0`.
Most of the service phase is pulling images through the test proxy; on the real host with
a direct uplink it should be shorter. Not included: getting the replacement hardware,
installing Debian, fetching the Ansible-Vault password and unseal keys from Vaultwarden.

---

## 6. Lessons from the tests

Found while building and testing this, all fixed:

- Backups had lost group/other permissions (`chmod -R go-rwx` before `borg create`) --
  fixed 2026-11-09 (#164); `restore.yml` checks the archive.
- Borg restores owners by **name**; container UIDs then map to other names on a new host
  → `borg extract --numeric-ids`.
- AdGuard's config and Supabase's pgsodium key lived in named Docker volumes, outside the
  backup (#163).
- `homelab-vault-agent:1.0` is built locally, it is in no registry → `restore.yml` builds it.
- The network `adguardhome_network` was `external` but created by nobody.
- CrowdSec refuses to start (FATAL) without reaching its central API.
- Debian 13 has no `/etc/timezone` any more; Vault mounts it.
- A missing `/data/loki` is created by Docker as root; Loki (uid 10001) then cannot write
  → `restore.yml` creates it with the right owner.
- `docker cp` keeps root:600; the vault CLI in the container cannot read the snapshot.
- `cscli notifications test` without decisions sends an empty text that Telegram rejects
  silently -- test with `-a` as above.
