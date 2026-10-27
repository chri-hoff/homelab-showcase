# Container hardening: least privilege for every container

Edge security decides who reaches a service. This layer limits what a service can do once
something goes wrong inside it: every container drops all Linux capabilities and gets back only
what its image provably needs, cannot gain privileges, and has hard limits for memory and
processes. A check script keeps it that way.

The reasoning, alternatives and trade-offs are in the
[ADR](001-container-hardening-baseline.md). The full per-container table is in
[MATRIX.md](MATRIX.md).

## Baseline

```yaml
    mem_limit: 512m          # from 30-day peaks + headroom
    pids_limit: 128
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:                 # only what the image needs, with a comment explaining why
      - NET_BIND_SERVICE
    healthcheck:
      test: ["CMD", "wget", "-qO", "/dev/null", "http://127.0.0.1:80/login.html"]
```

Every compose file carries a `# Hardening: ...` comment next to these settings that explains
each capability.

## Check script

`check/check-container-hardening.py` parses all compose files (no Docker needed) and fails when
a container lacks one of the seven baseline checks (the six above plus a pinned image version) without a justified entry in
`check/container-hardening-exceptions.yaml`. An exception that is no longer needed fails the
check too, so the list cannot rot.

```
$ python3 scripts/security/check-container-hardening.py
39 Container, 0 unbegründete Lücken, 0 veraltete Ausnahmen
```

(Output is in German, like all my operational scripts: 39 containers, 0 unjustified gaps,
0 stale exceptions. The script expects the `services/*/docker-compose.yaml` layout of my
private repository.)

## Finding the right capabilities

Capabilities were not guessed but determined per image: inspect the running processes and the
ownership of data directories, deploy, then search the logs for `EPERM`, `EACCES` and `fatal`.
Some cases that were not obvious:

| Container | Finding |
|---|---|
| AdGuard Home | The binary carries the file capability `cap_net_bind_service=eip`. Without it in the bounding set, `exec` fails before the process starts. It runs as root on volumes owned by `nobody`, so it also needs `DAC_OVERRIDE`. |
| Redis 8 | The new entrypoint drops privileges with `setpriv --bounding-set`, which needs `SETPCAP`. Switching the command to exec form made it run as the `redis` user. |
| Collabora | Jails use file capabilities on helper binaries, so `no-new-privileges` has to stay off. This is the one documented exception for that check. |
| cAdvisor | Ran as `privileged`. Now `DAC_READ_SEARCH` + `SYSLOG` + `/dev/kmsg` is enough. |
| Vault | `IPC_LOCK` removed: integrated storage runs with `disable_mlock = true`. |
| Loki | Distroless image without shell or HTTP client, so no in-container health check; Uptime Kuma checks `/ready` from outside. |

Binding ports below 1024 does not need `NET_BIND_SERVICE` on its own: Docker sets
`net.ipv4.ip_unprivileged_port_start=0` inside containers.

## Docker socket

Only one container mounts `/var/run/docker.sock`: a read-only socket proxy
(`socket-proxy/`), on its own internal network that only Traefik, Uptime Kuma and Alloy
join. Kestra deploys through a forced-command SSH wrapper on the host (`homelab-deploy`, see
the [update pipeline](../update-pipeline/)), as a user that is not in the `docker` group.
Details and rejected alternatives: [ADR 002](002-docker-socket-access.md).

## Docker daemon

`daemon/docker-daemon.json` sets log rotation (`10m` x 3), `live-restore`, `no-new-privileges` as
default for every container (including ones started by Kestra) and `icc: false`.
`daemon/apply-docker-daemon.sh` validates the file, activates `live-restore` with a reload
first and only then restarts the daemon. Applying it stopped none of the running containers.

## Image scanning

`trivy/trivy-scan.sh` runs Trivy as a hardened throwaway container against the images of all
running containers. The Kestra flow `trivy/trivy-scan.yml` runs it weekly and sends the number of
fixable HIGH/CRITICAL findings per image to Telegram. Fixing them is the job of the
[update pipeline](../update-pipeline/).

## Files

| Path | Content |
|---|---|
| `001-container-hardening-baseline.md` | ADR: decision, alternatives, consequences |
| `MATRIX.md` | generated matrix of all containers and the exception list |
| `check/` | check script and exception list |
| `daemon/` | `daemon.json` and the apply script |
| `trivy/` | scan script and Kestra flow |
| `socket-proxy/` | read-only Docker API for Traefik, Uptime Kuma, Alloy |
| `002-docker-socket-access.md` | ADR: no Docker socket in application containers |

The compose files with the per-service settings live in the other folders of this repository.
