-- FACEOFF Lax Stats - logins, roles, family view and change log  (STEP 1 of 2)
-- Run once in Supabase: SQL Editor > New query > paste all of this > Run.
-- Safe to run more than once. It does NOT remove today's open access yet, so the
-- current app keeps working while you try the login version. Step 2 locks it down.

-- 1. One profile per signed-in person -------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  email        text,
  display_name text,
  role         text not null default 'pending'
               check (role in ('pending', 'admin', 'coach', 'assistant', 'family', 'disabled')),
  team_key     text not null default 'express-east-2034',
  player_ids   text[] not null default '{}',
  created_at   timestamptz not null default now()
);
alter table public.profiles enable row level security;

-- helpers (security definer so policies can read profiles without recursion)
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;
create or replace function public.my_team() returns text
language sql stable security definer set search_path = public as $$
  select team_key from public.profiles where id = auth.uid()
$$;

-- new sign-ups get a profile; the very first account becomes the admin,
-- everyone after that waits as 'pending' until the admin approves them
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, display_name, role)
  values (
    new.id,
    new.email,
    coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(new.email, '@', 1)),
    case when exists (select 1 from public.profiles where role = 'admin') then 'pending' else 'admin' end
  )
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- people see their own profile; the admin sees and edits everyone's
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.my_role() = 'admin');
drop policy if exists profiles_admin_update on public.profiles;
create policy profiles_admin_update on public.profiles for update to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');
grant select, update on public.profiles to authenticated;

-- 2. Team data: coaches and admin edit, assistant coaches read only -------------
-- (family members never read this table directly; they use family_view below)
drop policy if exists app_state_staff_read on public.app_state;
create policy app_state_staff_read on public.app_state for select to authenticated
  using (team_key = public.my_team() and public.my_role() in ('admin', 'coach', 'assistant'));
drop policy if exists app_state_coach_insert on public.app_state;
create policy app_state_coach_insert on public.app_state for insert to authenticated
  with check (team_key = public.my_team() and public.my_role() in ('admin', 'coach'));
drop policy if exists app_state_coach_update on public.app_state;
create policy app_state_coach_update on public.app_state for update to authenticated
  using (team_key = public.my_team() and public.my_role() in ('admin', 'coach'))
  with check (team_key = public.my_team() and public.my_role() in ('admin', 'coach'));
grant select, insert, update on public.app_state to authenticated;

