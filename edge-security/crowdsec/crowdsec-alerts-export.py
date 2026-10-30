#!/usr/bin/env python3
"""cscli alerts -> compact rows for public.crowdsec_alerts (#127).

Input (stdin): "cscli alerts list --since <d> -l 0 -o json". Output: a JSON list with
the columns of crowdsec_alerts (written to argv[1]), a one-line summary on stdout.

Skipped: alerts that are not about one IP (range/ASN decisions from the blocklist
import) and manual decisions (cscli, cscli-import) -- only what CrowdSec detected.
started_at is truncated to seconds, the same key as the Console CSV import.

Aufruf: homelab-deploy crowdsec-alerts (Kestra-Flow crowdsec-alerts-import, stündlich)
"""
import json
import re
import sys
from datetime import datetime, timezone

MANUAL_ORIGINS = {"cscli", "cscli-import"}


def started(value):
    # "2026-10-29T11:39:54.484263781Z" -> seconds precision, UTC
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)", value or "")
    if not m:
        return None
    return datetime.fromisoformat(m.group(1)).replace(tzinfo=timezone.utc).isoformat()


def target_uris(alert):
    for m in alert.get("meta") or []:
        if m.get("key") == "target_uri":
            try:
                uris = json.loads(m.get("value") or "[]")
                return [str(u) for u in uris][:20] if isinstance(uris, list) else [str(uris)]
            except json.JSONDecodeError:
                return [m["value"]]
    return None


def main():
    alerts = json.load(sys.stdin) or []
    rows, skipped = [], 0
    for a in alerts:
        src = a.get("source") or {}
        decisions = a.get("decisions") or []
        if (src.get("scope") or "").lower() != "ip" \
                or any(d.get("origin") in MANUAL_ORIGINS for d in decisions):
            skipped += 1
            continue
        ts = started(a.get("start_at"))
        ip = src.get("ip") or src.get("value")
        if not ts or not ip or not a.get("scenario"):
            skipped += 1
            continue
        asn = str(src.get("as_number") or "").strip()
        rows.append({
            "started_at": ts,
            "scenario": a["scenario"],
            "source_ip": ip,
            "as_number": int(asn) if asn.isdigit() else None,
            "as_name": src.get("as_name") or None,
            "country": src.get("cn") or None,
            "decisions": len(decisions),
            "target_uris": target_uris(a),
            "origin": "cscli",
        })
    with open(sys.argv[1], "w") as f:
        json.dump(rows, f)
    print(f"{len(rows)} Alarme exportiert, {skipped} übersprungen (manuell/Range)")


main()
