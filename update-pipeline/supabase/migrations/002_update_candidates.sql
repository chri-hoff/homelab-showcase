-- Issue #72, phase 3: populate update_candidates (#70) + database webhook to Kestra.

-- ---------------------------------------------------------------------------
-- Kestra (docker-update-check) may read and insert candidates -- not update/delete them.
-- The status is set in Studio (later possibly via Mindwtr), "done" by the trigger below.
-- ---------------------------------------------------------------------------
grant select, insert on public.update_candidates to kestra_sync;

create policy kestra_sync_select on public.update_candidates
  for select to kestra_sync using (true);
create policy kestra_sync_insert on public.update_candidates
  for insert to kestra_sync with check (status = 'inbox');

-- ---------------------------------------------------------------------------
-- Set a candidate to "done" automatically once services.version (i.e. versions.yaml after
-- the next sync) has reached the candidate version.
-- ---------------------------------------------------------------------------
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
     and new_version = new.version
     and status <> 'done';
  return null;
end;
$$;

create trigger services_close_candidates
  after update of version on public.services
  for each row execute function public.services_close_candidates();

revoke execute on function public.services_close_candidates() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Database webhook: every status change of a candidate -> Kestra flow
-- supabase-candidate-status (phase 3: log only, no deploy).
--
-- supabase_functions.http_request() comes from volumes/db/webhooks.sql (pg_net, asynchronous:
-- the request is only sent after commit, so an unreachable Kestra does not block the
-- change). Payload: {type, table, schema, record, old_record}.
-- "kestra" is only reachable via the supabase-hooks network (see docker-compose.yaml).
-- ---------------------------------------------------------------------------
create trigger update_candidates_status_webhook
  after update of status on public.update_candidates
  for each row
  when (old.status is distinct from new.status)
  execute function supabase_functions.http_request(
    'http://kestra:8080/api/v1/executions/webhook/homelab/supabase-candidate-status/<KESTRA_WEBHOOK_KEY>',
    'POST',
    '{"Content-Type": "application/json"}',
    '{}',
    '5000'
  );

notify pgrst, 'reload schema';
