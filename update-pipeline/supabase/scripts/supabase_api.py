"""Shared PostgREST access for the Supabase scripts (Issue #72).

Environment:
    SUPABASE_URL       e.g. http://supabase-envoy:8000
    SUPABASE_ANON_KEY  for the apikey check in the Envoy gateway
    SUPABASE_JWT       JWT of the role kestra_sync (Authorization: Bearer)
"""

import json
import os
import sys
import urllib.error
import urllib.request


def request(method, path, body=None, prefer=None):
    """PostgREST call under /rest/v1/. Exits the script with a message on HTTP errors."""
    url = os.environ["SUPABASE_URL"].rstrip("/") + "/rest/v1/" + path
    headers = {
        "apikey": os.environ["SUPABASE_ANON_KEY"],
        "Authorization": "Bearer " + os.environ["SUPABASE_JWT"],
        "Content-Type": "application/json",
    }
    if prefer:
        headers["Prefer"] = prefer
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"FEHLER: {method} {path} -> HTTP {e.code}: {e.read().decode(errors='replace')[:500]}")
