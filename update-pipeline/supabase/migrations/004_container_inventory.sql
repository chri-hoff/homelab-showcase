-- Issue #72: inventory of all running containers + update candidates also for images without
-- an entry in config/versions.yaml (e.g. the Supabase stack itself).
--
-- Populated on every update check run (scripts/supabase/record-inventory.py from
-- docker ps). versions.yaml stays responsible for deploys; containers shows what is
-- actually running.

-- ---------------------------------------------------------------------------
-- containers: one entry per container name, as shown by docker ps
-- ---------------------------------------------------------------------------
create table public.containers (
  container_name text primary key,
  image          text not null,          -- without tag, e.g. "supabase/gotrue"
  tag            text not null,          -- e.g. "v2.196.0" or "latest"
  service        text references public.services (name) on update cascade on delete set null,
  checkable      boolean not null,       -- tag is a version the check can compare
  first_seen     timestamptz not null default now(),
  last_seen      timestamptz not null default now()
);

comment on table public.containers is
  'Laufende Container laut docker ps, bei jedem Update-Check aktualisiert (Issue #72). last_seen < letzter Lauf = Container laeuft nicht mehr.';

-- A container that has reached the version of an open candidate -> candidate done.
-- Counterpart of services_close_candidates for images without a versions.yaml entry.
create function public.containers_close_candidates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.update_candidates
     set status = 'done'
   where service is null
     and image = new.image
     and new_version = new.tag
     and status <> 'done';
  return null;
end;
$$;

create trigger containers_close_candidates
  after insert or update of tag on public.containers
  for each row execute function public.containers_close_candidates();

-- ---------------------------------------------------------------------------
-- update_candidates: service optional (images without a versions.yaml entry)
-- ---------------------------------------------------------------------------
alter table public.update_candidates alter column service drop not null;

-- Uniqueness via the image -- (service, new_version) does not apply when service = null
create unique index update_candidates_image_version_key
  on public.update_candidates (image, new_version);

-- Allowlist: with a service the image must match services.image (as before),
-- without a service the image must currently be running (containers).
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
  elsif not exists (select 1 from public.containers c where c.image = new.image) then
    raise exception 'Image % laeuft nicht (nicht in containers) und hat keinen Service', new.image;
  end if;
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    new.status_changed_at := now();
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- version_drift: versions.yaml vs. actually running tag
-- ---------------------------------------------------------------------------
create view public.version_drift
with (security_invoker = true)
as
select s.name as service, s.version as versions_yaml, c.container_name, c.tag as running
  from public.services s
  join public.containers c on c.service = s.name
 where c.tag is distinct from s.version;

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------
alter table public.containers enable row level security;
revoke all on public.containers, public.version_drift from anon, authenticated;
revoke execute on function public.containers_close_candidates() from public, anon, authenticated;

grant select, insert, update on public.containers to kestra_sync;
grant select on public.version_drift to kestra_sync;

create policy kestra_sync_select on public.containers
  for select to kestra_sync using (true);
create policy kestra_sync_insert on public.containers
  for insert to kestra_sync with check (true);
create policy kestra_sync_update on public.containers
  for update to kestra_sync using (true) with check (true);

notify pgrst, 'reload schema';
