#!/usr/bin/env python3
"""Receive a Duplicati result report (send-http) and keep the state per backup job.

Called by the Kestra flow duplicati-report (webhook). Duplicati keeps its results in its own
database, not in the container log, so without this a failed upload (e.g. a OneDrive outage,
2026-11-13) was only visible in the web UI and in a mail.

Input:  env BODY = Kestra's trigger.body as JSON. Duplicati sends either a JSON document
        (send-http-json-urls / result format Json) or a form-encoded body with the report in
        the parameter "message" (JSON or plain text). All variants are accepted.
Output: /state/duplicati/<job>.json (read by scripts/maintenance/system-check.py on the host
        as /data/kestra-state/duplicati/), and message.txt in the working directory with the
        Telegram text -- empty when the run was a plain success.

State per job: last report (time, operation, result), last successful backup, and the
failures of the last 14 days. No log lines are stored: they can contain signed download
URLs of the backup target.
"""
import json
import os
import re
import sys
import urllib.parse
from datetime import datetime, timedelta, timezone

STATE_DIR = os.environ.get("DUPLICATI_STATE_DIR", "/state/duplicati")
KEEP_FAILURES_D = 14
NOW = datetime.now(timezone.utc)
URL_RE = re.compile(r"https?://\S+")


def from_text(s):
    """A string: JSON report, form body with "message", or plain text report."""
    s = (s or "").strip()
    if s.startswith("{"):
        try:
            return from_obj(json.loads(s))
        except json.JSONDecodeError:
            pass
    if s and "=" in s and "\n" not in s:
        form = urllib.parse.parse_qs(s)
        if "message" in form:
            return from_text(form["message"][0])
    return None, s


def from_obj(body):
    """A dict: the JSON report itself, or a form body Kestra already parsed."""
    if isinstance(body, dict):
        msg = body.get("message")
        if isinstance(msg, list):
            msg = msg[0] if msg else ""
        if isinstance(msg, str) and "Data" not in body and "Extra" not in body:
            return from_text(msg)
        return body, ""
    if isinstance(body, str):
        return from_text(body)
    return None, ""


def parse_body(raw):
    """Return (dict or None, text) from Kestra's trigger.body serialised as JSON."""
    try:
        return from_obj(json.loads(raw)) if raw else (None, "")
    except json.JSONDecodeError:
        return from_text(raw)


def find_key(obj, *names):
    """First value of any of the keys (case-insensitive), searched depth-first."""
    wanted = {n.lower() for n in names}
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k.lower() in wanted and not isinstance(v, (dict, list)):
                return v
        for v in obj.values():
            r = find_key(v, *names)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = find_key(v, *names)
            if r is not None:
                return r
    return None


def messages(obj, limit=3):
    """A few error/warning texts from the report, URLs removed."""
    out = []

    def walk(o, key=""):
        if len(out) >= limit:
            return
        if isinstance(o, dict):
            for k, v in o.items():
                walk(v, k.lower())
        elif isinstance(o, list):
            for v in o:
                walk(v, key)
        elif isinstance(o, str) and any(w in key for w in ("error", "warning", "exception", "loglines", "message")):
            if re.search(r"error|warn|fail|exception|unauthori", o, re.I):
                out.append(URL_RE.sub("<url>", o).strip()[:300])
    walk(obj)
    return out


def text_field(text, name):
    m = re.search(rf"^\s*{name}\s*[:=]\s*(\S+)", text, re.I | re.M)
    return m.group(1) if m else None


def main():
    data, text = parse_body(os.environ.get("BODY", ""))
    if data is not None:
        result = find_key(data, "ParsedResult", "PARSEDRESULT")
        name = find_key(data, "backup-name", "BackupName")
        operation = find_key(data, "OperationName", "MainOperation", "OPERATIONNAME")
        details = messages(data)
    else:
        result = text_field(text, "ParsedResult") or text_field(text, "Result")
        name = text_field(text, "backup-name")
        operation = text_field(text, "OperationName") or text_field(text, "MainOperation")
        details = [URL_RE.sub("<url>", l).strip()[:300] for l in text.splitlines()
                   if re.search(r"error|fail|exception|unauthori", l, re.I)][:3]

    result = str(result or "Unknown")
    name = str(name or "unbekannt")
    operation = str(operation or "Backup")
    ok = result.lower() == "success"

    os.makedirs(STATE_DIR, exist_ok=True)
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("_") or "unbekannt"
    path = os.path.join(STATE_DIR, f"{slug}.json")
    try:
        state = json.load(open(path, encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        state = {}
    now = NOW.isoformat(timespec="seconds")
    state.update({"name": name, "last_report": now, "last_operation": operation, "last_result": result})
    if ok and operation.lower() == "backup":
        state["last_success"] = now
    failures = [f for f in state.get("failures", [])
                if datetime.fromisoformat(f["time"]) > NOW - timedelta(days=KEEP_FAILURES_D)]
    if not ok:
        failures.append({"time": now, "operation": operation, "result": result,
                         "details": details[:1]})
    state["failures"] = failures
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, path)

    msg = ""
    if not ok:
        icon = "⚠️" if result.lower() == "warning" else "❌"
        msg = f"{icon} Duplicati: {name} -- {operation} {result}"
        if details:
            msg += "\n\n" + "\n".join(f"- {d}" for d in details)
        if data is None and not text:
            msg += "\n(leerer Bericht -- send-http-Einstellungen in Duplicati prüfen)"
    open("message.txt", "w", encoding="utf-8").write(msg)
    print(f"{name}: {operation} {result}" + ("" if ok else f", {len(failures)} Fehlschläge in {KEEP_FAILURES_D} Tagen"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
