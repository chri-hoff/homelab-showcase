#!/usr/bin/env python3
"""Turn the findings of the weekly system check into Gitea issues and Mindwtr tasks (ADR 007).

Input: env FINDINGS = JSON document from scripts/maintenance/system-check.py.
Output: summary.txt (Telegram text) in the working directory; log lines on stdout.

Per finding, keyed by its fingerprint (hidden marker <!-- fp:... --> in the issue body):
  new            -> issue (labels auto + area) as GITEA_BOT_USER, Mindwtr task in
                    MINDWTR_PROJECT / MINDWTR_SECTION with a link to the issue
  still open     -> a reminder comment at most every REMIND_DAYS days (default 6)
  reappeared     -> comment right away (last bot comment was "resolved")
  gone           -> one comment "nicht mehr aufgetreten"; closing stays manual
  issue closed   -> its Mindwtr task is set to done (task ID kept as <!-- mindwtr:ID --> in the
                    issue body; issues closed in the last CLOSED_LOOKBACK_D days are checked)
Check errors of system-check.py become findings of their own (check "system-check").

DRY_RUN=true (default): only reads Gitea and reports what it would do -- no issue, no
comment, no Mindwtr task.

Review (ADR 007, stage 2b): if N8N_REVIEW_URL is set and there are findings, the findings
are REDACTED (domain, internal IPs, user names, mail addresses, long token-like strings) and
sent to the n8n workflow system-check-review, where Claude Haiku 5.5 writes an assessment,
one text per finding and the Telegram summary. Claude never adds or removes findings. The
issues keep the full, unredacted details below Claude's text (they stay inside the homelab).
If the review fails, the fixed template is used -- a finding is never lost.

Update candidates (stage 2b): with SUPABASE_* set, candidates in "inbox" (never released)
or "next" (released, not deployed) older than CANDIDATE_MAX_AGE_D days become one finding.

Environment: FINDINGS, GITEA_URL, GITEA_REPO, GITEA_TOKEN (bot token, write:issue),
GITEA_BOT_USER, MINDWTR_URL, MINDWTR_TOKEN, optional MINDWTR_PROJECT (Homelab),
MINDWTR_SECTION (Issues), DRY_RUN, REMIND_DAYS (6); optional N8N_REVIEW_URL +
N8N_WEBHOOK_SECRET (review), SUPABASE_URL + SUPABASE_ANON_KEY + SUPABASE_JWT (candidates),
GITEA_MIRROR_TOKEN (push mirror), CANDIDATE_MAX_AGE_D (14).
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

DRY = os.environ.get("DRY_RUN", "true").lower() != "false"
# weekly run: 6 days, so the next Friday run is not missed by a few minutes
REMIND = timedelta(days=int(os.environ.get("REMIND_DAYS", "6")))
BOT = os.environ.get("GITEA_BOT_USER", "kestra-bot")
NOW = datetime.now(timezone.utc)
CANDIDATE_MAX_AGE = timedelta(days=int(os.environ.get("CANDIDATE_MAX_AGE_D", "14")))
# Fingerprints may contain spaces (Duplicati job "Vault Backup"): with (\S+) such an issue
# was never matched and every run opened a new one (#213 -> #222, 2026-11-18).
FP_RE = re.compile(r"<!-- fp:(.+?) -->")
TASK_RE = re.compile(r"<!-- mindwtr:(\S+) -->")
CLOSED_LOOKBACK = timedelta(days=int(os.environ.get("CLOSED_LOOKBACK_D", "8")))
RESOLVED = "<!-- resolved -->"
# Every comment of this script carries this marker; own comments are found by it, not by the
# author -- a token of the wrong account must not make the script comment again and again.
OWN = "<!-- syscheck -->"
AREA = {"container": "container", "backup": "backup", "cert": "updates", "disk": "host",
        "drift": "drift", "ansible": "drift", "mirror": "drift", "trivy": "security",
        "lynis": "security", "ports": "security", "expiry": "security", "apt": "updates",
        "candidates": "updates",
        "system-check": "auto"}
SEV_ICON = {"high": "🔴", "medium": "🟠", "low": "🟡"}


def http(method, url, body=None, headers=None):
    req = urllib.request.Request(url, method=method, headers={"Content-Type": "application/json", **(headers or {})},
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]


def gitea(method, path, body=None):
    url = f"{os.environ['GITEA_URL'].rstrip('/')}/api/v1/repos/{os.environ['GITEA_REPO']}{path}"
    st, data = http(method, url, body, {"Authorization": "token " + os.environ["GITEA_TOKEN"]})
    if st >= 300:
        hint = " (privates Repo + ungültiger/fehlender Token ergibt 404)" if st == 404 else ""
        raise RuntimeError(f"Gitea {method} {path} -> {st}{hint}: {data}")
    return data


def mindwtr(method, path, body=None):
    st, data = http(method, os.environ["MINDWTR_URL"].rstrip("/") + path, body,
                    {"Authorization": "Bearer " + os.environ["MINDWTR_TOKEN"]})
    if st >= 300:
        raise RuntimeError(f"Mindwtr {method} {path} -> {st}: {data}")
    return data


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def open_auto_issues():
    issues, page = [], 1
    while True:
        batch = gitea("GET", f"/issues?state=open&type=issues&labels=auto&limit=50&page={page}")
        issues += batch
        if len(batch) < 50:
            return issues
        page += 1


def recently_closed_auto_issues():
    since = (NOW - CLOSED_LOOKBACK).strftime("%Y-%m-%dT%H:%M:%SZ")
    return gitea("GET", f"/issues?state=closed&type=issues&labels=auto&since={since}&limit=50")


def close_tasks_of_closed_issues():
    """Mindwtr task done when its issue was closed by hand. Returns the issue numbers."""
    closed = []
    for issue in recently_closed_auto_issues():
        m = TASK_RE.search(issue.get("body") or "")
        if not m:
            continue
        task = mindwtr("GET", f"/v1/tasks/{m.group(1)}").get("task", {})
        if task.get("status") in ("done", "archived"):
            continue
        if DRY:
            print(f"  würde Mindwtr-Aufgabe zu #{issue['number']} erledigen")
        else:
            mindwtr("PATCH", f"/v1/tasks/{m.group(1)}", {"status": "done"})
            print(f"  Mindwtr-Aufgabe zu #{issue['number']} erledigt (Issue geschlossen)")
        closed.append(issue["number"])
    return closed


def last_bot_comment(number):
    comments = [c for c in gitea("GET", f"/issues/{number}/comments")
                if OWN in (c.get("body") or "") or RESOLVED in (c.get("body") or "")
                or c["user"]["login"] == BOT]
    return comments[-1] if comments else None


def label_ids(names):
    labels = {l["name"]: l["id"] for l in gitea("GET", "/labels?limit=100")}
    return [labels[n] for n in names if n in labels]


def mindwtr_placement():
    proj = os.environ.get("MINDWTR_PROJECT", "Homelab").lower()
    sect = os.environ.get("MINDWTR_SECTION", "Issues").lower()
    pid = next((p["id"] for p in mindwtr("GET", "/v1/projects?limit=500").get("projects", [])
                if p.get("title", "").strip().lower() == proj), None)
    if not pid:
        print(f"  WARNUNG: Mindwtr-Projekt '{proj}' nicht gefunden -- Aufgabe ohne Projekt")
        return {}
    sid = next((s["id"] for s in mindwtr("GET", f"/v1/sections?projectId={urllib.parse.quote(pid)}&limit=500")
                .get("sections", []) if s.get("title", "").strip().lower() == sect), None)
    if not sid:
        print(f"  WARNUNG: Abschnitt '{sect}' nicht gefunden -- Aufgabe ohne Abschnitt")
    return {"projectId": pid, **({"sectionId": sid} if sid else {})}


def mirror_findings():
    """Push-mirror state (the bot token may not read it -- needs repo admin, so it uses
    GITEA_MIRROR_TOKEN, Kestra's existing Gitea token). Missing token -> no check."""
    tok = os.environ.get("GITEA_MIRROR_TOKEN", "").strip()
    if not tok:
        return []
    url = f"{os.environ['GITEA_URL'].rstrip('/')}/api/v1/repos/{os.environ['GITEA_REPO']}/push_mirrors"
    st, data = http("GET", url, headers={"Authorization": "token " + tok})
    if st != 200:
        return [{"check": "mirror", "fingerprint": "mirror:api", "severity": "low",
                 "title": "Status des Push-Mirrors nicht abrufbar", "details": f"HTTP {st}"}]
    out = []
    for m in data or []:
        name = re.sub(r"https://[^/@\s]+@", "https://", m.get("remote_address", "?"))
        err = re.sub(r"https://[^/@\s]+@", "https://", m.get("last_error") or "")
        last = m.get("last_update") or ""
        age_h = (NOW - ts(last)).total_seconds() / 3600 if last and not last.startswith("0001") else None
        if err:
            out.append({"check": "mirror", "fingerprint": f"mirror:error:{name}", "severity": "high",
                        "title": f"Push-Mirror {name} meldet einen Fehler", "details": err[:500]})
        elif age_h is None or age_h > 26:
            out.append({"check": "mirror", "fingerprint": f"mirror:stale:{name}", "severity": "medium",
                        "title": f"Push-Mirror {name} seit über 26 h nicht synchronisiert",
                        "details": f"letzte Synchronisierung: {last or 'nie'}"})
    return out


def candidate_findings():
    """Update candidates left lying around (inbox = never released, next = released but
    not deployed). waiting/someday are deliberate states and not counted."""
    if not os.environ.get("SUPABASE_URL"):
        return []
    cutoff = (NOW - CANDIDATE_MAX_AGE).strftime("%Y-%m-%dT%H:%M:%SZ")
    url = (os.environ["SUPABASE_URL"].rstrip("/") + "/rest/v1/update_candidates"
           f"?select=service,new_version,status,detected_at&status=in.(inbox,next)"
           f"&detected_at=lt.{cutoff}&order=detected_at")
    st, rows = http("GET", url, headers={"apikey": os.environ["SUPABASE_ANON_KEY"],
                                         "Authorization": "Bearer " + os.environ["SUPABASE_JWT"]})
    if st != 200:
        return [{"check": "candidates", "fingerprint": "candidates:api", "severity": "low",
                 "title": "Update-Kandidaten nicht abrufbar", "details": f"HTTP {st}: {str(rows)[:200]}"}]
    if not rows:
        return []
    lines = [f"{r['service']} {r['new_version']} ({r['status']}, seit {ts(r['detected_at']):%d.%m.%Y})" for r in rows]
    return [{"check": "candidates", "fingerprint": "candidates:stale", "severity": "low",
             "title": f"{len(rows)} Update-Kandidat(en) seit über {CANDIDATE_MAX_AGE.days} Tagen offen",
             "details": "\n".join(lines) + "\n\ninbox: in Mindwtr entscheiden (Nächstes / Irgendwann); "
                        "next: freigegeben, aber nicht ausgerollt -- update-release prüfen."}]


# Redaction before anything goes to Claude (ADR 007): the issues keep the raw details.
# Own domains and user names come from config/system-checks/redact.txt (not exported to the
# showcase): one entry per line, "domain <name>" or "user <name>", # starts a comment.
REDACT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                           "config", "system-checks", "redact.txt")


