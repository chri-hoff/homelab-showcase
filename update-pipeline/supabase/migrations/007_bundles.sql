-- Issue #72: bundles -- images that may only be updated as a tested combination
-- (e.g. the Supabase Docker stack). The check run compares a bundle's candidates with
-- the upstream state (compose file in the upstream repo, minimum age min_age_days) and
-- tags them: pending (upstream does not have it yet), fresh (only recently), ready.
-- A release ("Next") does not set an individual target version for bundle members.

create table public.bundles (
  name          text primary key check (name ~ '^[a-z0-9][a-z0-9-]*$'),
  source_repo   text not null,          -- GitHub owner/repo
  compose_path  text not null,          -- path of the compose file in the repo
  min_age_days  integer not null default 14 check (min_age_days >= 0),
  notes         text not null default ''
);

comment on table public.bundles is
  'Getestete Image-Kombinationen (Issue #72): Mitglieder nur gemeinsam auf einen Upstream-Stand heben, der mindestens min_age_days alt ist.';

insert into public.bundles (name, source_repo, compose_path, notes)
values ('supabase', 'supabase/supabase', 'docker/docker-compose.yml',
        'Self-Hosting-Stack: Tags und volumes/ immer zusammen aus einem Upstream-Commit uebernehmen');

alter table public.services
  add column bundle text references public.bundles (name) on update cascade on delete set null;

update public.services set bundle = 'supabase' where stack = 'supabase';

-- Revert individual target versions from earlier releases: for bundles the upstream
-- state applies, not the individual version (otherwise a permanent target/actual drift)
update public.services set version = running_tag
 where bundle is not null and running_tag is not null and version is distinct from running_tag;

alter table public.update_candidates
  add column bundle_state text check (bundle_state in ('pending', 'fresh', 'ready')),
  add column bundle_note  text;

alter table public.bundles enable row level security;
revoke all on public.bundles from anon, authenticated;
grant select on public.bundles to kestra_sync;
create policy kestra_sync_select on public.bundles for select to kestra_sync using (true);

grant update (bundle_state, bundle_note) on public.update_candidates to kestra_sync;

notify pgrst, 'reload schema';
