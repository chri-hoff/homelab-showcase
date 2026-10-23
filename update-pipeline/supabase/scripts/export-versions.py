#!/usr/bin/env python3
"""Export public.services -> config/versions.yaml (Issue #72, phase 4: Supabase is the source of truth).

Renders the services: block from Supabase. Everything outside that block (trailing comments,
app:) is carried over from the existing file because it does not exist in Supabase.

    export-versions.py FILE            -> new file on stdout
    export-versions.py FILE --write    -> overwrite FILE, print the changes
    export-versions.py FILE --check    -> compare only, print differences as a diff

Per entry: version (target), image, stack/bundle (if set), last_updated, updateable,
breaking_changes, notes. Actual state (running_tag, containers, last_seen) is deliberately
left out -- it changes on every run and would only produce noise commits.

Environment: see supabase_api.py.
"""

import argparse
import difflib
import json
import re
import sys

from supabase_api import request

FIELDS = ("version", "image", "stack", "bundle", "last_updated", "updateable", "breaking_changes", "notes")
OPTIONAL = {"stack", "bundle"}
MARKER = "# AUTO-GENERATED from Supabase (public.services) -- do not edit by hand.\n" \
         "# Change versions in Supabase Studio; the next check run commits this file.\n"


def scalar(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    # JSON strings are valid double-quoted YAML strings
    return json.dumps(str(value), ensure_ascii=False)


def render(rows):
    blocks = []
    for row in rows:
        if row.get("bundle"):
            # Never let sops-auto-update deploy bundle members individually
            row = {**row, "updateable": False}
        lines = [f"  {row['name']}:"] + [
            f"    {f}: {scalar(row[f])}" for f in FIELDS if not (f in OPTIONAL and row[f] is None)]
        blocks.append("\n".join(lines) + "\n")
    return "\n".join(blocks)


def split_template(text):
    """(head incl. 'services:', foot from the first line after the last field) of the template."""
    lines = text.splitlines(keepends=True)
    start = next(i for i, line in enumerate(lines) if line.rstrip() == "services:")
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i][:1] not in ("", " ", "\n", "#"):
            end = i  # next top-level key
            break
    last_field = max(i for i in range(start + 1, end) if lines[i].startswith("    ") and lines[i].strip())
    head = "".join(lines[: start + 1])
    if MARKER not in head:
        head = MARKER + "\n" + head
    return head, "".join(lines[last_field + 1:])


def versions(text):
    """{name: version} from the services: block -- enough for the change overview."""
    out, current, in_services = {}, None, False
    for line in text.splitlines():
        if line.rstrip() == "services:":
            in_services = True
        elif in_services and line[:1] not in ("", " ", "#"):
            break
        elif in_services and (m := re.match(r"^  ([a-z0-9][a-z0-9-]*):\s*$", line)):
            current = m.group(1)
            out[current] = None
        elif in_services and current and (m := re.match(r'^    version:\s*"?([^"]*)"?\s*$', line)):
            out[current] = m.group(1)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    args = ap.parse_args()

    with open(args.file, encoding="utf-8") as fh:
        original = fh.read()
    head, foot = split_template(original)

    # Sort in Python instead of via DB collation: alphabetical as before
    rows = sorted(request("GET", "services?select=name," + ",".join(FIELDS)) or [], key=lambda r: r["name"])
    exported = head + render(rows) + foot

    if not (args.check or args.write):
        sys.stdout.write(exported)
        return
    if exported == original:
        print(f"versions.yaml unveraendert ({len(rows)} Eintraege).")
        return

    if args.check:
        print("".join(difflib.unified_diff(original.splitlines(keepends=True), exported.splitlines(keepends=True),
                                           "versions.yaml", "export aus Supabase")))
        return

    with open(args.file, "w", encoding="utf-8") as fh:
        fh.write(exported)
    old, new = versions(original), versions(exported)
    print(f"versions.yaml neu geschrieben ({len(rows)} Eintraege):")
    for name in sorted(set(new) - set(old)):
        print(f"  + {name} {new[name]}")
    for name in sorted(set(old) - set(new)):
        print(f"  - {name} {old[name]}")
    for name in sorted(set(old) & set(new)):
        if old[name] != new[name]:
            print(f"  ~ {name} {old[name]} -> {new[name]}")


if __name__ == "__main__":
    main()
