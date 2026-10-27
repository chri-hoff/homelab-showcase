#!/usr/bin/env bash
# Scans the images of all running containers with Trivy (Issue #103, STEP 8) and
# prints a short summary: per image the number of CRITICAL/HIGH vulnerabilities
# that already have a fix (--ignore-unfixed). Images without findings are only counted.
#
# Trivy itself runs as a throwaway container via the Docker socket, no installation
# on the host needed. The vulnerability DB is kept in the named volume "trivy-cache"
# and updated once per run.
#
# Run:   sudo homelab-deploy trivy-scan   (or bash scripts/security/trivy-scan.sh as root)
# Used:  services/kestra/flows/trivy-scan.yml (weekly + Telegram)
# Exit:  0 = scan ran (with or without findings), 1 = at least one image could not be scanned
set -uo pipefail

TRIVY_IMAGE=${TRIVY_IMAGE:-aquasec/trivy:0.65.0}
SEVERITY=HIGH,CRITICAL

trivy() {
  docker run --rm \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --memory 2g --pids-limit 256 \
    -v trivy-cache:/root/.cache/trivy \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    "$TRIVY_IMAGE" "$@"
}

IMAGES=$(docker ps --format '{{.Image}}' | sort -u)
[[ -n "$IMAGES" ]] || { echo "Keine laufenden Container gefunden."; exit 0; }

if ! DB_LOG=$(trivy image --download-db-only --quiet 2>&1); then
  echo "Trivy-Scan: DB-Update fehlgeschlagen"
  echo "$DB_LOG" | tail -5
  exit 1
fi

FINDINGS=()
CLEAN=0
FAILED=()
for img in $IMAGES; do
  if ! REPORT=$(trivy image --skip-db-update --scanners vuln --severity "$SEVERITY" \
      --ignore-unfixed --format json --quiet "$img" 2>/dev/null); then
    FAILED+=("$img")
    continue
  fi
  # Count each CVE once per package (multi-layer/multi-target reports repeat findings)
  LINE=$(jq -r --arg img "$img" '
    [.Results[]?.Vulnerabilities[]?] | unique_by(.VulnerabilityID + .PkgName) as $v
    | ($v | map(select(.Severity == "CRITICAL"))) as $c
    | ($v | map(select(.Severity == "HIGH")) | length) as $h
    | if ($c | length) + $h == 0 then empty
      else "\($c | length)\t\($h)\t\($img)\t\([$c[].VulnerabilityID] | unique | .[:3] | join(" "))"
      end' <<<"$REPORT")
  if [[ -n "$LINE" ]]; then FINDINGS+=("$LINE"); else CLEAN=$((CLEAN + 1)); fi
done

echo "Trivy-Scan $(date '+%Y-%m-%d') – fixbare HIGH/CRITICAL"
echo "$(wc -w <<<"$IMAGES") Images: ${#FINDINGS[@]} mit Funden, $CLEAN sauber, ${#FAILED[@]} Fehler"
if ((${#FINDINGS[@]})); then
  echo
  printf '%s\n' "${FINDINGS[@]}" | sort -t$'\t' -k1,1nr -k2,2nr | while IFS=$'\t' read -r c h img ids; do
    echo "• ${img}: C ${c} / H ${h}${ids:+ (${ids})}"
  done
fi
if ((${#FAILED[@]})); then
  echo
  echo "Nicht scannbar:"
  printf '• %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0
