#!/usr/bin/env python3
"""Records found updates in the Supabase table public.update_candidates (Issue #72, phase 3).

Input (stdin): JSON lines from docker-update-check.sh (UPDATE_CHECK_JSON), each
    {"image": "grafana/grafana", "current": "13.2.4", "latest": "13.2.5"}

Image -> service mapping via public.services.image (docker.io/ and library/ are ignored
in the comparison). Since phase 4 every running image is in services
(record-inventory.py runs first); images without an entry are skipped with a
notice. Versions already set as target are skipped as well. Existing candidates
(image + new_version) stay unchanged -- a status someone set in Studio is never
overwritten.

Environment: see supabase_api.py.
"""

import json
import re
import sys

from supabase_api import request


def norm(image):
    for prefix in ("docker.io/", "library/"):
        if image.startswith(prefix):
            image = image[len(prefix):]
    return image


def ver(s):
    """Same numeric comparison as in docker-update-check.sh."""
    nums = re.findall(r"\d+", s)
    return [int(x) for x in nums] if nums else [0]


def main():
    updates = [json.loads(line) for line in sys.stdin if line.strip()]
    if not updates:
        print("Supabase update_candidates: keine Updates gemeldet.")
        return

    services = request("GET", "services?select=name,image,version") or []
    by_image = {norm(s["image"]): s for s in services}

    rows, notes = [], []
    for u in updates:
        svc = by_image.get(norm(u["image"]))
        if svc is None:
            # Check the DB allowlist up front: a rejected entry would otherwise discard
            # the whole bulk insert
            notes.append(f"{u['image']} {u['latest']}: kein Eintrag in services (record-inventory.py gelaufen?)")
            continue
        if ver(u["latest"]) <= ver(svc["version"]):
            notes.append(f"{svc['name']} {u['latest']}: Soll steht schon auf {svc['version']}")
            continue
        # image exactly as in services, otherwise the allowlist in the trigger rejects it
        rows.append({"service": svc["name"], "image": svc["image"], "new_version": u["latest"]})

    inserted = []
    if rows:
        inserted = request(
            "POST",
            "update_candidates?on_conflict=image,new_version&select=service,image,new_version",
            rows,
            prefer="resolution=ignore-duplicates,return=representation",
        ) or []

    print("Supabase update_candidates:")
    for r in inserted:
        print(f"  neu (inbox): {r['service'] or r['image']} {r['new_version']}")
    known = len(rows) - len(inserted)
    if known:
        print(f"  {known} schon vorhanden, unveraendert")
    for n in notes:
        print(f"  uebersprungen: {n}")


if __name__ == "__main__":
    main()
