#!/usr/bin/env python3
"""Handles a click on an ASN suggestion in Telegram (#127, ADR 005).

    ASN=<number> DECISION=y|n|r|x MESSAGE_ID=<telegram message> asn-decision.py

- Removes the buttons from the message (no second click).
- Suggestion (crowdsec-asn-candidates):
  n: records "rejected" in public.asn_decisions -> no suggestion for 90 days.
  y: adds the ASN with its evidence (from asn_overview) and "| until <today + 180 days>"
     to config/crowdsec/asn-blocklist.txt on main via the Gitea API (an expired line of
     the same ASN gets the new date instead) and records "approved". Refused if the ASN
     is on the allowlist or has no alerts in the last 30 days.
- Expiry reminder (asn-expiry-notify.py):
  r: extends the entry to <later of until/today> + 180 days.
  x: nothing changes, the ban ends at its date.
- y and r print the Kestra output apply=true, so the flow pulls the change onto the
  host and runs the sync right away.

Environment: SUPABASE_* (see supabase_api.py), GITEA_URL/GITEA_REPO/GITEA_TOKEN (see
commit-versions.py), BOT_TOKEN, CHAT_ID.
"""
import base64
import json
import os
import re
import sys
import urllib.request
from datetime import date, datetime, timedelta, timezone

from supabase_api import request

BLOCKLIST = "config/crowdsec/asn-blocklist.txt"
ALLOWLIST = "config/crowdsec/asn-allowlist.txt"
HOLD = timedelta(days=180)
UNTIL = re.compile(r"\|\s*until\s+(\d{4}-\d\d-\d\d)\s*$")


def telegram(method, payload):
    req = urllib.request.Request(f"https://api.telegram.org/bot{os.environ['BOT_TOKEN']}/{method}",
                                 data=json.dumps(dict(payload, chat_id=os.environ["CHAT_ID"])).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=30).close()
    except Exception as e:  # removing buttons of an old message may fail; not fatal
        print(f"Telegram {method}: {e}")


