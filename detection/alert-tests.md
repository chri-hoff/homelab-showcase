# Runbook: testing the security alerts

Every alert rule in `services/grafana/provisioning/alerting/` gets triggered once after a
change, so a broken query or template shows up immediately instead of during an incident.
All triggers are harmless. Expected result: a Telegram message within 1-2 minutes, and the
rule returns to *Normal* about 5 minutes later (15 minutes for the 15m rules).

| Rule | Trigger on the host | Expected message |
|---|---|---|
| SSH-Login | log in via SSH from the laptop | `SSH-Login: <user> von <ip>` |
| Sudo Anmeldung Fehlgeschlagen | `sudo -k; echo wrong \| sudo -S true` | `sudo-Fehlversuch von <user>` |
| Benutzer oder Gruppen geändert | `logger -t useradd test` (simulated entry) | `Konto/Gruppe geändert durch useradd` |
| AppArmor blockiert etwas | `logger -t kernel 'apparmor="DENIED" operation="test" profile="runbook" comm="test"'` (simulated entry) | `AppArmor DENIED: test (Profil runbook)` |
| Speicherabbrüche (OOM) | `docker run --rm --memory 16m alpine:3.24.3 sh -c 'tail /dev/zero'` (real cgroup OOM kill) | `OOM: Kernel hat tail beendet …` |
| Kritische Datei geändert | `sudo touch /etc/docker/daemon.json` | `Kritische Datei geändert durch touch (/usr/bin/touch)` |
| HomeLab Deploy | `sudo homelab-deploy ps >/dev/null` | `homelab-deploy ps von local:<user> …` |
| Unerwarteter Neustart | not triggered on purpose -- check on the next planned reboot | `Neustart von <instance>` |
| Dauerhaft hohe CPU-Last | rule preview in Grafana with threshold `0.01` (do not save) | -- |
| Ungewöhnlich viel ausgehender Traffic | rule preview with threshold `1000` (do not save) | -- |

Must **not** fire: a normal Kestra run (Telegram `/checkversion`, a deploy through
`update-on-merge`). Kestra's SSH logins as `deploy` from its fixed address and its
`homelab-deploy` calls are excluded on purpose.

Rules are provisioned from files and read-only in the UI. To change a threshold for real:
edit the file, push, `docker restart grafana` on the host.
