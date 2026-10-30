#!/usr/bin/env bash
# CrowdSec ASN blocklist (#127, ADR 005): bans every prefix of the networks in
# config/crowdsec/asn-blocklist.txt -- in the Traefik plugin only.
#
# CrowdSec decisions always expire, and the database flush removes old ones, so a
# "permanent" manual ban disappears sooner or later. Instead this script re-applies the
# list every night: delete all decisions with reason homelab/asn-blocklist, import the
# current prefixes with a 7-day duration. If the nightly run stops, the bans expire
# after a week instead of staying forever.
#
# The firewall bouncer must ignore these decisions (it filters by source IP, so a ban
# on a cloud network would also drop the replies to our own outbound connections).
# The script refuses to import before that is configured: run --setup-bouncer once.
#
# Aufruf: sudo homelab-deploy crowdsec-asn-sync            (Kestra-Flow, nachts)
#         sudo bash scripts/security/crowdsec-asn-blocklist.sh [sync]
#         sudo bash scripts/security/crowdsec-asn-blocklist.sh --setup-bouncer   (einmalig)
#         sudo bash scripts/security/crowdsec-asn-blocklist.sh --remove          (Notfall: alle ASN-Sperren aufheben)
set -Eeuo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BLOCKLIST="$REPO/config/crowdsec/asn-blocklist.txt"
ALLOWLIST="$REPO/config/crowdsec/asn-allowlist.txt"
BOUNCER_CFG=/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
REASON=homelab/asn-blocklist
DURATION=168h

fail() { echo "FEHLER: $*"; logger -t crowdsec-asn-blocklist "result=failed reason=\"$*\""; echo "Status: Fehlgeschlagen"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "muss als root laufen"
command -v cscli >/dev/null || fail "cscli nicht gefunden"

# The firewall bouncer ignores decisions whose scenario (= reason) contains this word
bouncer_excludes() { grep -Eq '^scenarios_not_containing:.*asn-blocklist' "$BOUNCER_CFG"; }

setup_bouncer() {
  [ -f "$BOUNCER_CFG" ] || fail "$BOUNCER_CFG fehlt"
  if bouncer_excludes; then echo "Firewall-Bouncer ignoriert ASN-Sperren bereits."; return 0; fi
  grep -q '^scenarios_not_containing:' "$BOUNCER_CFG" \
    && fail "scenarios_not_containing ist schon gesetzt -- bitte \"asn-blocklist\" von Hand ergänzen"
  local bak="/root/crowdsec-firewall-bouncer.yaml.$(date +%Y%m%d-%H%M%S)"
  cp -a "$BOUNCER_CFG" "$bak"
  printf '\n# #127: ASN blocklist only at HTTP level (Traefik plugin), never in iptables\nscenarios_not_containing: ["asn-blocklist"]\n' >> "$BOUNCER_CFG"
  systemctl restart crowdsec-firewall-bouncer
  sleep 3
  if ! systemctl is-active -q crowdsec-firewall-bouncer; then
    cp -a "$bak" "$BOUNCER_CFG"; systemctl restart crowdsec-firewall-bouncer
    fail "Bouncer startet mit der neuen Einstellung nicht -- alte Konfiguration wiederhergestellt"
  fi
  echo "Firewall-Bouncer ignoriert jetzt ASN-Sperren (Backup: $bak)."
}

case "${1:-sync}" in
  --setup-bouncer) setup_bouncer; exit 0 ;;
  --remove)
    cscli decisions delete --scenario "$REASON"
    logger -t crowdsec-asn-blocklist "result=removed"
    exit 0 ;;
  sync) ;;
  *) fail "unbekannte Option '$1' (erlaubt: sync, --setup-bouncer, --remove)" ;;
esac

START=$(date +%s)
WORK=$(mktemp -d /run/crowdsec-asn.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "==> CrowdSec-ASN-Sperrliste"
bouncer_excludes || fail "Firewall-Bouncer würde die Sperren übernehmen -- erst --setup-bouncer ausführen"

# All lookups first: if anything fails, the current bans stay untouched
python3 "$HERE/crowdsec-asn-prefixes.py" "$BLOCKLIST" "$ALLOWLIST" "$WORK/prefixes.txt" "$WORK/samples.txt" \
  || fail "Prefixe nicht ermittelt -- bestehende Sperren bleiben unverändert"
COUNT=$(wc -l < "$WORK/prefixes.txt")

cscli decisions delete --scenario "$REASON" >/dev/null \
  || fail "alte ASN-Sperren nicht löschbar (cscli zu alt für --scenario?) -- nichts importiert"
if [ "$COUNT" -eq 0 ]; then
  echo "    keine aktiven ASNs -- alle ASN-Sperren aufgehoben"
  logger -t crowdsec-asn-blocklist "result=ok prefixes=0"
  echo "Status: Erfolgreich"
  exit 0
fi
cscli decisions import -i "$WORK/prefixes.txt" --format values --scope Range \
  --duration "$DURATION" --reason "$REASON" --type ban --batch 1000 >/dev/null \
  || fail "cscli decisions import fehlgeschlagen -- ASN-Sperren sind gerade NICHT aktiv"
echo "    $COUNT Range-Sperren importiert, Laufzeit $DURATION"

# Checks: the LAPI (what the Traefik plugin asks) knows a ban for one address per ASN,
# and the firewall bouncer did not put it into its ipsets
sleep 15
SETS=$(ipset list -n 2>/dev/null | grep '^crowdsec' || true)
while read -r asn ip; do
  found=$(cscli decisions list -i "$ip" -o json 2>/dev/null || true)
  grep -q "\"$REASON\"" <<<"$found" || fail "$asn: keine Sperre für $ip in der LAPI"
  for s in $SETS; do
    ipset test "$s" "$ip" >/dev/null 2>&1 && fail "$asn: $ip steht im Firewall-Set $s -- Bouncer-Filter greift nicht"
  done
  echo "    $asn: $ip gesperrt (LAPI), nicht in der Firewall"
done < "$WORK/samples.txt"
[ -n "$SETS" ] || echo "    Hinweis: keine crowdsec-ipsets gefunden (nftables-Modus?) -- Firewall-Prüfung übersprungen"

logger -t crowdsec-asn-blocklist "result=ok prefixes=$COUNT asns=$(cut -d' ' -f1 "$WORK/samples.txt" | paste -sd,)"
echo "Dauer: $(( $(date +%s) - START ))s"
echo "Status: Erfolgreich"
