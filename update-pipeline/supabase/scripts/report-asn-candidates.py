#!/usr/bin/env python3
"""Weekly suggestion for the ASN blocklist (#127): reads public.asn_candidates
(networks with >= 3 different IPs in 30 days, on neither list, not decided on in the
last 90 days) and sends one Telegram message per network with the buttons
"Sperren" / "Nicht sperren". The click is handled by telegram-listener ->
crowdsec-asn-decision (scripts/supabase/asn-decision.py).

Environment: see supabase_api.py, plus BOT_TOKEN, CHAT_ID.
"""
import json
import os
import urllib.request
from datetime import datetime

from supabase_api import request


def day(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).strftime("%d.%m.")


def send(text, asn):
    keyboard = [[{"text": "🚫 Sperren", "callback_data": f"asn:y:{asn}"},
                 {"text": "✋ Nicht sperren", "callback_data": f"asn:n:{asn}"}]]
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{os.environ['BOT_TOKEN']}/sendMessage",
        data=json.dumps({"chat_id": os.environ["CHAT_ID"], "text": text,
                         "reply_markup": {"inline_keyboard": keyboard}}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        if json.load(resp).get("ok") is not True:
            raise SystemExit("Telegram: ok != true")


rows = request("GET", "asn_candidates?select=*") or []
for r in rows:
    scen = ", ".join(s.split("/")[-1] for s in (r["scenarios"] or [])[:3])
    text = (f"🔎 CrowdSec: auffälliges Netz\n\n"
            f"AS{r['as_number']} {r['as_name'] or '?'}\n"
            f"{r['ips']} IPs, {r['alerts']} Alarme an {r['days']} Tagen, "
            f"{day(r['first_seen'])}–{day(r['last_seen'])}\n({scen})\n\n"
            f"Sperren = Eintrag in der ASN-Sperrliste (nur Traefik), sofort aktiv.\n"
            f"Nicht sperren = 90 Tage kein Vorschlag mehr.")
    send(text, r["as_number"])
    print(f"Vorschlag gesendet: AS{r['as_number']} ({r['ips']} IPs)")
if not rows:
    print("Keine auffälligen Netze.")
