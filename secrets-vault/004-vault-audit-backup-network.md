# ADR 004: Vault audit, backup and network isolation

- **Status:** accepted
- **Date:** 2026-10-29
- **Issue:** #101 (related: ADR 002, ADR 003)

## Context

Every service in the homelab fetches its secrets from one HashiCorp Vault (integrated Raft
storage, single node). Three gaps remained after the SOPS-to-Vault migration:

- **No audit trail.** Nobody could tell which identity read or changed which secret.
- **No backup.** The Raft data lived only on an external HDD. The nightly Borg backup covers
  `/opt/docker`, not Vault's data directory, and copying the files of a running Raft store
  would not be consistent anyway. Losing the disk meant rebuilding every service.
- **Too reachable.** Vault was attached to the `frontend` network, where every web-facing
  container (dashboards, file browser, ...) could reach its plain-HTTP API.

## Decision

### Backup: encrypted Raft snapshots with a key that does not live in Vault

- A daily Kestra flow calls `homelab-deploy backup-vault` on the host (ADR 002). The script
  takes a snapshot through the API (`sys/storage/raft/snapshot`, the supported consistent
  method) with an AppRole whose policy can do nothing else. The role only works from the host
  (`secret_id_bound_cidrs`/`token_bound_cidrs`), and its token lives 10 minutes.
- The snapshot is checked (tar.gz with `SHA256SUMS`), encrypted with **age** to a dedicated
  backup key, and written with a checksum next to the other backups; Duplicati copies it to
  cloud storage. Plaintext exists only briefly in tmpfs. Retention: 14 days plus 8 Sundays.
- **The private backup key is kept offline** next to the unseal keys, not in Vault. The SOPS
  key would have been convenient, but it lives in Vault -- a backup that needs Vault to be
  decrypted cannot restore Vault.
- **Restore is tested**, not assumed (`docs/runbooks/vault-restore.md`): decrypt the newest
  snapshot, restore it into a throwaway Vault with `--network none`, unseal with the real key
  shares, read a secret. First test on 2026-10-29; repeated every six months.

### Audit: two devices, shipped to Loki

- Vault refuses requests when no audit device can write. Two independent devices keep it
  available if one fails:
  - `file` on the SSD (`/vault/logs/audit.log`, rotated daily with logrotate + SIGHUP, 30 days):
    the local forensic copy.
  - `file` with `file_path=stdout`: lands in the container log, which Docker rotates and Alloy
    already ships to Loki -- no extra mount, no extra agent.
- Values are HMAC-hashed (Vault's default); the log shows who accessed which path, not the
  secret.
- Alert rules on the audit stream (provisioned Grafana rules, ADR 003): repeated failed AppRole
  logins, any use of a root-policy token, any write under `homelab/`, plus low disk space,
  because a full disk would block Vault through the file device.

### Network: backend only

Vault is attached to the `backend` network only. All consumers -- entrypoints, vault-agent
sidecars, Traefik for the UI, host scripts via the backend address or `docker exec` -- were
checked to be on `backend` before the change.

## Alternatives considered

- **Copy the Raft directory in the existing Borg backup:** not consistent while Vault runs,
  and stopping Vault means sealing it, which takes every dependent service down until a manual
  unseal.
- **Encrypt snapshots with the SOPS key or a key stored in Vault:** circular; see above.
- **Vault Enterprise automated snapshots / cloud auto-unseal:** not available or not wanted for
  a self-hosted single node; auto-unseal would also put the unseal capability on the host.
- **TLS on the Vault listener with an internal CA:** traffic stays on the `backend` bridge, and
  every consumer would need to trust and update the CA. Deferred; the network split removes
  most of the exposure at a fraction of the cost.
- **Syslog or socket audit device as the second device:** the container has no syslog daemon;
  stdout reuses the existing Docker log rotation and Alloy pipeline.

## Consequences

- A disk failure now costs at most one day of secret changes, and the recovery procedure is
  written down and proven.
- The offline items -- unseal key shares, the backup age key, an admin token -- are now the
  single point of failure for recovery and must be kept together and current.
- Audit records and alert rules depend on field names in Vault's audit format (a failed login
  carries `response.data.error`, not a top-level `error`); the alert test runbook catches
  changes after Vault upgrades.
- The host directory for the audit file must belong to Vault's container user: the image's
  entrypoint does not take ownership of it with the `vault server` command line.
