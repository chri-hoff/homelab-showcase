-- Issue #127: decisions on ASN suggestions from Telegram (ADR 005).
--
-- "Ja" commits the ASN to config/crowdsec/asn-blocklist.txt, "Nein" keeps it out of
-- the suggestions for 90 days. Both are recorded here; an approved ASN also shows up
-- in asn_list (block) after the next sync.

create table public.asn_decisions (
  asn        bigint primary key,
  decision   text not null check (decision in ('approved', 'rejected')),
  decided_at timestamptz not null default now(),
  note       text
);

comment on table public.asn_decisions is
  'Entscheidungen zu ASN-Vorschlägen aus Telegram (Issue #127); 90 Tage kein erneuter Vorschlag.';

-- Suggestions: as in 008, minus networks decided on in the last 90 days
create or replace view public.asn_candidates
with (security_invoker = true)
as
select o.as_number, o.as_name, o.ips, o.alerts, o.days, o.first_seen, o.last_seen, o.scenarios
  from public.asn_overview o
 where o.list is null
   and o.ips >= 3
   and not exists (select 1 from public.asn_decisions d
                    where d.asn = o.as_number
                      and d.decided_at > now() - interval '90 days')
 order by o.ips desc, o.alerts desc;

alter table public.asn_decisions enable row level security;
revoke all on public.asn_decisions from anon, authenticated;
grant select, insert, update on public.asn_decisions to kestra_sync;

create policy kestra_sync_all on public.asn_decisions
  for all to kestra_sync using (true) with check (true);

notify pgrst, 'reload schema';
