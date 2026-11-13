# ADR 007: Weekly system checks, reviewed by Claude, tracked as Gitea issues and Mindwtr tasks

- **Status:** accepted
- **Date:** 2026-11-12
- **Issue:** #170 (extends it; related: ADR 002, ADR 003, ADR 006)

## Context

Checks exist, but in pieces: Grafana alert rules for live events (ADR 003), the weekly Trivy
scan and the daily update check post to Telegram, and real problems are found by hand and
written up in `docs/system-checks/`. Two recent examples show the gap:

- **Kestra outage 2026-11-11:** the nightly backup restarted all containers unordered, Kestra
  hung for 3.5 hours. Nobody was told; it was noticed in the morning.
- **Backup logs missing in Loki 2026-10-27 to 2026-11-12:** a config section was commented out
  by accident. It went unnoticed for 16 days.

Telegram messages scroll away, nothing tracks whether a finding was fixed, and the same finding
is reported again and again. #170 planned deterministic checks that open Gitea issues through a
bot user. This ADR adds the review step and the task list.

## Decision

### 1. Weekly run, deterministic checks

A Kestra flow `system-checks` runs **weekly on Friday at 06:30**, after the night's backups
(01:00-03:15), so their results are already in the logs. (Decided daily at first, changed to
weekly on 2026-11-12, see Alternatives.) It calls a new read-only `homelab-deploy` action
`system-check` on the host (root, ADR 002), which runs the check scripts and prints one JSON
document. **The scripts decide what is a finding**, against fixed thresholds and baselines; Claude
never suppresses or invents one.

Each finding: `{check, fingerprint, severity, title, details}`. The fingerprint is stable for the
same problem (e.g. `container-unhealthy:kestra`, `cert-expiry:<host>`), it is the key for
deduplication.

First stage of checks:

| Area | Check | Finding when |
|---|---|---|
| Containers & backups | container state | `unhealthy`, restart loop, `exited` (except the one-shot `*-vault-agent` with exit 0) |
| | backup runs | no successful run ("Skript beendet") within 26 h, or any `ERROR` in the last 8 days – read from the log files on the host, so the check does not depend on Loki |
| | Duplicati (off-site) | no successful run within 26 h, or failures in the last 8 days, or no reports at all – from the state the Kestra flow `duplicati-report` keeps for each send-http report (added 2026-11-13 after a OneDrive outage only showed up in a mail) |
| | disks | usage from 85 % (critical from 95 %), data disk not mounted |
| Security | Trivy | fixable **CRITICAL** in a running image, as **one** finding listing all images (from the state file of the weekly `trivy-scan`; HIGH stays in its Telegram report) |
| | Lynis | warnings (not suggestions) **not** in `config/system-checks/lynis-baseline.txt` |
| | ports | non-local listening ports not in `config/system-checks/expected-ports.txt` (UDP in the ephemeral range ignored: client sockets) |
| | expiry dates | entries in `config/system-checks/expiries.tsv` (e.g. GitHub mirror token), 21 days ahead |
| Certificates & updates | TLS | certificate in Traefik's `acme.json` expires in less than 21 days |
| | apt | security updates pending **and** unattended-upgrades has not run for 26 h; reboot pending > 3 days |
| | image updates | candidates in `inbox`/`next` older than 14 days, one finding |
| Config drift | host checkout | `/data/gitea/homelab` not on `main`, behind `origin/main`, or with local changes |
| | Ansible | `site.yml --check` on the host (`-c local`) reports changes; roles that need ansible-vault files (`storage`) are skipped, so the vault password never touches the host |
| | push mirror | last error set or no sync for 26 h |

### 2. Redaction before anything leaves the homelab

Only what goes to Claude is redacted, right before the call (`scripts/kestra/system-check-issues.py`):
domain names, internal IPs, user names, mail addresses, credentials in URLs, `key=value`
secrets, long token-like strings and digests become placeholders. Only the findings go out,
never raw logs. The Gitea issues keep the full details, because they stay inside the homelab.

### 3. Review and summary by Claude via n8n

Only when there are findings, Kestra posts them to an n8n workflow `system-check-review`, which
calls the Claude API (`POST /v1/messages`, as `changelog-summary` already does) with
**structured outputs** (`output_config.format`, a JSON schema), so the result is machine-readable:

```json
{
  "assessment": "kurze Bewertung auf Deutsch",
  "findings": [{ "fingerprint": "...", "issue_title": "...", "issue_body": "Markdown: Symptom, Befund, vermutete Ursache, nächste Schritte" }],
  "telegram_summary": "2-4 Zeilen"
}
```

Claude writes the texts and may propose a cause and next steps; the list of findings and their
severity stay as the scripts reported them. The prompt asks for German and says not to repeat
values that look like secrets.

**Model: Claude Haiku 5.5** (`claude-haiku-5-5`, $0.10 / $0.50 per MTok). Summarising a few
kilobytes of findings does not need a larger model; the cost per run stays below a cent. Effort
`low`, structured outputs as above. Haiku 5.5 has no server-side refusal fallback: a refusal
(`stop_reason: "refusal"`) is treated like any other failed call (template, see below).

**If n8n or Claude fail,** Kestra builds the issue text from a fixed template with the raw
(redacted) findings. A finding is never lost because the review step is down.

### 4. Gitea issue and Mindwtr task

Per finding, keyed by fingerprint:

| State | Gitea | Mindwtr |
|---|---|---|
| new | open an issue **in this repo** (`owner/homelab`) as bot user, labels `auto` + area (`security`, `backup`, `drift`, …), fingerprint as a hidden marker in the body | task in project **Homelab**, section **Issues**, title = issue title, link to the issue |
| still open | a reminder comment on each weekly run (at most every 6 days) | unchanged |
| gone | comment "seit <Datum> nicht mehr aufgetreten"; closing stays manual | task stays |
| closed by hand | – | task set to done on the next run (task ID kept as a hidden marker in the issue) |

