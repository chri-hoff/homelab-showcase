#!/usr/bin/env python3
"""CrowdSec alerts and ASN lists -> Supabase (#127).

- stdin: JSON list from scripts/security/crowdsec-alerts-export.py; inserted into
  public.crowdsec_alerts, duplicates (same start second, IP, scenario) are ignored.
- public.asn_list mirrors config/crowdsec/asn-blocklist.txt and asn-allowlist.txt
  (ASN lines only, blocklist entries only while active, see "| until"); everything
  else is removed, so an expired network is observed and suggested again.
- Rows older than 12 months are deleted (the only rows kestra_sync may delete).

Working directory: repo root. Environment: see supabase_api.py.
Prints a Kestra outputs line "summary" on success.
"""
import json
import re
import sys
from datetime import date, datetime, timedelta, timezone

from supabase_api import request

LISTS = {"block": "config/crowdsec/asn-blocklist.txt", "allow": "config/crowdsec/asn-allowlist.txt"}


def read_asns(path, kind):
    entries = {}
    for raw in open(path):
        line, _, note = raw.partition("#")
        if m := re.fullmatch(r"AS(\d{1,10})", line.strip(), re.I):
            u = re.search(r"\|\s*until\s+(\d{4}-\d\d-\d\d)\s*$", note)
            until = u.group(1) if u else None
            if kind == "block" and until and date.fromisoformat(until) < date.today():
                continue
            entries[int(m.group(1))] = {"asn": int(m.group(1)), "list": kind,
                                        "note": note.strip() or None, "until": until}
    return entries


def main():
    rows = json.load(sys.stdin) or []
    if rows:
        request("POST", "crowdsec_alerts?on_conflict=started_at,source_ip,scenario", rows,
                prefer="resolution=ignore-duplicates,return=minimal")

    cutoff = (datetime.now(timezone.utc) - timedelta(days=366)).strftime("%Y-%m-%dT%H:%M:%SZ")
    request("DELETE", f"crowdsec_alerts?started_at=lt.{cutoff}", prefer="return=minimal")

    entries = {}
    for kind, path in LISTS.items():
        for asn, e in read_asns(path, kind).items():
            if asn in entries:
                sys.exit(f"FEHLER: AS{asn} steht auf Block- und Allowlist")
            entries[asn] = e
    now = datetime.now(timezone.utc).isoformat()
    body = [dict(e, updated_at=now) for e in entries.values()]
    if body:
        request("POST", "asn_list?on_conflict=asn", body, prefer="resolution=merge-duplicates,return=minimal")
    keep = ",".join(str(a) for a in entries) or "0"
    request("DELETE", f"asn_list?asn=not.in.({keep})", prefer="return=minimal")

    summary = (f"{len(rows)} Alarme übertragen (doppelte ignoriert), "
               f"asn_list: {sum(e['list'] == 'block' for e in body)} block / "
               f"{sum(e['list'] == 'allow' for e in body)} allow")
    print(summary)
    print("::" + json.dumps({"outputs": {"summary": summary}}) + "::")


main()
