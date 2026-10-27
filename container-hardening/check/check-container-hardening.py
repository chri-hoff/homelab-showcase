#!/usr/bin/env python3
"""Container hardening check over all services/*/docker-compose*.yaml (Issue #103).

Prints a matrix of hardening options per container and fails (exit 1) when a
required option is missing and not justified in container-hardening-exceptions.yaml.

Reads the compose files directly (PyYAML resolves anchors and `<<` merge keys),
so it runs on the dev laptop without Docker.

Run:  python3 scripts/security/check-container-hardening.py [--all | --markdown]
      --all       also list containers without gaps
      --markdown  full matrix + exceptions as Markdown (for the showcase MATRIX.md)
"""
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
EXCEPTIONS = Path(__file__).with_name("container-hardening-exceptions.yaml")

VERSIONS = ROOT / "config" / "versions.yaml"


def pinned(s, stack):
    """Image tag is a fixed version: no ':latest', no missing tag, no ':-latest'
    fallback, and a ${VERSION} tag resolves to a non-latest entry in versions.yaml."""
    image = str(s.get("image") or "")
    if not image or ":-latest" in image:
        return False
    tag = image.rsplit(":", 1)[1] if ":" in image.split("/")[-1] else "latest"
    if "${VERSION" in tag:
        entry = (VERSION_MAP.get(stack) or {}) if VERSION_MAP else {}
        return str(entry.get("version", "latest")) != "latest"
    return tag != "latest"


VERSION_MAP = ((yaml.safe_load(VERSIONS.read_text()) or {}).get("services") or {}) if VERSIONS.exists() else {}

# Required checks: name -> predicate(service dict, stack dir) -> bool
REQUIRED = {
    "no-new-privileges": lambda s, _: any("no-new-privileges" in str(o) and "false" not in str(o)
                                       for o in s.get("security_opt") or []),
    "cap_drop": lambda s, _: "ALL" in (s.get("cap_drop") or []),
    "pids_limit": lambda s, _: bool(s.get("pids_limit")),
    "mem_limit": lambda s, _: bool(s.get("mem_limit")),
    "healthcheck": lambda s, _: bool(s.get("healthcheck")) and not (s["healthcheck"].get("disable")),
    "not-privileged": lambda s, _: not s.get("privileged"),
    "pinned": pinned,
}

# Informational columns, not enforced
def info(s):
    socks = [str(v) for v in s.get("volumes") or [] if "docker.sock" in str(v)]
    return {
        "user": str(s.get("user") or "-"),
        "ro": "ja" if s.get("read_only") else "-",
        "cap_add": ",".join(s.get("cap_add") or []) or "-",
        "sock": ("ro" if all(v.endswith(":ro") for v in socks) else "rw") if socks else "-",
    }


def load_services():
    for f in sorted(ROOT.glob("services/*/docker-compose*.y*ml")):
        data = yaml.safe_load(f.read_text()) or {}
        for name, svc in (data.get("services") or {}).items():
            yield f"{f.parent.name}/{name}", svc or {}


def markdown(exceptions):
    """Full matrix (every container, untruncated) plus the exception list."""
    mark = {True: "✓", False: "✗"}
    cols = list(REQUIRED) + ["user", "read_only", "cap_add", "docker.sock"]
    print("| Container | " + " | ".join(cols) + " |")
    print("|---" * (len(cols) + 1) + "|")
    for key, svc in load_services():
        exc = exceptions.get(key) or {}
        stack = key.split("/")[0]
        cells = [mark[ok(svc, stack)] if ok(svc, stack) or check not in exc else "exception"
                 for check, ok in REQUIRED.items()]
        cells += [f"`{v}`" if v not in ("-", "ja") else ("yes" if v == "ja" else "–")
                  for v in info(svc).values()]
        print(f"| `{key}` | " + " | ".join(cells) + " |")
    print("\n## Exceptions\n")
    print("| Container | Check | Reason |")
    print("|---|---|---|")
    for key, checks in sorted(exceptions.items()):
        for check, reason in checks.items():
            print(f"| `{key}` | {check} | {reason} |")


def main():
    show_all = "--all" in sys.argv
    exceptions = yaml.safe_load(EXCEPTIONS.read_text()) or {} if EXCEPTIONS.exists() else {}
    if "--markdown" in sys.argv:
        markdown(exceptions)
        return
    seen = set()
    gaps = stale = 0

    cols = list(REQUIRED) + ["user", "ro", "cap_add", "sock"]
    print(f"{'Container':34}" + " ".join(f"{c[:10]:>10}" for c in cols))
    for key, svc in load_services():
        seen.add(key)
        exc = exceptions.get(key) or {}
        row, bad = [], False
        for check, ok in REQUIRED.items():
            passed = ok(svc, key.split("/")[0])
            if passed:
                row.append("ok")
                if check in exc:
                    print(f"  ! veraltete Ausnahme: {key} {check} (Check besteht inzwischen)")
                    stale += 1
            elif check in exc:
                row.append("ausn.")
            else:
                row.append("FEHLT")
                bad = True
                gaps += 1
        row += list(info(svc).values())
        if bad or show_all:
            print(f"{key[:34]:34}" + " ".join(f"{v[:10]:>10}" for v in row))

    for key in sorted(set(exceptions) - seen):
        print(f"  ! Ausnahme für unbekannten Container: {key}")
        stale += 1

    print(f"\n{len(seen)} Container, {gaps} unbegründete Lücken, {stale} veraltete Ausnahmen")
    sys.exit(1 if gaps or stale else 0)


if __name__ == "__main__":
    main()