def private_patterns(path=REDACT_FILE):
    rules = []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        print(f"WARNUNG: {path} fehlt -- eigene Domains/Benutzer werden nicht ersetzt")
        return rules
    for line in lines:
        kind, _, value = line.split("#", 1)[0].strip().partition(" ")
        value = value.strip()
        if kind == "domain" and value:
            rules.append((re.compile(r"[\w.-]*" + re.escape(value), re.I), "<host>.example.com"))
        elif kind == "user" and value:
            rules.append((re.compile(r"\b" + re.escape(value) + r"\b", re.I), "<user>"))
    return rules


REDACT = [
    (re.compile(r"https?://[^/\s:@]+:[^/\s@]+@"), "https://<cred>@"),          # credentials in URLs
    *private_patterns(),
    (re.compile(r"\b[\w.-]+\.(?:lan|local)\b", re.I), "<host>.lan"),
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"), "<email>"),
    (re.compile(r"\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}(?:/\d+)?\b"), "<internal-ip>"),
    (re.compile(r"(?i)\b(token|secret|passw(?:or)?d|api[_-]?key|key)\b(\s*[:=]\s*)\S+"), r"\1\2<redacted>"),
    # long token-like strings; without "/" so file paths stay readable
    (re.compile(r"\b[A-Za-z0-9+_-]{32,}={0,2}\b"), "<redacted>"),
]
SHA_RE = re.compile(r"\b(?:sha256:)?[0-9a-f]{64}\b")


