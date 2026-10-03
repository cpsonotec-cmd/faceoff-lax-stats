-- FACEOFF Lax Stats - Supabase setup
-- Run this once in your Supabase project: SQL Editor > New query > paste > Run.
-- It creates the table the app syncs to, and lets the app read/write it with the
-- public anon key (the key shipped in the app).

create table if not exists public.app_state (
  team_key   text primary key,
  data       jsonb        not null,
  updated_at timestamptz  not null default now()
);

alter table public.app_state enable row level security;

-- Allow the app (anon key) to read and upsert rows.
-- NOTE: anyone who has your Supabase URL + anon key + a team key can read/write
-- that team's data. For a youth team tracker that is usually fine. To lock it down
-- later (per-user logins), tell Claude and it will switch the app to Supabase Auth.
drop policy if exists faceoff_anon_all on public.app_state;
create policy faceoff_anon_all
  on public.app_state
  for all
  to anon
  using (true)
  with check (true);
