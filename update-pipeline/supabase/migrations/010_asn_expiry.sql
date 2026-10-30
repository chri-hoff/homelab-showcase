-- Issue #127: ASN bans expire (ADR 005).
--
-- Every blocklist entry carries "| until YYYY-MM-DD" (default 180 days). asn_list only
-- mirrors active entries, so an expired network is observed and suggested again.
-- asn_expiry_notices remembers which Telegram notice (reminder 7 days before, info
-- after expiry) was already sent for which date, so a missed night only delays it.

alter table public.asn_list add column until date;

create table public.asn_expiry_notices (
  asn     bigint not null,
  until   date not null,
  kind    text not null check (kind in ('reminder', 'expired')),
  sent_at timestamptz not null default now(),
  primary key (asn, until, kind)
);

comment on table public.asn_expiry_notices is
  'Gesendete Ablauf-Hinweise zur ASN-Sperrliste (Issue #127), je ASN/Ablaufdatum/Art einmal.';

alter table public.asn_expiry_notices enable row level security;
revoke all on public.asn_expiry_notices from anon, authenticated;
grant select, insert on public.asn_expiry_notices to kestra_sync;

create policy kestra_sync_select on public.asn_expiry_notices
  for select to kestra_sync using (true);
create policy kestra_sync_insert on public.asn_expiry_notices
  for insert to kestra_sync with check (true);

notify pgrst, 'reload schema';