def redact(text):
    text = SHA_RE.sub("<digest>", text or "")
    for rx, repl in REDACT:
        text = rx.sub(repl, text)
    return text


def review(findings, day):
    """Claude's texts via n8n, or None (then the template is used)."""
    url = os.environ.get("N8N_REVIEW_URL", "").strip()
    if not url or not findings:
        return None
    payload = {"date": day, "findings": [
        {"fingerprint": f["fingerprint"], "check": f["check"], "severity": f["severity"],
         "title": redact(f["title"]), "details": redact(f["details"])[:3000]} for f in findings]}
    st, data = http("POST", url, payload, {"x-webhook-secret": os.environ.get("N8N_WEBHOOK_SECRET", "")})
    if st != 200 or not isinstance(data, dict) or not data.get("ok"):
        print(f"  WARNUNG: Auswertung durch Claude nicht verfügbar ({st}: {str(data)[:200]}) -- Vorlage")
        return None
    texts = {x.get("fingerprint"): x.get("issue_body", "") for x in data.get("findings", [])}
    print(f"  Auswertung durch Claude: {len(texts)} Text(e)")
    return {"assessment": data.get("assessment", ""), "texts": texts,
            "telegram": data.get("telegram_summary", "")}


def issue_body(f, day, ai_text=""):
    ai = (f"### Einschätzung (Claude, aus bereinigten Daten)\n\n{ai_text}\n\n### Rohdaten\n\n"
          if ai_text else "")
    return (f"**Befund** aus dem Systemcheck vom {day} – Schweregrad **{f['severity']}**\n\n"
            f"{f['title']}\n\n{ai}```\n{f['details'] or '-'}\n```\n\n"
            f"Prüfung: `{f['check']}` · Fingerprint: `{f['fingerprint']}`\n\n"
            "_Automatisch angelegt vom wöchentlichen Systemcheck (ADR 007). Wenn behoben, von Hand schließen._\n\n"
            f"<!-- fp:{f['fingerprint']} -->")


