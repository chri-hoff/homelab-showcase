#!/usr/bin/env bash
# Checks running Docker containers for newer images
set -euo pipefail
echo "============================================"
echo " Docker Update Check"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# ── Running containers → collect image tags ────────────────────────────────
# Format: "namespace/image:tag" or "image:tag" (library)
RUNNING_IMAGES=$(docker ps --format '{{.Image}}' | sort -u)

if [[ -z "$RUNNING_IMAGES" ]]; then
    echo "Keine laufenden Container gefunden."
    exit 0
fi

# ──  Version-pinned images: Docker Hub API ─────────────────────────────────
echo ""
echo "=== Version-gepinnte Images (Docker Hub) ==="
echo ""

python3 << PYEOF
import urllib.request, json, re, sys, os

RUNNING = """${RUNNING_IMAGES}""".strip().splitlines()

# Optional: also write found updates as JSON lines to this file
# (for supabase update_candidates, Issue #72). Without the variable, behavior is unchanged.
JSON_OUT = os.environ.get('UPDATE_CHECK_JSON')

def image_ref(image_str):
    """'namespace/image:tag' -> 'namespace/image' (as docker ps shows it, without tag/digest)."""
    image_str = image_str.split('@')[0]
    if ':' in image_str.split('/')[-1]:
        return image_str.rsplit(':', 1)[0]
    return image_str

def parse_image(image_str):
    """Splits 'namespace/image:tag' or 'image:tag' into (registry, namespace, image, tag)."""
    # Ignore SHA digest
    image_str = image_str.split('@')[0]
    if ':' in image_str.split('/')[-1]:
        ref, tag = image_str.rsplit(':', 1)
    else:
        ref, tag = image_str, 'latest'
    parts = ref.split('/')
    if len(parts) == 1:
        return 'dockerhub', 'library', parts[0], tag
    elif len(parts) == 2:
        return 'dockerhub', parts[0], parts[1], tag
    elif len(parts) == 3 and parts[0] == 'ghcr.io':
        return 'ghcr', parts[1], parts[2], tag
    else:
        # unknown registry → skip
        return None, None, None, None

def version_pattern(tag):
    """Derives a search pattern for newer versions from the current tag."""
    # v3.7 → ^v3\.\d+(\.\d+)?$
    # 11.4 → ^11\.\d+(\.\d+)?$
    # 17.2 → ^17(\.\d+)?$
    # 26.04.5.1.1 → ^26(\.\d+){4}$  (more than 3 parts, e.g. Collabora: part count stays fixed)
    m = re.match(r'^(v?)(\d+)((?:\.\d+)+)$', tag)
    if not m:
        return None
    prefix = m.group(1)
    major  = m.group(2)
    rest   = m.group(3).count('.')
    if rest > 2:
        return rf'^{re.escape(prefix)}{major}(\.\d+){{{rest}}}$'
    # Pin major, leave minor+patch open
    return rf'^{re.escape(prefix)}{major}\.\d+(\.\d+)?$'

def get_latest_tags(namespace, image, pattern, n=5):
    all_tags = []
    for page in range(1, 6):
        url = (f"https://hub.docker.com/v2/repositories/{namespace}/{image}"
               f"/tags?page_size=100&page={page}")
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                d = json.loads(r.read())
        except Exception as e:
            return f"ERROR: {e}"
        for t in d.get('results', []):
            if re.match(pattern, t['name']):
                all_tags.append(t['name'])
        if not d.get('next'):
            break
    return sorted(
        all_tags,
        key=lambda v: [int(x) for x in re.findall(r'\d+', v)],
        reverse=True
    )[:n]

def get_latest_tags_ghcr(namespace, image, pattern, n=5):
    """Like get_latest_tags, but for ghcr.io (GitHub Container Registry).
    Docker Hub's v2 API does not know ghcr.io -- GHCR speaks the generic
    OCI distribution API and needs an (anonymous) pull token for it."""
    repo = f"{namespace}/{image}"
    try:
        token_url = f"https://ghcr.io/token?scope=repository:{repo}:pull"
        with urllib.request.urlopen(token_url, timeout=10) as r:
            token = json.loads(r.read())['token']
    except Exception as e:
        return f"ERROR: Token-Abruf fehlgeschlagen: {e}"

    all_tags = []
    url = f"https://ghcr.io/v2/{repo}/tags/list?n=100"
    for _ in range(10):
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                d = json.loads(r.read())
                link = r.headers.get('Link')
        except Exception as e:
            return f"ERROR: {e}"
        for t in d.get('tags', []):
            if re.match(pattern, t):
                all_tags.append(t)
        m = re.search(r'<([^>]+)>;\s*rel="next"', link) if link else None
        if not m:
            break
        next_path = m.group(1)
        url = next_path if next_path.startswith('http') else f"https://ghcr.io{next_path}"

    return sorted(
        all_tags,
        key=lambda v: [int(x) for x in re.findall(r'\d+', v)],
        reverse=True
    )[:n]