def gitea(method, path, body=None):
    url = f"{os.environ['GITEA_URL'].rstrip('/')}/api/v1/repos/{os.environ['GITEA_REPO']}/{path}"
    req = urllib.request.Request(url, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"token {os.environ['GITEA_TOKEN']}",
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def listed(content, asn):
    return any(re.match(rf"\s*AS{asn}\b", line, re.I) for line in content.splitlines())


def set_until(content, asn, new_until):
    """Content with the "until" date of the ASN's line replaced (or appended)."""
    out = []
    for line in content.splitlines(keepends=True):
        if re.match(rf"\s*AS{asn}\b", line, re.I):
            body = UNTIL.sub("", line.rstrip("\n")).rstrip()
            line = f"{body} | until {new_until.isoformat()}\n"
        out.append(line)
    return "".join(out)


def until_of(content, asn):
    for line in content.splitlines():
        if re.match(rf"\s*AS{asn}\b", line, re.I) and (u := UNTIL.search(line)):
            return date.fromisoformat(u.group(1))
    return None


def commit(current, content, message):
    result = gitea("PUT", f"contents/{BLOCKLIST}", {
        "branch": "main",
        "sha": current["sha"],
        "content": base64.b64encode(content.encode()).decode(),
        "message": message,
        "author": {"name": "Kestra Auto-Update", "email": "kestra-auto-update@homelab.local"},
        "committer": {"name": "Kestra Auto-Update", "email": "kestra-auto-update@homelab.local"},
    })
    return result["commit"]["sha"][:7]


def finish(text, apply=False):
    telegram("sendMessage", {"text": text})
    print(text)
    print("::" + json.dumps({"outputs": {"apply": "true" if apply else "false"}}) + "::")
    sys.exit(0)


def record(asn, decision, note):
    request("POST", "asn_decisions?on_conflict=asn",
            [{"asn": asn, "decision": decision, "note": note,
              "decided_at": datetime.now(timezone.utc).isoformat()}],
            prefer="resolution=merge-duplicates,return=minimal")


def main():
    asn_raw, decision = os.environ.get("ASN", ""), os.environ.get("DECISION", "")
    if not re.fullmatch(r"\d{1,10}", asn_raw) or decision not in ("y", "n", "r", "x"):
        sys.exit(f"FEHLER: ungültige Eingabe ASN={asn_raw!r} DECISION={decision!r}")
    asn = int(asn_raw)
    if re.fullmatch(r"\d+", os.environ.get("MESSAGE_ID", "")):
        telegram("editMessageReplyMarkup", {"message_id": int(os.environ["MESSAGE_ID"]),
                                            "reply_markup": {"inline_keyboard": []}})

    rows = request("GET", f"asn_overview?as_number=eq.{asn}&select=*") or []
    stats = rows[0] if rows else None
    name = re.sub(r"[#\s]+", " ", (stats or {}).get("as_name") or "?").strip()

    if decision == "n":
        record(asn, "rejected", name)
        finish(f"✋ AS{asn} {name}: nicht gesperrt. Kein erneuter Vorschlag in den nächsten 90 Tagen.")

    current = gitea("GET", f"contents/{BLOCKLIST}?ref=main")
    content = base64.b64decode(current["content"]).decode()
    today = date.today()

    if decision in ("r", "x"):
        until = until_of(content, asn)
        if until is None:
            finish(f"⚠️ AS{asn} steht nicht (mehr) mit Ablaufdatum auf der Sperrliste -- nichts geändert.")
        if decision == "x":
            finish(f"⏹ AS{asn}: Sperre läuft am {until:%d.%m.%Y} aus, danach wird das Netz wieder beobachtet.")
        new_until = max(until, today) + HOLD
        sha = commit(current, set_until(content, asn, new_until),
                     f"feat(crowdsec): AS{asn} Sperre verlängert bis {new_until} (Telegram, #127)")
        finish(f"🔁 AS{asn}: verlängert bis {new_until:%d.%m.%Y}, Commit {sha} auf main.", apply=True)

    allow = base64.b64decode(gitea("GET", f"contents/{ALLOWLIST}?ref=main")["content"]).decode()
    if listed(allow, asn):
        finish(f"⚠️ AS{asn} {name} steht auf der Allowlist -- nicht gesperrt.")
    if listed(content, asn):
        until = until_of(content, asn)
        if until and until >= today:
            record(asn, "approved", name)
            finish(f"AS{asn} {name} ist schon gesperrt (bis {until:%d.%m.%Y}) -- Sperre wird neu gesetzt …",
                   apply=True)
        # expired entry: same line, new date
        new_until = today + HOLD
        sha = commit(current, set_until(content, asn, new_until),
                     f"feat(crowdsec): AS{asn} ({name}) erneut gesperrt bis {new_until} (Telegram-Freigabe, #127)")
        record(asn, "approved", name)
        finish(f"✅ AS{asn} {name}: erneut freigegeben bis {new_until:%d.%m.%Y}, Commit {sha} auf main. "
               f"Sperre wird gesetzt …", apply=True)
    if not stats:
        finish(f"⚠️ AS{asn}: keine Alarme in den letzten 30 Tagen -- Vorschlag veraltet, nicht gesperrt.")

    first, last = (datetime.fromisoformat(stats[k].replace("Z", "+00:00")).date().isoformat()
                   for k in ("first_seen", "last_seen"))
    new_until = today + HOLD
    line = (f"AS{asn}".ljust(10) + f"# {name} -- {stats['alerts']} alerts from {stats['ips']} different IPs, "
            f"{first}..{last[5:]} (approved via Telegram {today.isoformat()}) | until {new_until.isoformat()}\n")
    new = content if content.endswith("\n") else content + "\n"
    sha = commit(current, new + line,
                 f"feat(crowdsec): AS{asn} ({name}) auf die ASN-Sperrliste (Telegram-Freigabe, #127)")
    record(asn, "approved", name)
    finish(f"✅ AS{asn} {name}: freigegeben bis {new_until:%d.%m.%Y}, Commit {sha} auf main. "
           f"Sperre wird gesetzt …", apply=True)


main()
