#!/usr/bin/env python3
"""Generate config/versions.yaml from Supabase and commit it to main via the Gitea API (#100).

Replaces commit-versions.sh (git clone + push with an SSH deploy key): Kestra runs its
tasks in its own container now, which has python3 and network access but no git and no
SSH keys. A commit through the API triggers the same push webhook (update-on-merge).

    commit-versions.py            -> commit if the export differs from main
    commit-versions.py --check    -> only print whether it would commit

Environment: SUPABASE_* (see supabase_api.py) and
    GITEA_URL    e.g. http://gitea:3000
    GITEA_REPO   owner/repo, e.g. owner/homelab
    GITEA_TOKEN  access token with write access to that repository (from Vault)
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import urllib.request

PATH = "config/versions.yaml"
HERE = os.path.dirname(os.path.abspath(__file__))


def gitea(method, path, body=None):
    url = f"{os.environ['GITEA_URL'].rstrip('/')}/api/v1/repos/{os.environ['GITEA_REPO']}/{path}"
    req = urllib.request.Request(url, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"token {os.environ['GITEA_TOKEN']}",
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def main():
    check = "--check" in sys.argv[1:]
    current = gitea("GET", f"contents/{PATH}?ref=main")
    original = base64.b64decode(current["content"]).decode("utf-8")

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "versions.yaml")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(original)
        # export-versions.py renders the file and prints the changes (+/-/~ lines)
        report = subprocess.run([sys.executable, os.path.join(HERE, "export-versions.py"), path, "--write"],
                                check=True, capture_output=True, text=True).stdout
        with open(path, encoding="utf-8") as fh:
            exported = fh.read()

    print(report, end="")
    if exported == original:
        return
    if check:
        print("(--check: nicht committet)")
        return

    # sha = blob of the file on main we started from; if main changed it meanwhile,
    # Gitea rejects the update (409) instead of silently overwriting it.
    result = gitea("PUT", f"contents/{PATH}", {
        "branch": "main",
        "sha": current["sha"],
        "content": base64.b64encode(exported.encode("utf-8")).decode(),
        "message": "chore(versions): versions.yaml aus Supabase (Check-Lauf, #72)",
        "author": {"name": "Kestra Auto-Update", "email": "kestra-auto-update@homelab.local"},
        "committer": {"name": "Kestra Auto-Update", "email": "kestra-auto-update@homelab.local"},
    })
    print(f"versions.yaml auf main committet: {result['commit']['sha'][:7]}")


if __name__ == "__main__":
    main()
