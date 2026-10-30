#!/usr/bin/env python3
"""Expiry notices for the ASN blocklist (#127, ADR 005), run nightly after the sync.

Reads config/crowdsec/asn-blocklist.txt (working directory: repo root):
- expires within 7 days -> Telegram with the buttons "Verlängern (+180 Tage)" /
  "Auslaufen lassen" (handled by crowdsec-asn-decision, callback asn:r|x:<ASN>)
- expired in the last 30 days -> info: lifted, observed again
Each notice is sent once per ASN and expiry date (public.asn_expiry_notices), so a
failed night only delays it.

Environment: see supabase_api.py, plus BOT_TOKEN, CHAT_ID.
"""
import json
import os
import re
import urllib.request
from datetime import date, timedelta

from supabase_api import request

BLOCKLIST = "config/crowdsec/asn-blocklist.txt"


def entries():
    for raw in open(BLOCKLIST):
        line, _, comment = raw.partition("#")
        m = re.fullmatch(r"AS(\d{1,10})", line.strip(), re.I)
        u = re.search(r"\|\s*until\s+(\d{4}-\d\d-\d\d)\s*$", comment)
        if m and u:
            name = comment.split("--", 1)[0].strip() or "?"
            yield int(m.group(1)), name, date.fromisoformat(u.group(1))


def send(text, buttons=None):
    payload = {"chat_id": os.environ["CHAT_ID"], "text": text}
    if buttons:
        payload["reply_markup"] = {"inline_keyboard": [buttons]}
    req = urllib.request.Request(f"https://api.telegram.org/bot{os.environ['BOT_TOKEN']}/sendMessage",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        if json.load(resp).get("ok") is not True:
            raise SystemExit("Telegram: ok != true")


def main():
    today = date.today()
    sent = {(r["asn"], r["until"], r["kind"])
            for r in request("GET", "asn_expiry_notices?select=asn,until,kind") or []}
    count = 0
    for asn, name, until in entries():
        if today <= until <= today + timedelta(days=7):
            kind = "reminder"
            text = (f"⏳ ASN-Sperre läuft ab: AS{asn} {name}\n"
                    f"gesperrt bis {until:%d.%m.%Y}.\n\n"
                    f"Verlängern = bis {max(until, today) + timedelta(days=180):%d.%m.%Y}.\n"
                    f"Auslaufen lassen = danach wieder beobachten, bei weiteren Scans neuer Vorschlag.")
            buttons = [{"text": "🔁 Verlängern (+180 Tage)", "callback_data": f"asn:r:{asn}"},
                       {"text": "⏹ Auslaufen lassen", "callback_data": f"asn:x:{asn}"}]
        elif today - timedelta(days=30) <= until < today:
            kind = "expired"
            text = (f"🔓 ASN-Sperre abgelaufen: AS{asn} {name} (bis {until:%d.%m.%Y}).\n"
                    f"Das Netz wird wieder beobachtet; die Zeile bleibt als Historie in der Sperrliste.")
            buttons = None
        else:
            continue
        if (asn, until.isoformat(), kind) in sent:
            continue
        send(text, buttons)
        request("POST", "asn_expiry_notices",
                [{"asn": asn, "until": until.isoformat(), "kind": kind}], prefer="return=minimal")
        print(f"{kind}: AS{asn} (bis {until})")
        count += 1
    print(f"{count} Ablauf-Hinweis(e) gesendet")


main()
