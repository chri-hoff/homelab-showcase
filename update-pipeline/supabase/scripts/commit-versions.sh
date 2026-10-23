#!/bin/sh
# Generate config/versions.yaml from Supabase and commit it directly to main (Issue #72, phase 4).
#
# Deliberately works in a FRESH clone, not in the host checkout /repo: the push triggers
# update-on-merge via the Gitea webhook, which runs "git pull" in the host checkout and
# detects version changes by diffing before/after. A commit made directly in /repo would
# already be "there" -- the pull would find nothing and nothing would be deployed.
#
# Run from the repo root (Kestra: docker-update-check, task candidates). Needs
# SUPABASE_* (supabase_api.py) and:
#   GIT_PUSH_URL  full SSH URL incl. port (Gitea SSH runs on 2222; the origin URL of
#                 the host checkout relies on ~/.ssh/config for that, which is
#                 deliberately not mounted into the task)
#   GIT_PUSH_KEY  (default /secrets/git_push_key) Gitea deploy key with write access.
#                 The regular server key is read-only and is not used here.

set -eu

GIT_PUSH_KEY=${GIT_PUSH_KEY:-/secrets/git_push_key}
# No silent fallback to another SSH key (the server key is read-only)
if [ ! -f "$GIT_PUSH_KEY" ]; then
  echo "FEHLER: Push-Key $GIT_PUSH_KEY fehlt -- /opt/docker/secrets/kestra_git_push_key auf dem" \
       "Host angelegt und im Flow (Task candidates, volumes) eingehaengt?" >&2
  exit 1
fi
export GIT_SSH_COMMAND="ssh -i $GIT_PUSH_KEY -o IdentitiesOnly=yes"

REPO_DIR=$(pwd)
ORIGIN=${GIT_PUSH_URL:?GIT_PUSH_URL fehlt (z. B. ssh://git@host:2222/Owner/repo.git)}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git clone -q --depth 1 --branch main "$ORIGIN" "$WORK"
python3 "$REPO_DIR/scripts/supabase/export-versions.py" "$WORK/config/versions.yaml" --write

cd "$WORK"
if git diff --quiet -- config/versions.yaml; then
  exit 0
fi

git -c user.name="Kestra Auto-Update" -c user.email="kestra-auto-update@homelab.local" \
  commit -q -m "chore(versions): versions.yaml aus Supabase (Check-Lauf, #72)" -- config/versions.yaml

# main may have moved since the clone -> rebase once and retry
if ! git push -q origin HEAD:main; then
  git fetch -q --depth 20 origin main
  git rebase -q origin/main
  git push -q origin HEAD:main
fi
echo "versions.yaml auf main committet: $(git rev-parse --short HEAD)"
