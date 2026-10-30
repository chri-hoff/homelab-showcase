# ADR 005: ASN blocklist for cloud scanners, Traefik plugin only

- **Status:** accepted
- **Date:** 2026-10-29
- **Issue:** #127 (related: ADR 002, ADR 003)

## Context

CrowdSec bans an IP for four hours once one of its scenarios fires. Its alerts for the 30 days
up to 2026-10-29 show where that falls short. There were 69 alerts:

| Network | Alerts | Different IPs |
|---|---|---|
| DigitalOcean (AS14061, Frankfurt) | 35 | 19 |
| Google Cloud (AS396982, AS15169) | 17 | 8 |
| seven other networks | 17 | 7 |

The same scanners return every few days with the same request lists (Jira and PHPUnit CVE
probes, `.env`/`.git` scans), each time from a fresh cloud IP. A per-IP ban therefore always
comes one scan too late. The geo filter does not help, because these IPs are located in Germany.

## Decision

- **Ban whole networks, chosen by hand.** `config/crowdsec/asn-blocklist.txt` lists each ASN
  together with the evidence for it. It starts with AS14061 and AS396982. Google's main network
  AS15169 (Googlebot, Gmail, APIs) is deliberately left out, even though one scanner came from it.
- **Prefixes come from RIPEstat.** CrowdSec decisions have no AS scope, so the sync turns each
  ASN into the prefixes it announces (874 range decisions to start with).
- **An allowlist that takes precedence.** `config/crowdsec/asn-allowlist.txt` lists the own
  ISP, Telegram and the VPN used for testing. An ASN that is on both lists stops the sync, and
  any blocklist prefix that overlaps an allowlisted range is dropped.
- **Traefik plugin only.** The decisions carry the reason `homelab/asn-blocklist`. The firewall
  bouncer ignores it (`scenarios_not_containing: ["asn-blocklist"]`). The firewall bouncer
  matches source IPs in `INPUT` and `DOCKER-USER`, so it would also drop the replies to the
  homelab's own outbound connections: image pulls, APIs and webhooks hosted on these clouds.
  The scanners only probe HTTP anyway.
- **Re-applied every night instead of "permanent".** CrowdSec decisions always expire, and the
  database flush removes old ones. Manually added long bans disappeared this way before. The
  Kestra flow `crowdsec-asn-sync` (04:15) runs `homelab-deploy crowdsec-asn-sync`, which:
  1. fetches all prefixes first, and leaves the existing bans untouched if that fails;
  2. deletes the old decisions and imports the new set with a duration of 7 days;
  3. checks that one address per ASN is banned in the LAPI (the source the plugin queries)
     and is **not** in the firewall bouncer's ipsets.

  If the flow stops running, the bans expire after a week instead of staying forever. Removing
  an ASN from the list lifts its ban on the next run.
- **Suggestions with approval in Telegram** (added the same day). Every hour the alerts go
  to Supabase (`crowdsec_alerts`, kept 12 months; hourly because CrowdSec's flush also
  removes alerts by count, and the decision count is only right while the decision exists). Each Monday, every network with at least
  3 different IPs in 30 days that is on neither list gets a Telegram message with two
  buttons. **Sperren** commits the ASN with its evidence to the blocklist on `main` through
  the Gitea API, then pulls it onto the host and runs the sync. **Nicht sperren** hides the
  network for 90 days. Only clicks from the own chat count, and the allowlist is checked
  again on approval. The commit is the record of the decision; `asn_decisions` keeps both
  kinds.
- **Every ban expires after 180 days.** Each blocklist line ends with `| until YYYY-MM-DD`,
  and the sync refuses lines without it. From the day after that date the sync skips the
  entry and `asn_list` drops it, so the network is observed again. If it keeps scanning,
  it is suggested again. Seven days before the date, Telegram asks **Verlängern** (adds
  180 days, committed) or **Auslaufen lassen**. After the date, an info message follows.
  The line stays in the file as history. Why 180 days: a network-wide ban targets how a
  provider handles abuse, which rarely changes within weeks. Shorter periods would keep
  re-approving the same clouds, and without an end the list goes stale. A banned network
  produces almost no alerts, so the ban cannot be judged by its own evidence; letting it
  expire and observing again can.
- **Safety checks.** The script refuses to import while the firewall bouncer filter is
  missing. It also stops on prefixes larger than /8 (IPv4) or /19 (IPv6) and on more than
  20,000 prefixes in total. Telegram is notified only when a run fails.

## Alternatives considered

| Option | Why not |
|---|---|
| Ban automatically when a network crosses the threshold (as first sketched in the issue) | A wrong automatic ban blocks real traffic, while a missed scan only gets a 404. The threshold only produces a suggestion; one tap in Telegram makes it a reviewed commit. |
| Approval as a Mindwtr task (like update releases) | Takes more steps for a decision that arrives at most weekly, and "reject" does not map cleanly onto a task status. |
| Ban in both bouncers | Breaks outbound traffic to the banned clouds (see above). |
| One long manual ban (`cscli decisions add --duration 8760h`) | Decisions disappear through expiry and the flush, without anyone noticing; there is no record of why a range is banned. |
| Ban only the German prefixes of each ASN | All other prefixes are already blocked by the geo filter, so this changes nothing and needs a geolocation source. |
| CrowdSec community blocklists | They list known-bad IPs. Fresh droplets are exactly what they do not know yet. |

## Consequences

- HTTP requests from DigitalOcean and Google Cloud never reach a service. Legitimate traffic
  from there (for example a webhook from a SaaS hosted on Google Cloud) is blocked as well and
  has to go on the allowlist.
- Outbound connections and non-HTTP ports are unaffected.
- There is a short window of a few seconds each night between deleting and importing.
- A new ASN is a commit that names its evidence. It is either written by hand or created by
  approving a suggestion in Telegram, never by the threshold alone.