Mindwtr tasks reuse the existing helper: `scripts/supabase/process-candidate.py` already finds
project and section by title (`GET /v1/sections?projectId=…`) for the update tasks (section
„Updates“); system-check tasks use the section „Issues“.

Issues land in this repo so a fix can close them with `Closes #`. The bot user is a
collaborator here, which in a user-owned Gitea repo always includes code write access; its
**token** is therefore limited to the scope `write:issue` (plus `read:repository`), so it cannot
push code even though the account could. The bot token and the Mindwtr token come from Vault
through Kestra's `secret()`, like all other flows.

### 5. Telegram

Two messages per run, as requested in #170: at the start ("System-Check läuft") and at the end
(counts new/open/reappeared/resolved, the Claude summary if available, one line per finding
with its issue number, closed tasks).
Telegram is a notification only; the issue is the record.

## Alternatives considered

- **Claude decides what is a finding** (all raw results to Claude): flexible, but not
  reproducible, costs on every run and risks noise or a missed finding. Rejected.
- **Raw results to Claude without redaction:** better analysis, but host names, IPs and paths
  leave the homelab, and a log line may carry a secret. Rejected.
- **Local model instead of Claude:** nothing leaves the host, but the ThinkCentre has no room for
  a useful model next to 36 containers. Rejected for now.
- **Everything as Grafana alert rules:** right for live events (ADR 003 stays), wrong for audits
  like Lynis, drift or certificate dates, and alerts have no task tracking.
- **Daily instead of weekly:** faster detection, but more runs to read and more noise while the
  baselines settle. Chosen: **weekly**, because urgent failures already have their own live
  alerts (Grafana rules, Uptime Kuma container monitors, Telegram/mail from the backup scripts,
  the sealed-Vault alarm); the system check is the weekly audit on top. The backup check looks
  back 8 days, so a failure early in the week is still reported.

## Consequences

- Redacted findings go to Anthropic once per week, only when there are findings. Cost per run with findings
  (estimate: ~6k input, ~1.5k output tokens) with Claude Haiku 5.5: about $0.002, well under a
  dollar a month. Weeks without findings make no API call.
- Each check needs a baseline before it is switched on (Lynis, ports), or it opens the same
  issues every day. Checks start in a dry-run mode that only reports to Telegram.
- New moving parts: a `homelab-deploy` action, a Kestra flow, an n8n workflow, a bot user, and
  Ansible installed on the host for the weekly drift check (role `base`). The
  fallback template keeps the chain working when n8n or the API is down.
- The issue list becomes the to-do list for the homelab; it needs a short weekly look.

## Decided on 2026-11-12

- Weekly on Friday morning (changed from daily the same day); model Claude Haiku 5.5; issues in this repo; weekly Ansible drift check (Friday) without the vault
  roles; resolved findings get a comment, closing stays manual.

## Deliberately not implemented

- **SMART warnings in the check:** smartd already sends them to Telegram the moment they appear
  (role `backup`, `smartd-telegram.sh`); a weekly copy would only be later.
- **Rising restart count:** a container in a restart loop is caught; a slowly rising count
  would need state between runs for little gain – Uptime Kuma's container monitors cover it.
- **Expiring AppRole `secret_id`s:** all AppRoles use `secret_id_ttl=0` (no expiry). If one gets a
  TTL, its date goes into `config/system-checks/expiries.tsv`.
- **Links in Telegram:** issue numbers instead of links keep the message short; Gitea finds them.

## Implementation status

**Stage 1 (2026-11-12, without Claude):** `scripts/maintenance/system-check.py` (containers,
backup logs, certificates from Traefik's `acme.json`, disk usage and mounts, host checkout),
`homelab-deploy system-check`, `scripts/kestra/system-check-issues.py` (issues, reminders,
resolved comments, Mindwtr task), Kestra flow `system-checks` starting with `DRY_RUN: "true"`.
Backup runs are read from the log files on the host instead of Loki, so the check does not
depend on Loki.

**Stage 2a (2026-11-12):** Trivy (only fixable CRITICAL becomes an issue, from the state file
the weekly scan now writes; HIGH stays in the weekly report), Lynis warnings minus
`config/system-checks/lynis-baseline.txt`, listening ports against
`config/system-checks/expected-ports.txt` (UDP ports in the ephemeral range are ignored:
client sockets), expiry dates from `config/system-checks/expiries.tsv`, apt (security updates
only when unattended-upgrades has not run for 26 h; reboot pending > 3 days), Ansible drift
(`ansible/drift-check.yml` = site.yml without `storage`, check mode on the host), push mirror
(in the Kestra script with Kestra's Gitea token). Lynis and Ansible are installed by the role
`base`.

**Stage 2b (2026-11-12):** update candidates in `inbox`/`next` older than 14 days (Supabase,
one finding), redaction and the n8n workflow `system-check-review` (Claude Haiku 5.5,
structured output, effort `low`, API version `2026-10-21`). The issue gets Claude's text plus
the raw details; on any failure (n8n, API, refusal, invalid JSON) the template is used. Claude's
answer is filtered to the fingerprints that were sent. `changelog-summary` moved to
`claude-haiku-5-5` at the same time (reads the text block, Haiku 5.5 starts with a thinking block).

**Live since 2026-11-12** (`DRY_RUN: "false"`): tested with a stopped container and an unexpected
port (issue, Mindwtr task, Claude text, "resolved" comment, all by `kestra-bot`). Afterwards:
own comments are recognised by a hidden marker instead of the author, and closing an issue sets
its Mindwtr task to done on the next run (for issues created from then on).