-- 3. Family view: team results + only their own player(s) -----------------------
create or replace function public.family_view() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  p public.profiles;
  d jsonb;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null or p.role not in ('family', 'admin', 'coach', 'assistant') then
    raise exception 'no access';
  end if;
  select data into d from public.app_state where team_key = p.team_key;
  if d is null then return null; end if;
  return jsonb_build_object(
    'settings',       d -> 'settings',
    'seasons',        coalesce(d -> 'seasons', '[]'::jsonb),
    'activeSeasonId', d -> 'activeSeasonId',
    'tournaments',    coalesce(d -> 'tournaments', '[]'::jsonb),
    'roster', coalesce((
      select jsonb_agg(r) from jsonb_array_elements(coalesce(d -> 'roster', '[]'::jsonb)) r
      where r ->> 'id' = any (p.player_ids)), '[]'::jsonb),
    'games', coalesce((
      select jsonb_agg(
        (g - 'stats' - 'log') || jsonb_build_object(
          -- only this family's player(s)
          'stats', coalesce((
            select jsonb_object_agg(e.key, e.value)
            from jsonb_each(coalesce(g -> 'stats', '{}'::jsonb)) e
            where e.key = any (p.player_ids)), '{}'::jsonb),
          -- whole-team totals per stat (no names)
          'teamTotals', coalesce((
            select jsonb_object_agg(t.k, t.v) from (
              select kv.key as k, sum((kv.value #>> '{}')::numeric) as v
              from jsonb_each(coalesce(g -> 'stats', '{}'::jsonb)) e, jsonb_each(e.value) kv
              where jsonb_typeof(kv.value) = 'number'
              group by kv.key) t), '{}'::jsonb),
          -- goal timeline (period only) for scoring by quarter
          'log', coalesce((
            select jsonb_agg(jsonb_build_object(
                     'period', l -> 'period',
                     'side', l -> 'side',
                     'statKey', case when l ->> 'statKey' = 'g' then 'g' end,
                     'oppGoal', l -> 'oppGoal'))
            from jsonb_array_elements(coalesce(g -> 'log', '[]'::jsonb)) l
            where (l ->> 'oppGoal') = 'true' or (l ->> 'side' = 'team' and l ->> 'statKey' = 'g')), '[]'::jsonb)
        ))
      from jsonb_array_elements(coalesce(d -> 'games', '[]'::jsonb)) g), '[]'::jsonb)
  );
end $$;
revoke execute on function public.family_view() from public, anon;
grant execute on function public.family_view() to authenticated;

-- 4. Change log: every stat change saved to the cloud, for the admin only -------
create table if not exists public.audit_log (
  id           bigserial primary key,
  team_key     text,
  at           timestamptz not null default now(),
  user_id      uuid,
  user_email   text,
  game_id      text,
  game_label   text,
  player_id    text,
  player_label text,
  field        text,
  old_value    numeric,
  new_value    numeric,
  note         text
);
alter table public.audit_log enable row level security;
drop policy if exists audit_admin_read on public.audit_log;
create policy audit_admin_read on public.audit_log for select to authenticated
  using (public.my_role() = 'admin');
grant select on public.audit_log to authenticated;
create index if not exists audit_log_at on public.audit_log (team_key, at desc);

create or replace function public.log_state_changes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  ng jsonb; og jsonb; nst jsonb; ost jsonb;
  gid text; glabel text; pid text; plabel text; k text; grp text;
  ov numeric; nv numeric; uemail text;
begin
  select email into uemail from public.profiles where id = auth.uid();
  if uemail is null and auth.uid() is null then uemail := '(no login - old app)'; end if;

  for ng in select value from jsonb_array_elements(coalesce(new.data -> 'games', '[]'::jsonb)) loop
    gid := ng ->> 'id';
    glabel := 'vs ' || coalesce(ng ->> 'oppName', '?') || ' (' || coalesce(ng ->> 'date', '') || ')';
    og := null;
    select value into og from jsonb_array_elements(coalesce(old.data -> 'games', '[]'::jsonb)) where value ->> 'id' = gid;
    if og is null then
      insert into public.audit_log (team_key, user_id, user_email, game_id, game_label, field, note)
      values (new.team_key, auth.uid(), uemail, gid, glabel, 'game', 'game created');
      continue;
    end if;

    -- score
    foreach k in array array['team', 'opp'] loop
      ov := coalesce((og -> 'scores' ->> k)::numeric, 0);
      nv := coalesce((ng -> 'scores' ->> k)::numeric, 0);
      if ov <> nv then
        insert into public.audit_log (team_key, user_id, user_email, game_id, game_label, field, old_value, new_value)
        values (new.team_key, auth.uid(), uemail, gid, glabel, 'score.' || k, ov, nv);
      end if;
    end loop;

    -- final / in progress
    if coalesce(og ->> 'status', '') <> coalesce(ng ->> 'status', '') then
      insert into public.audit_log (team_key, user_id, user_email, game_id, game_label, field, note)
      values (new.team_key, auth.uid(), uemail, gid, glabel, 'status',
              coalesce(og ->> 'status', '') || ' -> ' || coalesce(ng ->> 'status', ''));
    end if;

    -- team and opponent counters (clears, man-up, opponent SOG, ...)
    foreach grp in array array['teamStats', 'oppStats'] loop
      nst := coalesce(ng -> grp, '{}'::jsonb);
      ost := coalesce(og -> grp, '{}'::jsonb);
      for k in select jsonb_object_keys(nst) union select jsonb_object_keys(ost) loop
        if coalesce(jsonb_typeof(nst -> k), 'number') <> 'number' or coalesce(jsonb_typeof(ost -> k), 'number') <> 'number' then continue; end if;
        ov := coalesce((ost ->> k)::numeric, 0);
        nv := coalesce((nst ->> k)::numeric, 0);
        if ov <> nv then
          insert into public.audit_log (team_key, user_id, user_email, game_id, game_label, field, old_value, new_value)
          values (new.team_key, auth.uid(), uemail, gid, glabel,
                  case when grp = 'teamStats' then 'team.' else 'opp.' end || k, ov, nv);
        end if;
      end loop;
    end loop;

    -- player stats
    for pid in select jsonb_object_keys(coalesce(ng -> 'stats', '{}'::jsonb))
               union select jsonb_object_keys(coalesce(og -> 'stats', '{}'::jsonb)) loop
      nst := coalesce(ng -> 'stats' -> pid, '{}'::jsonb);
      ost := coalesce(og -> 'stats' -> pid, '{}'::jsonb);
      plabel := null;
      select '#' || coalesce(value ->> 'num', '?') || ' ' || coalesce(value ->> 'name', '')
        into plabel from jsonb_array_elements(coalesce(new.data -> 'roster', '[]'::jsonb)) where value ->> 'id' = pid;
      plabel := coalesce(plabel, pid);
      for k in select jsonb_object_keys(nst) union select jsonb_object_keys(ost) loop
        if coalesce(jsonb_typeof(nst -> k), 'number') <> 'number' or coalesce(jsonb_typeof(ost -> k), 'number') <> 'number' then continue; end if;
        ov := coalesce((ost ->> k)::numeric, 0);
        nv := coalesce((nst ->> k)::numeric, 0);
        if ov <> nv then
          insert into public.audit_log (team_key, user_id, user_email, game_id, game_label, player_id, player_label, field, old_value, new_value)
          values (new.team_key, auth.uid(), uemail, gid, glabel, pid, plabel, k, ov, nv);
        end if;
      end loop;
    end loop;
  end loop;

  -- deleted games
  for og in select value from jsonb_array_elements(coalesce(old.data -> 'games', '[]'::jsonb)) loop
    if not exists (select 1 from jsonb_array_elements(coalesce(new.data -> 'games', '[]'::jsonb)) x where x ->> 'id' = og ->> 'id') then
      insert into public.audit_log (team_key, user_id, user_email, game_id, game_label, field, note)
      values (new.team_key, auth.uid(), uemail, og ->> 'id',
              'vs ' || coalesce(og ->> 'oppName', '?') || ' (' || coalesce(og ->> 'date', '') || ')', 'game', 'game deleted');
    end if;
  end loop;
  return new;
end $$;
drop trigger if exists app_state_audit on public.app_state;
create trigger app_state_audit after update on public.app_state
  for each row when (old.data is distinct from new.data)
  execute function public.log_state_changes();