def main():
    if not os.environ.get("GITEA_TOKEN", "").strip():
        raise RuntimeError("Bot-Token leer -- Vault-Policy kestra-ro (services/kestra-gitea-bot) "
                           "und Kestra-Neustart prüfen")
    doc = json.loads(os.environ["FINDINGS"])
    day = ts(doc["generated"]).astimezone().strftime("%d.%m.%Y")
    findings = list(doc.get("findings", []))
    for e in doc.get("errors", []):
        name = e.split(":", 1)[0]
        findings.append({"check": "system-check", "fingerprint": f"system-check:error:{name}", "severity": "medium",
                         "title": f"Systemcheck '{name}' ist fehlgeschlagen", "details": e})
    findings += mirror_findings()
    findings += candidate_findings()
    current = {f["fingerprint"]: f for f in findings}
    rv = review(findings, day)

    existing = {}
    for i in open_auto_issues():
        m = FP_RE.search(i.get("body") or "")
        if m:
            existing[m.group(1)] = i

    new, still, back, gone, actions = [], [], [], [], []
    for fp, f in current.items():
        issue = existing.get(fp)
        if not issue:
            new.append(f)
            continue
        last = last_bot_comment(issue["number"])
        if last and RESOLVED in last["body"]:
            back.append((f, issue))
        else:
            still.append(f)
            since = ts(last["created_at"]) if last else ts(issue["created_at"])
            if NOW - since >= REMIND:
                actions.append(("comment", issue, f"Weiterhin vorhanden (Systemcheck {day}):\n\n```\n{f['details'] or '-'}\n```"))
    for f, issue in back:
        actions.append(("comment", issue, f"Wieder aufgetreten (Systemcheck {day}):\n\n```\n{f['details'] or '-'}\n```"))
    for fp, issue in existing.items():
        if fp not in current:
            last = last_bot_comment(issue["number"])
            if not (last and RESOLVED in last["body"]):
                gone.append(issue)
                actions.append(("comment", issue, f"Seit dem Systemcheck vom {day} nicht mehr aufgetreten. "
                                                  f"Bitte prüfen und von Hand schließen.\n\n{RESOLVED}"))

    print(f"{'TROCKENLAUF -- ' if DRY else ''}{len(findings)} Befund(e): neu {len(new)}, offen {len(still)}, "
          f"wieder {len(back)}, behoben {len(gone)}")
    created = []
    placement = None
    for f in new:
        title = f"[Systemcheck] {f['title']}"
        if DRY:
            print(f"  würde anlegen: {title}")
            continue
        ai_text = rv["texts"].get(f["fingerprint"], "") if rv else ""
        issue = gitea("POST", "/issues", {"title": title, "body": issue_body(f, day, ai_text),
                                          "labels": label_ids(["auto", AREA.get(f["check"], "auto")])})
        created.append((f, issue))
        print(f"  angelegt: #{issue['number']} {title}")
        try:
            if placement is None:
                placement = mindwtr_placement()
            task = mindwtr("POST", "/v1/tasks", {"title": f"{f['title']} (#{issue['number']})",
                                                 "props": {"status": "inbox", "tags": ["#issue"],
                                                           "description": f"Gitea-Issue: {issue['html_url']}", **placement}})
            # Remember the task in the issue, so closing the issue can close the task
            body = issue_body(f, day, ai_text) + f"\n<!-- mindwtr:{task['task']['id']} -->"
            gitea("PATCH", f"/issues/{issue['number']}", {"body": body})
        except RuntimeError as e:  # the issue is the record; a missing task is only reported
            print(f"  WARNUNG Mindwtr: {e}")
    tasks_done = []
    try:
        tasks_done = close_tasks_of_closed_issues()
    except RuntimeError as e:  # not worth failing the run: the next run tries again
        print(f"  WARNUNG Mindwtr-Abgleich: {e}")
    for kind, issue, text in actions:
        if DRY:
            print(f"  würde kommentieren: #{issue['number']} ({text.splitlines()[0][:60]})")
        else:
            gitea("POST", f"/issues/{issue['number']}/comments", {"body": text + "\n\n" + OWN})
            print(f"  kommentiert: #{issue['number']}")

    lines = [f"🩺 Systemcheck {day}{' (Trockenlauf)' if DRY else ''}: "
             + (f"{len(findings)} Befund(e)" if findings else "keine Befunde ✅")]
    if findings:
        lines.append(f"neu {len(new)} · offen {len(still)} · wieder {len(back)} · behoben {len(gone)}")
    if rv and rv.get("telegram"):
        lines.append("")
        lines.append(rv["telegram"].strip())
        lines.append("")
    for f in sorted(findings, key=lambda f: ["high", "medium", "low"].index(f["severity"])):
        num = next((f"#{i['number']} " for x, i in created if x is f), "")
        if not num and f["fingerprint"] in existing:
            num = f"#{existing[f['fingerprint']]['number']} "
        lines.append(f"{SEV_ICON.get(f['severity'], '•')} {num}{f['title']}")
    for issue in gone:
        lines.append(f"✅ behoben: #{issue['number']} {issue['title'].removeprefix('[Systemcheck] ')}")
    if tasks_done:
        lines.append("☑️ Mindwtr-Aufgaben erledigt (Issue geschlossen): " + ", ".join(f"#{n}" for n in tasks_done))
    open("summary.txt", "w").write("\n".join(lines))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        open("summary.txt", "w").write(f"🩺 Systemcheck: Auswertung fehlgeschlagen ({type(e).__name__}: {str(e)[:300]})")
        print(f"FEHLER: {e}", file=sys.stderr)
        sys.exit(1)
