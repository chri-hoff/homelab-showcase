-- Issue #72: changelog summary (n8n) + Mindwtr task per update candidate.
--
-- Everything is driven by the update check run (docker-update-check, cron or Telegram
-- "checkversion"): scripts/supabase/process-candidate.py pending processes all open
-- candidates without a task on every run and closes the tasks of finished candidates.
-- Deliberately no INSERT webhook: this way every run also catches up on backlog and
-- failed candidates.

-- Reference to the Mindwtr task. Several candidates of the same service share one
-- open task (new version -> existing task is updated, see #70).
alter table public.update_candidates add column mindwtr_task_id text;

-- When the task was completed in Mindwtr -- after that the run no longer touches it.
alter table public.update_candidates add column mindwtr_task_closed_at timestamptz;

-- Kestra may fill in exactly these columns -- status/version/image stay off-limits.
grant update (changelog_summary, mindwtr_task_id, mindwtr_task_closed_at)
  on public.update_candidates to kestra_sync;

create policy kestra_sync_update on public.update_candidates
  for update to kestra_sync using (true) with check (true);

notify pgrst, 'reload schema';
