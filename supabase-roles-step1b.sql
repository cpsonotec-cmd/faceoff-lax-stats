-- FACEOFF Lax Stats - temporary passwords  (STEP 1b)
-- Run once in Supabase: SQL Editor > New query > paste > Run. Safe to run again.
-- Lets the admin create logins with a temporary password; the person is asked
-- to pick their own password the first time they sign in.

alter table public.profiles
  add column if not exists must_change_password boolean not null default false;

-- a signed-in person clears their own flag after choosing a new password
-- (they still can't change anything else on their profile)
create or replace function public.password_changed() returns void
language sql security definer set search_path = public as $$
  update public.profiles set must_change_password = false where id = auth.uid()
$$;
revoke execute on function public.password_changed() from public, anon;
grant execute on function public.password_changed() to authenticated;
