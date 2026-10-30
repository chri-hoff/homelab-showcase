#!/usr/bin/env python3
"""Prefixes for the CrowdSec ASN blocklist (#127, ADR 005).

Reads the block- and allowlist, fetches the prefixes every active blocklisted ASN
announces from RIPEstat, drops prefixes that overlap an allowlisted range and writes one
prefix per line (input for "cscli decisions import --format values"). Blocklist entries
need "| until YYYY-MM-DD"; from the day after that date they are skipped.

Usage: crowdsec-asn-prefixes.py <blocklist> <allowlist> <out-prefixes> <out-samples>
  out-samples: "<ASN> <IP>" per ASN, one address inside an imported prefix (for checks)

Exits non-zero -- and writes nothing -- if any lookup fails or a sanity check trips,
so the caller never replaces working bans with an incomplete set.
"""
import ipaddress
import json
import re
import sys
import time
import urllib.request
from datetime import date

RIPESTAT = "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS{}"
MAX_PREFIXES = 20000
# Shorter prefixes than this are never plausible for one hosting ASN
MIN_LEN = {4: 8, 6: 19}


def die(msg):
    print(f"FEHLER: {msg}")
    sys.exit(1)


def read_list(path):
    """[(asn, until or None)], [networks]"""
    asns, nets = [], []
    for n, raw in enumerate(open(path), 1):
        line, _, comment = raw.partition("#")
        line = line.strip()
        if not line:
            continue
        if m := re.fullmatch(r"AS(\d{1,10})", line, re.I):
            u = re.search(r"\|\s*until\s+(\d{4}-\d\d-\d\d)\s*$", comment)
            asns.append((int(m.group(1)), date.fromisoformat(u.group(1)) if u else None))
            continue
        try:
            nets.append(ipaddress.ip_network(line))
        except ValueError:
            die(f"{path}:{n}: weder AS<Nummer> noch CIDR: {line!r}")
    return asns, nets


def announced(asn):
    for attempt in range(3):
        try:
            req = urllib.request.Request(RIPESTAT.format(asn), headers={"User-Agent": "homelab-asn-blocklist"})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = json.load(r)
            return [p["prefix"] for p in data["data"]["prefixes"]]
        except Exception as e:  # network errors, bad JSON, missing keys
            err = e
            time.sleep(5 * (attempt + 1))
    die(f"RIPEstat-Abfrage für AS{asn} fehlgeschlagen: {err}")


def main():
    if len(sys.argv) != 5:
        die("Aufruf: crowdsec-asn-prefixes.py <blocklist> <allowlist> <out-prefixes> <out-samples>")
    block, block_nets = read_list(sys.argv[1])
    allow, allow_nets = read_list(sys.argv[2])
    if block_nets:
        die("die Blocklist enthält nur ASNs, keine CIDRs")
    if clash := sorted({a for a, _ in block} & {a for a, _ in allow}):
        die("ASN auf Block- UND Allowlist: " + ", ".join(f"AS{a}" for a in clash))

    block_asns = []
    for asn, until in block:
        if until is None:
            die(f"AS{asn}: kein Ablaufdatum -- Zeile braucht \"| until JJJJ-MM-TT\"")
        if until < date.today():
            print(f"    AS{asn}: abgelaufen am {until} -- nicht mehr gesperrt")
        else:
            block_asns.append(asn)

    result, samples = [], []
    for asn in block_asns:
        nets, dropped = [], 0
        for p in announced(asn):
            net = ipaddress.ip_network(p)
            if net.prefixlen < MIN_LEN[net.version]:
                die(f"AS{asn} kündigt unplausibel großes Netz an: {net}")
            if any(net.overlaps(a) for a in allow_nets if a.version == net.version):
                dropped += 1
                continue
            nets.append(net)
        if not nets:
            die(f"AS{asn}: keine Prefixe erhalten -- RIPEstat-Antwort leer?")
        v4 = list(ipaddress.collapse_addresses(n for n in nets if n.version == 4))
        v6 = list(ipaddress.collapse_addresses(n for n in nets if n.version == 6))
        print(f"    AS{asn}: {len(v4)} IPv4- und {len(v6)} IPv6-Prefixe"
              + (f", {dropped} wegen Allowlist ausgelassen" if dropped else ""))
        result += v4 + v6
        first = (v4 or v6)[0]
        samples.append(f"AS{asn} {first[1] if first.num_addresses > 1 else first[0]}")

    if len(result) > MAX_PREFIXES:
        die(f"{len(result)} Prefixe -- mehr als {MAX_PREFIXES}, Liste prüfen")
    with open(sys.argv[3], "w") as f:
        f.write("".join(f"{n}\n" for n in result))
    with open(sys.argv[4], "w") as f:
        f.write("".join(f"{s}\n" for s in samples))
    print(f"    gesamt: {len(result)} Prefixe")


main()