def ver(s):
    nums = re.findall(r'\d+', s)
    return [int(x) for x in nums] if nums else [0]

skipped = []

for raw in RUNNING:
    raw = raw.strip()
    if not raw:
        continue

    registry, ns, img, tag = parse_image(raw)

    # Skip unknown registry
    if registry is None:
        skipped.append(raw)
        continue

    # 'latest' or non-numeric tags cannot be compared meaningfully
    pat = version_pattern(tag)
    if not pat:
        skipped.append(raw)
        continue

    if registry == 'ghcr':
        tags = get_latest_tags_ghcr(ns, img, pat)
    else:
        tags = get_latest_tags(ns, img, pat)

    if isinstance(tags, str):          # error message
        print(f"  [!]     {raw} — {tags}")
        continue

    if tags:
        latest = tags[0]
        if ver(latest) > ver(tag):
            status = f"[UPDATE] {raw} → {latest}"
            if len(tags) > 1:
                status += f"  (auch: {', '.join(tags[1:])})"
            if JSON_OUT:
                with open(JSON_OUT, 'a') as fh:
                    fh.write(json.dumps({'image': image_ref(raw), 'current': tag, 'latest': latest}) + chr(10))
        else:
            status = f"[OK]     {raw}"
        print("  " + status)
    else:
        print(f"  [?]     {raw} — Keine passenden Tags gefunden")

if skipped:
    print()
    print("  Übersprungen (kein Docker Hub / kein Versions-Tag):")
    for s in skipped:
        print(f"    - {s}")
PYEOF

echo ""
echo "=== Manuell gepinnte Plugins (GitHub Releases) ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# The source is config/manual-plugin-versions.yaml, NOT the respective
# services/*/config/ file: services/*/config is entirely in .gitignore
# (see the header comment there) and is therefore never versioned/never
# pulled to the server -- reading from there would always fail here.
#
# "yq -r '<path> | keys | .[]' file" instead of "yq -o=json": the latter is a
# mikefarah/yq flag (present in the update-runner container version), but
# not every yq installation is the same -- e.g. the Python-based yq
# (kislyuk/yq) passes unknown flags 1:1 to jq, which then fails with
# "Unknown option". -r/keys works in both variants, just like the existing
# pattern in sops-auto-update.fish.
PLUGINS_FILE="${REPO_ROOT}/config/manual-plugin-versions.yaml"

for key in $(yq -r '.plugins | keys | .[]' "$PLUGINS_FILE"); do
    current=$(yq -r ".plugins.\"$key\".version" "$PLUGINS_FILE")
    repo=$(yq -r ".plugins.\"$key\".github_repo" "$PLUGINS_FILE")

    if [ -z "$current" ] || [ "$current" = "null" ] || [ -z "$repo" ] || [ "$repo" = "null" ]; then
        echo "  [!]     ${key} — version/github_repo fehlt in ${PLUGINS_FILE}"
        continue
    fi

    RESPONSE=$(curl -sf -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo}/releases/latest") || RESPONSE=""

    if [ -z "$RESPONSE" ]; then
        echo "  [!]     ${key} ${current} — GitHub-API nicht erreichbar"
        continue
    fi

    latest=$(printf '%s' "$RESPONSE" | jq -r '.tag_name // empty')

    if [ -z "$latest" ]; then
        echo "  [!]     ${key} ${current} — kein tag_name in GitHub-Antwort"
        continue
    fi

    # Numeric version comparison via Python instead of "sort -V": busybox sort
    # (Alpine/update-runner container) does not reliably support -V, whereas
    # python3 is guaranteed to exist on the host AND in the container.
    if python3 -c "
import re, sys
def ver(s):
    n = re.findall(r'\d+', s)
    return [int(x) for x in n] if n else [0]
sys.exit(0 if ver('$latest') > ver('$current') else 1)
"; then
        echo "  [UPDATE] ${key} ${current} → ${latest}"
    else
        echo "  [OK]     ${key} ${current}"
    fi
done

echo ""
echo "============================================"
echo " Fertig."
echo "============================================"