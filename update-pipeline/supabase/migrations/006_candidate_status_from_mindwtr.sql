-- Issue #72: the status of update candidates comes from Mindwtr (tasks in project Homelab).
--
-- process-candidate.py pending reads the status of the Mindwtr task on every check run:
--   "Next" (next)    -> update released: services.version (target) = candidate version,
--                       candidate + task -> waiting; the export in the same run deploys
--   other statuses   -> mirrored into update_candidates.status
-- For this, kestra_sync may now change the status (previously Studio only).
-- The candidate's version/image remain off-limits for kestra_sync.

grant update (status) on public.update_candidates to kestra_sync;

notify pgrst, 'reload schema';
