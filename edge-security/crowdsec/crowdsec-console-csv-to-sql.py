#!/usr/bin/env python3
"""CrowdSec Console CSV export -> SQL inserts for public.crowdsec_alerts (#127).

The Console keeps 30 days of alerts, the local CrowdSec database fewer. This script
turns a Console export ("Alerts" -> export as CSV) into idempotent inserts, so the
history in Supabase can start before the nightly pull existed. Re-running it, or
importing an overlapping export, adds nothing twice (same key as the nightly pull:
start second, source IP, scenario).

The export only has the network name, not the AS number; the number is looked up per
IP in RIPEstat (current routing, which is close enough for a few weeks old alerts).
Manual decisions (kind CSCLI, e.g. tests) are skipped.

Aufruf (Host, Repo-Root, nach services/supabase/migrate.sh mit 008):
  python3 scripts/security/crowdsec-console-csv-to-sql.py export.csv > /tmp/alerts.sql
  docker exec -i supabase-db sh -c '. /vault-secrets/db.env; PGPASSWORD="$POSTGRES_PASSWORD" exec psql -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 -q' < /tmp/alerts.sql
"""
import csv
import ipaddress
import json
import sys
import time
import urllib.request
from datetime import datetime

RIPESTAT = "https://stat.ripe.net/data/network-info/data.json?resource={}"


def q(value):
    """SQL literal (or NULL)."""
    if value is None or value == "":
        return "null"
    return "'" + str(value).replace("'", "''") + "'"


def as_number(ip, cache={}):
    if ip not in cache:
        req = urllib.request.Request(RIPESTAT.format(ip), headers={"User-Agent": "homelab-crowdsec-import"})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    asns = json.load(r)["data"]["asns"]
                # Several origins (e.g. "15169, 43515"): the first is the main one
                cache[ip] = int(asns[0]) if asns else None
                break
            except Exception as e:
                err = e
                time.sleep(3 * (attempt + 1))
        else:
            sys.exit(f"FEHLER: RIPEstat für {ip}: {err}")
    return cache[ip]


def main():
    if len(sys.argv) != 2:
        sys.exit("Aufruf: crowdsec-console-csv-to-sql.py <export.csv>")
    rows, skipped = [], 0
    with open(sys.argv[1], newline="") as f:
        for r in csv.DictReader(f):
            if r["kind"] != "CROWDSEC" or r["sourceScope"].lower() != "ip":
                skipped += 1
                continue
            ip = str(ipaddress.ip_address(r["sourceIp"]))
            started = datetime.fromisoformat(r["startAt"].replace("Z", "+00:00")).replace(microsecond=0)
            try:
                uris = json.loads(r["context"] or "{}").get("target_uri") or []
            except json.JSONDecodeError:
                uris = []
            arr = "array[" + ",".join(q(u) for u in uris) + "]::text[]" if uris else "null"
            rows.append(
                f"({q(started.isoformat())}, {q(r['scenario'])}, {q(ip)}, {as_number(ip) or 'null'}, "
                f"{q(r['sourceAs'])}, {q(r['sourceCountry'])}, {int(r['nbDecisions'] or 0)}, "
                f"{q(r['behaviors'])}, {q(r['cves'])}, {arr}, 'console-csv')"
            )
    if not rows:
        sys.exit("FEHLER: keine Alarme in der Datei")
    print("begin;")
    print("insert into public.crowdsec_alerts")
    print("  (started_at, scenario, source_ip, as_number, as_name, country, decisions, behaviors, cves, target_uris, origin)")
    print("values")
    print(",\n".join(rows))
    print("on conflict (started_at, source_ip, scenario) do nothing;")
    print("commit;")
    print(f"-- {len(rows)} Alarme, {skipped} übersprungen (manuell/kein IP-Scope)", file=sys.stderr)


main()
