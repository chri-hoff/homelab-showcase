#!/usr/bin/env python3
"""Maintains the Supabase table public.services from docker ps (Issue #72, phase 4).

Input (stdin): `docker ps --format json`. Working directory: repo root (for deployable).

One entry per stack + image. Stack = compose project (label com.docker.compose.project,
for sops-update = directory under services/).

- existing entry (same stack + image, or legacy entry from versions.yaml with
  name = stack and the same image): only update actual state -- running_tag,
  containers, checkable, deployable, last_seen. The target version (version) stays.
- new entry: name = stack if the stack has only one image (or the compose service
  is named like the stack) and the name is free, otherwise <stack>-<compose-service>
  (e.g. supabase-auth). version = running tag.
  updateable = false for PROTECTED (the pipeline itself depends on them). If a bundle
  with the stack's name exists (table bundles), the entry is assigned to it.
- not seen for 7 days -> deleted (candidates go with it via FK).

Ephemeral containers (former Kestra task runners, vault-agent sidecars, alpine, label
kestra.io/*) are ignored.
Environment: see supabase_api.py.
"""

import json
import os
import re
import sys
import urllib.parse
from datetime import date, datetime, timedelta, timezone

from supabase_api import request

# like version_pattern() in docker-update-check.sh: 2-3 parts or more (Collabora: 26.04.5.1.1)
CHECKABLE = re.compile(r"^v?\d+(\.\d+)+$")
EPHEMERAL_IMAGES = {"homelab-update-runner", "homelab-vault-agent", "alpine"}
# Never deploy automatically: Kestra/Vault/Traefik as before, plus the Supabase core
# without which the pipeline itself (inventory, candidates, export) stops working.
PROTECTED = {"kestra", "vault", "traefik", "supabase-db", "supabase-rest", "supabase-api-gw"}
REMOVE_AFTER = timedelta(days=7)


def split_image(ref):
    ref = ref.split("@")[0]
    if ":" in ref.split("/")[-1]:
        return tuple(ref.rsplit(":", 1))
    return ref, "latest"


def norm(image):
    for prefix in ("docker.io/", "library/"):
        if image.startswith(prefix):
            image = image[len(prefix):]
    return image


def label(labels, key):
    m = re.search(rf"(?:^|,){re.escape(key)}=([^,]*)", labels or "")
    return m.group(1) if m else None


def slug(s):
    return re.sub(r"[^a-z0-9-]+", "-", s.lower()).strip("-")


def deployable(name, stack):
    """Deployable via versions.yaml: entry is named like its directory, compose uses
    ${VERSION}, an encrypted env exists (sops-update needs it)."""
    if not stack or name != stack:
        return False
    compose = f"services/{stack}/docker-compose.yaml"
    if not os.path.isfile(compose) or not os.path.isfile(f"services/{stack}/{stack}.env.sops"):
        return False
    with open(compose, encoding="utf-8") as fh:
        return "${VERSION}" in fh.read()


def groups_from(lines):
    """(stack, image) -> {tag, containers, service}"""
    groups = {}
    for c in lines:
        image, tag = split_image(c["Image"])
        if image in EPHEMERAL_IMAGES or "kestra.io/" in (c.get("Labels") or ""):
            continue
        name = c["Names"].split(",")[0]
        stack = label(c.get("Labels"), "com.docker.compose.project")
        g = groups.setdefault((stack, image), {"tag": tag, "containers": [], "service": None})
        g["containers"].append(name)
        g["service"] = g["service"] or label(c.get("Labels"), "com.docker.compose.service") or name
    return groups


def main():
    started = datetime.now(timezone.utc)
    lines = [json.loads(line) for line in sys.stdin if line.strip()]
    if not lines:
        sys.exit("FEHLER: keine Container in der Eingabe (docker ps leer?)")
    groups = groups_from(lines)

    rows = request("GET", "services?select=name,image,stack,version,bundle") or []
    bundles = {b["name"] for b in request("GET", "bundles?select=name") or []}
    by_stack_image = {(r["stack"], norm(r["image"])): r for r in rows if r["stack"]}
    legacy = {r["name"]: r for r in rows if not r["stack"]}
    taken = {r["name"] for r in rows}
    images_per_stack = {}
    for stack, image in groups:
        images_per_stack.setdefault(stack, set()).add(image)

    seen = started.isoformat()
    update, create = [], []
    for (stack, image), g in sorted(groups.items(), key=lambda kv: (kv[0][0] or "", kv[0][1])):
        row = by_stack_image.get((stack, norm(image)))
        if row is None and stack in legacy and norm(legacy[stack]["image"]) == norm(image):
            row = legacy.pop(stack)  # take over legacy entry from versions.yaml
        ist = {
            "stack": stack,
            "containers": sorted(g["containers"]),
            "running_tag": g["tag"],
            "checkable": bool(CHECKABLE.match(g["tag"])),
            "last_seen": seen,
        }
        if row:
            u = {"name": row["name"], **ist, "deployable": deployable(row["name"], stack)}
            if row.get("bundle") and ist["checkable"] and row["version"] != g["tag"]:
                # Bundle: tags are pinned in the compose file (taken from the upstream
                # state), so the target follows the running state
                u["version"] = g["tag"]
            update.append(u)
            continue
        if stack and (len(images_per_stack[stack]) == 1 or g["service"] == stack) and stack not in taken:
            name = slug(stack)
        else:
            name = slug(f"{stack}-{g['service']}" if stack else g["containers"][0])
        taken.add(name)
        create.append({
            "name": name, **ist, "image": image, "version": g["tag"],
            "deployable": deployable(name, stack),
            "updateable": name not in PROTECTED, "breaking_changes": False,
            "bundle": stack if stack in bundles else None,
            "last_updated": date.today().isoformat(), "notes": "automatisch erkannt (Check-Lauf)",
        })

    # Existing entries: PATCH only the actual-state columns, the target version stays
    # untouched (except for bundles, see above). (An upsert with columns=... does not
    # work: Postgres checks NOT NULL of the INSERT part before the conflict.)
    for u in update:
        name = u.pop("name")
        request("PATCH", f"services?name=eq.{urllib.parse.quote(name)}", u, prefer="return=minimal")
        u["name"] = name
    if create:
        request("POST", "services", create, prefer="return=minimal")

    cutoff = (started - REMOVE_AFTER).isoformat()
    removed = request("DELETE", f"services?last_seen=lt.{urllib.parse.quote(cutoff)}&select=name",
                      prefer="return=representation") or []
    gone = request("GET", f"services?last_seen=lt.{urllib.parse.quote(seen)}&select=name,last_seen") or []
    drift = request("GET", "version_drift?select=service,soll,laeuft") or []

    total = sum(len(g["containers"]) for g in groups.values())
    print(f"Supabase services: {len(update) + len(create)} Eintraege aus {total} Containern")
    for r in create:
        print(f"  neu: {r['name']} ({r['image']}:{r['version']}"
              f"{', kein Auto-Deploy' if not r['updateable'] else ''})")
    for r in gone:
        print(f"  laeuft nicht mehr: {r['name']} (zuletzt {r['last_seen'][:10]}, wird nach 7 Tagen entfernt)")
    for r in removed:
        print(f"  entfernt (7 Tage nicht gesehen): {r['name']}")
    for d in drift:
        print(f"  Soll/Ist: {d['service']} soll {d['soll']}, laeuft {d['laeuft']}")


if __name__ == "__main__":
    main()
