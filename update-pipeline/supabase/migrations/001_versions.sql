-- Issue #72, phase 2: shadow tables for config/versions.yaml + update_candidates (#70).
-- Applied via services/supabase/migrate.sh (one transaction per file).
--
-- In "public", Supabase grants ALL to anon/authenticated/service_role via default privileges.
-- Hence per table: enable RLS + explicitly revoke privileges from anon/authenticated.
-- service_role (Studio) bypasses RLS anyway.

-- ---------------------------------------------------------------------------
-- services: one row per entry in config/versions.yaml
-- ---------------------------------------------------------------------------
create table public.services (
  name             text primary key
                   check (name ~ '^[a-z0-9][a-z0-9-]*$'),
  version          text not null
                   check (version ~ '^[A-Za-z0-9][A-Za-z0-9._+-]*$'),
  image            text not null
                   check (image ~ '^[a-z0-9][a-z0-9._/-]*$'),
  image_digest     text
                   check (image_digest ~ '^sha256:[0-9a-f]{64}$'),
  last_updated     date,
  updateable       boolean not null default true,
  breaking_changes boolean not null default false,
  notes            text not null default '',
  updated_at       timestamptz not null default now()
);

comment on table public.services is
  'Spiegel von config/versions.yaml (Issue #72). Bis zur Phase-4-Entscheidung ist die YAML fuehrend.';

-- ---------------------------------------------------------------------------
-- service_version_history: filled automatically by trigger, replaces git history as audit trail
-- ---------------------------------------------------------------------------
create table public.service_version_history (
  id          bigint generated always as identity primary key,
  service     text not null,            -- deliberately no FK: history survives even if a service is deleted
  old_version text,
  new_version text not null,
  old_image   text,
  new_image   text not null,
  changed_by  text not null,
  changed_at  timestamptz not null default now()
);

create index service_version_history_service_idx
  on public.service_version_history (service, changed_at desc);

create function public.services_set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger services_set_updated_at
  before update on public.services
  for each row execute function public.services_set_updated_at();

-- AFTER instead of BEFORE: with upserts (INSERT ... ON CONFLICT DO UPDATE), BEFORE INSERT
-- triggers also fire for rows that then hit the conflict -> bogus "new" entries.
-- Who changed it: for PostgREST access the role from the JWT, otherwise the DB user (Studio/psql).
-- security definer: the table owner writes the history, callers need no INSERT on it.
create function public.services_track_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor text := coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::json ->> 'role',
    session_user
  );
begin
  if tg_op = 'INSERT'
     or new.version is distinct from old.version
     or new.image is distinct from old.image then
    insert into public.service_version_history
      (service, old_version, new_version, old_image, new_image, changed_by)
    values (
      new.name,
      case when tg_op = 'UPDATE' then old.version end,
      new.version,
      case when tg_op = 'UPDATE' then old.image end,
      new.image,
      actor
    );
  end if;
  return null;
end;
$$;

create trigger services_track_changes
  after insert or update on public.services
  for each row execute function public.services_track_changes();

-- ---------------------------------------------------------------------------
-- update_candidates: updates found by the check flow (phase 3, #70)
-- ---------------------------------------------------------------------------
create table public.update_candidates (
  id                bigint generated always as identity primary key,
  service           text not null references public.services (name) on update cascade,
  image             text not null,
  new_version       text not null
                    check (new_version ~ '^[A-Za-z0-9][A-Za-z0-9._+-]*$'),
  digest            text
                    check (digest ~ '^sha256:[0-9a-f]{64}$'),
  status            text not null default 'inbox'
                    check (status in ('inbox', 'someday', 'next', 'waiting', 'done')),
  changelog_summary text,
  detected_at       timestamptz not null default now(),
  status_changed_at timestamptz,
  unique (service, new_version)
);

-- Image allowlist: a candidate may only carry the image registered for its service
create function public.update_candidates_check()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  expected text;
begin
  select s.image into expected from public.services s where s.name = new.service;
  if new.image is distinct from expected then
    raise exception 'Image % passt nicht zu Service % (erwartet: %)', new.image, new.service, expected;
  end if;
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    new.status_changed_at := now();
  end if;
  return new;
end;
$$;

create trigger update_candidates_check
  before insert or update on public.update_candidates
  for each row execute function public.update_candidates_check();

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------
alter table public.services                enable row level security;
alter table public.service_version_history enable row level security;
alter table public.update_candidates       enable row level security;

revoke all on public.services, public.service_version_history, public.update_candidates
  from anon, authenticated;
revoke execute on function public.services_set_updated_at(), public.services_track_changes(),
  public.update_candidates_check()
  from public, anon, authenticated;

-- Role for the Kestra sync (versions.yaml -> services). PostgREST switches to this
-- role when the JWT in the Authorization header carries "role": "kestra_sync".
-- No DELETE: entries that only exist in Supabase are merely reported by the sync.
create role kestra_sync nologin noinherit;
grant kestra_sync to authenticator;

grant usage on schema public to kestra_sync;
grant select, insert, update on public.services to kestra_sync;
grant select on public.service_version_history to kestra_sync;

create policy kestra_sync_select on public.services
  for select to kestra_sync using (true);
create policy kestra_sync_insert on public.services
  for insert to kestra_sync with check (true);
create policy kestra_sync_update on public.services
  for update to kestra_sync using (true) with check (true);
create policy kestra_sync_select on public.service_version_history
  for select to kestra_sync using (true);

-- Reload the PostgREST schema cache so the tables are visible via the API immediately
notify pgrst, 'reload schema';
