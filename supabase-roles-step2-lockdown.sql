-- FACEOFF Lax Stats - lock down  (STEP 2 of 2)
-- Run this only after you have signed in to the login version as admin and
-- approved your coaches. It removes the old "anyone with the app" access, so from
-- now on only signed-in, approved people can see or change team data.

drop policy if exists faceoff_anon_all on public.app_state;
revoke all on public.app_state from anon;

-- To undo (go back to open access), run:
--   create policy faceoff_anon_all on public.app_state for all to anon using (true) with check (true);
--   grant select, insert, update on public.app_state to anon;
