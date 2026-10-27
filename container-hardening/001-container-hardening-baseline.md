# ADR 001: Container hardening baseline

- **Status:** accepted
- **Date:** 2026-10-27
- **Issue:** #103 (related: #100 Docker socket, #101 Vault, #86 version pinning)

## Context

The homelab runs about 38 containers on a single mini PC. Edge security (Traefik middleware
chains, Authentik, CrowdSec, host firewall) was in place, but the containers themselves ran with
Docker's defaults: the default capability set, no `no-new-privileges`, no PID or memory limits,
cAdvisor as `privileged`, partly no health checks, and no log rotation on the daemon. A
compromised service would have had far more rights than it needs.

Constraints:

- Everything runs on one host, so a runaway container (memory, fork bomb, log file) can take
  down all other services.
- The services are live and used daily; changes must roll out in small, reversible batches.
- Most images are upstream images whose entrypoints I do not control.

## Decision

### 1. A baseline per container, enforced by a check

Every container in every compose file must have:

| Check | Setting |
|---|---|
| no-new-privileges | `security_opt: [no-new-privileges:true]` |
| cap_drop | `cap_drop: [ALL]`, then only the capabilities the image provably needs via `cap_add` |
| pids_limit | per container, sized to its process model |
| mem_limit | `mem_limit` sized from 30-day Prometheus/cAdvisor peaks plus headroom (`deploy.resources` had no effect in this setup) |
| healthcheck | in the compose file or in the image |
| not-privileged | no `privileged: true` |

`scripts/security/check-container-hardening.py` reads the compose files (no Docker needed) and
fails on any gap that is not justified in `container-hardening-exceptions.yaml`. An exception
for a check that passes, or for a container that no longer exists, also fails the check, so the
exception list cannot silently go stale.

### 2. Capabilities are determined empirically, per image

Instead of guessing, each batch was inspected on the host first (`docker top`, ownership of the
data directories, `getcap` on binaries), then deployed, then the logs were searched for
`EPERM`/`EACCES`/`fatal`. Recurring patterns:

| Pattern | Capabilities |
|---|---|
| Entrypoint starts as root, `chown`s its data directory, drops to a service user (`gosu`, `su-exec`, `setpriv`) | `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID` |
| `setpriv --bounding-set` (Redis 8) | additionally `SETPCAP` |
| Root process signals children running as another user (Gitea, Nextcloud) | additionally `KILL` |
| Binary with file capabilities (`setcap`, e.g. AdGuard Home) | that capability must stay in the bounding set, otherwise `exec` fails with EPERM |
| Root process writing to a volume owned by another UID | `DAC_OVERRIDE` |
| Image already runs as non-root, binds no privileged port | none |

Ports below 1024 do not need `NET_BIND_SERVICE` by itself: Docker sets
`net.ipv4.ip_unprivileged_port_start=0` inside containers. It is only needed for file
capabilities as above.

### 3. Daemon defaults (`/etc/docker/daemon.json`)

- `log-opts` `max-size: 10m`, `max-file: 3`: container logs no longer grow without bound.
- `live-restore`: a daemon restart or upgrade does not stop containers.
- `no-new-privileges: true` as default, so containers started outside the repository (task
  runners, one-off `docker run`) get it too. Collabora opts out explicitly.
- `icc: false`: no traffic between containers on the default bridge. All stacks use their own
  networks, so this only affects ad-hoc containers.

The apply script activates `live-restore` with a reload first, then restarts the daemon, so
applying the file does not stop a single container.

### 4. Continuous image scanning

A weekly Kestra flow scans the images of all running containers with Trivy (throwaway container,
itself hardened) and sends the count of fixable HIGH/CRITICAL findings per image to Telegram.
Remediation is the existing update pipeline: newer images.

## Alternatives considered

- **`userns-remap`**: remaps container root to an unprivileged host UID. Rejected for now: every
  bind mount under `/opt/docker` (owned by UIDs 0, 999, 1000, 65534, ...) would have to be
  re-owned, and the gain over `cap_drop: ALL` + `no-new-privileges` is small for this threat
  model.
- **Rootless Docker**: same migration cost, plus problems with privileged ports, cAdvisor and
  the Docker-socket consumers.
- **`read_only: true` root filesystems**: tracked as an informational column only. Most upstream
  images write to undocumented paths; adding `tmpfs` mounts per image is a separate step.
- **Custom seccomp/AppArmor profiles**: Docker's defaults stay active; custom profiles per image
  are not worth the maintenance for a single-user homelab.

## Consequences

- All 38 containers meet the baseline or have a documented exception (see the matrix). Current
  exceptions: Collabora without `no-new-privileges` (jail file capabilities), health checks
  defined in images, one-shot vault-agent sidecars, and the distroless Loki image (monitored
  externally).
- cAdvisor no longer runs privileged (`DAC_READ_SEARCH`, `SYSLOG`, `/dev/kmsg`).
- Vault runs without `IPC_LOCK` (`disable_mlock = true`, as recommended for integrated storage).
- Image updates can change entrypoints and with them capability needs. After every update, the
  logs must be checked for EPERM; the health checks surface most failures automatically.
- Lessons from the rollout: test capability changes for critical services (DNS) in a throwaway
  container against the real volumes before deploying; grep logs for `fatal`, not just `error`.

## Open

- ~~Docker socket access and Authentik's `user: root`: #100~~ -- resolved, see ADR 002.
- Images on `:latest` make scan results hard to compare over time: #86.
