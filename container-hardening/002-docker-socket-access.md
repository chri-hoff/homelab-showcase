# ADR 002: No Docker socket in application containers

- **Status:** accepted
- **Date:** 2026-10-27
- **Issue:** #100 (related: #103 container hardening, ADR 001)

## Context

Six containers had the Docker socket mounted: Kestra (deploys, Docker task runner),
the Kestra task containers (`docker compose` during updates), the Authentik worker (as root),
Traefik, Uptime Kuma and Alloy (read-only mounts), plus dockhand (a Docker management UI).
Access to the socket is root on the host: whoever controls it can start a privileged
container with `/` mounted. A `:ro` mount does not change that, the API stays fully usable.

In addition, the update task mounted the admin's whole `~/.ssh` into a root container whose
image contained `sudo`, Kestra allowed every flow to mount arbitrary host paths
(`volume-enabled: true`), and the task image downloaded `sops` and `yq` as "latest" without
checksums while handling the SOPS age key.

A compromised Kestra, Authentik or Traefik therefore meant a compromised host, and secrets of
every container were readable via `docker inspect`/`exec`, regardless of Vault policies.

## Decision

### Write access: a forced-command wrapper instead of the socket

Kestra keeps the job of deploying, but it reaches the host only through
`homelab-deploy` (`scripts/deploy/`):

- SSH user `deploy`, no password, **not** in group `docker`.
- `authorized_keys`: one key, `command="sudo -n /usr/local/bin/homelab-deploy"`,
  `from="<Kestra's fixed IP>"`, no PTY, no forwarding. The private key lives in Vault and
  reaches Kestra as a `secret()` at startup.
- sudoers: `deploy` may run only that wrapper; `SSH_ORIGINAL_COMMAND` is passed through.
- The wrapper accepts a fixed list of actions (`deploy <service>`, `auto-update`, `ps`,
  `update-check`, `backup-mariadb`, `trivy-scan`), checks service names against
  `^[a-z0-9][a-z0-9-]*$` and the repository, never touches Vault, Authentik, Traefik or
  Kestra, refuses `latest`, fetches the SOPS age key from Vault only for the duration of a
  call (tmpfs), runs git as the checkout owner, serializes calls with `flock` and logs every
  call (`journalctl -t homelab-deploy`).

Kestra's flows run in the Kestra container itself (Process runner: curl and python3);
`versions.yaml` is committed through the Gitea API instead of `git push` with an SSH key.

### Read access: a socket proxy on its own network

Traefik, Uptime Kuma and Alloy only read (service discovery, container monitors, log
discovery). They use `tecnativa/docker-socket-proxy` (`services/docker-socket-proxy`):
GET on containers, events, info, networks, ping and version; everything else, including all
POST/DELETE, is rejected (tested). The proxy sits on an internal network `socket-proxy` that
only these three join, because container inspect shows environment variables.

### Authentik, dockhand

Only the embedded outpost is used, so the worker needs no Docker integration: socket and
`user: root` removed, server and worker run as the image user without capabilities.
dockhand needs write access to the socket by design and was retired.

## Alternatives considered

| Option | Why not |
|---|---|
| Socket proxy for Kestra too | Deploys need `containers/create`, which still allows privileged containers with host mounts. |
| Deploy user in group `docker` via SSH | Group `docker` is root-equivalent; nothing gained over the socket. |
| Rootless Docker / user namespaces | Large migration (see ADR 001); does not remove the need to restrict what Kestra may deploy. |
| Kestra Docker task runner with a restricted image | The runner itself needs the socket. |

## Consequences

- No compose file and no flow mounts `/var/run/docker.sock` except the proxy (checked with
  `grep` over `services/` and the flows). The Trivy scan starts its throwaway container from
  the wrapper on the host, not from a container.
- A compromised Kestra can at most redeploy allow-listed services at the versions in
  `versions.yaml` and read what its own Vault policy allows. It cannot start arbitrary
  containers or read other containers' environments.
- Vault, Authentik, Traefik and Kestra are deployed manually only (`sops-update`).
- New host-side actions need a change to the wrapper and a re-run of the installer --
  deliberately: every new capability is a reviewed code change.
- Monitoring: the wrapper's journal entries reach Loki via Alloy; a Grafana alert fires on
  rejected calls, excluded services and calls that do not come from Kestra.

## Open

- The SSH task does not pin the host key (`strictHostKeyChecking: no`; the plugin has no
  known-hosts property). Accepted: the connection only crosses the host's own Docker bridge,
  and an attacker able to impersonate the host there would already control Docker networking.
- The other webhook keys (Telegram commands, Supabase status hook) are still literal values in
  the flows; they are only reachable on the internal network. The Gitea push webhook of
  `update-on-merge` takes its key from Vault via `secret()`.
