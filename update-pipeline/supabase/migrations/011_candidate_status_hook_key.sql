-- #157: the Kestra webhook key of supabase-candidate-status is no longer a literal in the
-- repository. The trigger function reads it from Supabase Vault (secret
-- "kestra_candidate_status_key"), which services/kestra/rotate-webhook-keys.sh fills from
-- HashiCorp Vault (homelab/services/kestra-webhooks, field candidate_status).
--
-- Payload as before (supabase_functions.http_request): {type, table, schema, record,
-- old_record}. pg_net sends asynchronously after commit, so an unreachable Kestra does not
-- block the status change. If the key is missing, the change goes through and only a
-- warning is logged.
--
-- The function lives in homelab_ops (no grants for anon/authenticated, not exposed by
-- PostgREST) and runs as its owner so the updating role (kestra_sync, Studio) needs no
-- access to the vault schema.

create or replace function homelab_ops.notify_candidate_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  hook_key text;
begin
  select decrypted_secret into hook_key
    from vault.decrypted_secrets
   where name = 'kestra_candidate_status_key';
  if hook_key is null or hook_key = '' then
    raise warning 'kestra_candidate_status_key missing in Supabase Vault -- Kestra webhook skipped';
    return new;
  end if;
  perform net.http_post(
    url := 'http://kestra:8080/api/v1/executions/webhook/homelab/supabase-candidate-status/' || hook_key,
    body := jsonb_build_object(
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema,
      'record', to_jsonb(new),
      'old_record', to_jsonb(old)),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 5000);
  return new;
end;
$$;

revoke all on function homelab_ops.notify_candidate_status() from public;

drop trigger if exists update_candidates_status_webhook on public.update_candidates;
create trigger update_candidates_status_webhook
  after update of status on public.update_candidates
  for each row
  when (old.status is distinct from new.status)
  execute function homelab_ops.notify_candidate_status();
