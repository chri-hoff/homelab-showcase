-- Issue #127: CrowdSec alerts as a history for spotting noisy networks (ADR 005).
--
-- Sources: a one-off import of a CrowdSec Console CSV export
-- (scripts/security/crowdsec-console-csv-to-sql.py) and, later, a nightly pull of
-- "cscli alerts list". Both write the same key (start second, source IP, scenario), so
-- overlapping imports do not create duplicates. Nothing here bans anything: the
-- blocklist stays a reviewed file in the repo (config/crowdsec/asn-blocklist.txt).

-- ---------------------------------------------------------------------------
-- crowdsec_alerts: one row per CrowdSec alert
-- ---------------------------------------------------------------------------
create table public.crowdsec_alerts (
  id          bigint generated always as identity primary key,
  started_at  timestamptz not null,      -- truncated to seconds (Console and cscli differ in ms)
  scenario    text not null,
  source_ip   inet not null,
  as_number   bigint,                    -- null if unknown
  as_name     text,
  country     text,
  decisions   integer not null default 0,
  behaviors   text,                      -- e.g. "http:scan,http:exploit" (Console only)
  cves        text,
  target_uris text[],                    -- sample of requested paths
  origin      text not null check (origin in ('console-csv', 'cscli')),
  recorded_at timestamptz not null default now(),
  unique (started_at, source_ip, scenario)
);

create index crowdsec_alerts_started_at_idx on public.crowdsec_alerts (started_at);
create index crowdsec_alerts_as_number_idx on public.crowdsec_alerts (as_number);

comment on table public.crowdsec_alerts is
  'CrowdSec-Alarme als Historie (Issue #127). Grundlage für asn_overview/asn_candidates; gesperrt wird nur über config/crowdsec/asn-blocklist.txt.';

-- ---------------------------------------------------------------------------
-- asn_list: mirror of config/crowdsec/asn-blocklist.txt and asn-allowlist.txt
-- (overwritten by the sync; edit the files in the repo, not this table)
-- ---------------------------------------------------------------------------
create table public.asn_list (
  asn        bigint primary key,
  list       text not null check (list in ('block', 'allow')),
  note       text,
  updated_at timestamptz not null default now()
);

comment on table public.asn_list is
  'Spiegel der ASN-Block-/Allowlist aus dem Repo (Issue #127). Nicht hier bearbeiten.';

-- ---------------------------------------------------------------------------
-- Views for the analysis
-- ---------------------------------------------------------------------------
-- All networks of the last 30 days, with their list status
create view public.asn_overview
with (security_invoker = true)
as
select a.as_number,
       max(a.as_name)                    as as_name,
       l.list,
       count(distinct a.source_ip)       as ips,
       count(*)                          as alerts,
       count(distinct a.started_at::date) as days,
       min(a.started_at)                 as first_seen,
       max(a.started_at)                 as last_seen,
       array_agg(distinct a.scenario)    as scenarios
  from public.crowdsec_alerts a
  left join public.asn_list l on l.asn = a.as_number
 where a.started_at > now() - interval '30 days'
   and a.as_number is not null
 group by a.as_number, l.list;

-- Suggestions: several different IPs from one network, on neither list
create view public.asn_candidates
with (security_invoker = true)
as
select as_number, as_name, ips, alerts, days, first_seen, last_seen, scenarios
  from public.asn_overview
 where list is null
   and ips >= 3
 order by ips desc, alerts desc;

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------
alter table public.crowdsec_alerts enable row level security;
alter table public.asn_list enable row level security;
revoke all on public.crowdsec_alerts, public.asn_list, public.asn_overview, public.asn_candidates
  from anon, authenticated;

grant select, insert, delete on public.crowdsec_alerts to kestra_sync;
grant select, insert, update, delete on public.asn_list to kestra_sync;
grant select on public.asn_overview, public.asn_candidates to kestra_sync;

create policy kestra_sync_select on public.crowdsec_alerts
  for select to kestra_sync using (true);
create policy kestra_sync_insert on public.crowdsec_alerts
  for insert to kestra_sync with check (true);
-- Retention: Kestra may only delete rows older than 12 months
create policy kestra_sync_delete_old on public.crowdsec_alerts
  for delete to kestra_sync using (started_at < now() - interval '12 months');

create policy kestra_sync_all on public.asn_list
  for all to kestra_sync using (true) with check (true);

-- Initial state of the lists (as in the repo on 2026-10-29); from now on the sync
-- mirrors the files and overwrites this.
insert into public.asn_list (asn, list, note) values
  (14061,  'block', 'DigitalOcean'),
  (396982, 'block', 'Google Cloud'),
  (64496,   'allow', 'own ISP'),
  (62041,  'allow', 'Telegram'),
  (64497,  'allow', 'VPN provider -- own tests');

notify pgrst, 'reload schema';
