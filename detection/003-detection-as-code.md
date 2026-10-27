# ADR 003: Detection as code

- **Status:** accepted
- **Date:** 2026-10-27
- **Issue:** #123 (builds on #100 and #103)

## Context

ADR 001 and ADR 002 reduce what a compromised container or flow can do. They do not tell me
when something unusual happens. The building blocks were already there: Alloy ships the
systemd journal and container logs to Loki, node exporter feeds Prometheus, and Grafana can
send alerts to Telegram. The first rules were clicked together in the Grafana UI, which made
them invisible in Git, hard to review and easy to lose.

## Decision

1. **Few, high-signal rules.** Each rule watches for something that normally does not happen
   on this host, so that every message is worth reading:

   | Rule | Signal |
   |---|---|
   | SSH login | any login except the deploy wrapper's own logins from Kestra |
   | Failed sudo | wrong password, user not in sudoers |
   | Users or groups changed | `useradd`, `usermod`, `passwd`, ... |
   | AppArmor denial | a hardened container tried more than allowed (ADR 001) |
   | OOM kill | a process hit its memory limit |
   | Critical file changed | auditd watch on sudoers, sshd config, `authorized_keys`, the deploy wrapper, `daemon.json`, cron, systemd units |
   | Deploy wrapper used outside Kestra | any `homelab-deploy` call that is not Kestra's, or that was rejected (ADR 002) |
   | Unexpected reboot | node exporter boot time changed |
   | Sustained CPU > 90 %, unusual outbound traffic | crypto miner, data exfiltration (15-minute pending period) |

2. **Rules as code.** One provisioning file per rule in
   `services/grafana/provisioning/alerting/`, mounted read-only into Grafana. A change is a
   commit plus a Grafana restart. Each file starts with a comment on what it detects and why.

3. **Messages that need no second lookup.** Queries extract the interesting fields with
   `regexp` (user, source IP, command, killed process) and group by them, so the Telegram
   message names them. Every message ends with the command that shows the details on the host.

4. **Every rule is tested.** `docs/runbooks/alert-tests.md` lists a harmless trigger per
   rule, run after each change.

## Alternatives considered

- **Wazuh / a full SIEM:** ran here before and was retired: too heavy for a single mini PC,
  and most of its alerts were noise for a one-person setup.
- **Falco:** strong for container runtime detection, but needs a kernel driver or eBPF probe
  and privileged access, which conflicts with the hardening in ADR 001.
- **CrowdSec only:** stays for network-level attacks (bans at Traefik and the firewall); it
  does not see local events such as sudo, file changes or OOM kills.
- **Loki ruler instead of Grafana alerting:** would keep rules next to Loki, but Prometheus
  rules would live elsewhere, and Grafana's contact points and templates are already set up.

## Consequences

- Rules are read-only in the UI; experiments happen in the rule preview, real changes in Git.
- Grafana templates in provisioning files must avoid `$labels`/`$values` (environment
  variable interpolation) and can only read reduce/math expression values, not raw queries.
- Journal labels depend on Alloy's pipeline (`syslog_identifier`, `unit`, `host`); a change
  there can silently break rules -- the runbook catches that.
- Detection lags by up to ~30 seconds (journal shipping + 10-second evaluation).
