-- Issue #72, phase 4: Supabase becomes the source of truth, one table for target + actual.
--
-- services now contains every running image (per stack), not just the entries from
-- config/versions.yaml. versions.yaml is generated from it (export-versions.py) and
-- committed directly to main by the check run. containers + version_drift are dropped.
--
--   version      target -- change in Studio to trigger an update
--   running_tag  actual -- from docker ps in the check run
--   updateable   false = never deploy automatically (kestra, vault, traefik, Supabase core)
--   deployable   stack directory uses ${VERSION} -> deployable via versions.yaml

-- ---------------------------------------------------------------------------
-- extend services
-- ---------------------------------------------------------------------------
alter table public.services
  add column stack       text,
  add column containers  text[] not null default '{}',
  add column running_tag text,
  add column checkable   boolean not null default false,
  add column deployable  boolean not null default false,
  add column first_seen  timestamptz not null default now(),
  add column last_seen   timestamptz not null default now();

comment on table public.services is
  'Fuehrend fuer config/versions.yaml (Issue #72, Phase 4): ein Eintrag pro Stack + Image. version = Soll (Studio), running_tag = Ist (Check-Lauf). Nach 7 Tagen nicht gesehen -> geloescht.';

-- stack/containers/running_tag are filled by the next check run from the compose labels.
-- last_seen = now: existing entries (incl. diun) get a 7-day grace period from here on.

-- Supabase core + previous manual exceptions: never deploy automatically. The pipeline
-- needs db/rest/api-gw itself -- a broken auto-update could no longer repair it.
update public.services set updateable = false where name in ('kestra', 'vault', 'traefik');

-- Target version changed in Studio -> bump last_updated as well (so it shows up in the export)
create or replace function public.services_set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  if new.version is distinct from old.version and new.last_updated is not distinct from old.last_updated then
    new.last_updated := current_date;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Candidates: "done" once the container is running it (actual), not already on target change
-- ---------------------------------------------------------------------------
drop trigger services_close_candidates on public.services;
drop function public.services_close_candidates();

create function public.services_close_candidates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.update_candidates
     set status = 'done'
   where service = new.name
     and new_version = new.running_tag
     and status <> 'done';
  return null;
end;
$$;

create trigger services_close_candidates
  after insert or update of running_tag on public.services
  for each row execute function public.services_close_candidates();

-- Attach candidates without a service (from phase 3) to the new entry with the same image
create function public.services_adopt_candidates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.update_candidates
     set service = new.name
   where service is null
     and image = new.image;
  return null;
end;
$$;

create trigger services_adopt_candidates
  after insert or update of image on public.services
  for each row execute function public.services_adopt_candidates();

-- If a service goes away (not seen for 7 days), its candidates go with it
alter table public.update_candidates
  drop constraint update_candidates_service_fkey,
  add constraint update_candidates_service_fkey
    foreign key (service) references public.services (name) on update cascade on delete cascade;

-- Allowlist: image must match an entry in services
create or replace function public.update_candidates_check()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  expected text;
begin
  if new.service is not null then
    select s.image into expected from public.services s where s.name = new.service;
    if new.image is distinct from expected then
      raise exception 'Image % passt nicht zu Service % (erwartet: %)', new.image, new.service, expected;
    end if;
  elsif not exists (select 1 from public.services s where s.image = new.image) then
    raise exception 'Image % ist in keinem Service eingetragen', new.image;
  end if;
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    new.status_changed_at := now();
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Target/actual deviation as a view on services
-- ---------------------------------------------------------------------------
drop view public.version_drift;
create view public.version_drift
with (security_invoker = true)
as
select name as service, version as soll, running_tag as laeuft, containers
  from public.services
 where running_tag is not null and running_tag is distinct from version;

-- ---------------------------------------------------------------------------
-- containers is dropped
-- ---------------------------------------------------------------------------
drop trigger containers_close_candidates on public.containers;
drop function public.containers_close_candidates();
drop table public.containers;

-- ---------------------------------------------------------------------------
-- Access: kestra_sync maintains the inventory in services and may delete entries after
-- 7 days. It only sets version/updateable on insert -- after that, Studio.
-- ---------------------------------------------------------------------------
revoke all on public.version_drift from anon, authenticated;
revoke execute on function public.services_close_candidates(), public.services_adopt_candidates()
  from public, anon, authenticated;
grant select on public.version_drift to kestra_sync;
grant delete on public.services to kestra_sync;

create policy kestra_sync_delete on public.services
  for delete to kestra_sync using (true);

notify pgrst, 'reload schema';
