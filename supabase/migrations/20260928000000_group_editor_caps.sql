-- Group puzzles get the AI editor; people are capped at five groups; a
-- helped (revealed) play scores nothing on the group board.
--
-- 1. The member who builds a group's daily crossword runs the editor on it
--    before publishing, so everyone plays the edited clues. That spends
--    the builder's `crossword_review` allowance in its own `group` bucket
--    (five a day on Premium — one per group, at most) rather than their
--    personal Mini/Midi/Mega puzzles. "*" keeps a build that sends no
--    bucket at the six personal puzzles it had, not six plus the groups'.
--
-- 2. Only one member builds. `group_claim_build` hands out a short-lived
--    claim on (group, day, kind); the others wait for the published
--    puzzle instead of generating — and paying for an edit — themselves.
--    A claim older than five minutes has been abandoned and can be taken.
--    There's still one puzzle per group per day (the unique key on
--    group_puzzles): no regenerating.
--
-- 3. A person belongs to at most five groups, owned or joined.
--
-- 4. A play with reveals counts for nothing on the standings. The app
--    already uploads such plays with zero points; the board ignores their
--    points regardless, so an older build can't score them either.

-- ---------------------------------------------------------------------
-- 1. The editor's allowance for group puzzles
-- ---------------------------------------------------------------------

update public.app_config
   set value = '{
     "free":    {"crossword_review": {"mini": 0, "midi": 0, "mega": 0, "group": 0, "*": 0}, "feature_clues": 30},
     "premium": {"crossword_review": {"mini": 2, "midi": 2, "mega": 2, "group": 5, "*": 6}, "feature_clues": 400}
   }', updated_at = now()
 where key = 'ai_daily_limits';

-- ---------------------------------------------------------------------
-- 2. Build claims
-- ---------------------------------------------------------------------

create table public.group_puzzle_builds (
  group_id    uuid not null references public.groups (id) on delete cascade,
  puzzle_date date not null,
  kind        text not null,
  user_id     uuid not null references auth.users (id) on delete cascade,
  claimed_at  timestamptz not null default now(),
  primary key (group_id, puzzle_date, kind)
);

alter table public.group_puzzle_builds enable row level security;
-- No policies: only group_claim_build touches it.

-- 'published' — the day's puzzle exists; fetch it.
-- 'claimed'   — the caller builds it (a new claim, or their own again).
-- 'building'  — someone else is; `by` is their name in the group.
create or replace function public.group_claim_build(p_group uuid, p_date date, p_kind text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user  uuid := auth.uid();
  v_claim public.group_puzzle_builds;
  v_name  text;
begin
  if v_user is null or not public.is_group_member(p_group) then
    raise exception 'not_a_member' using errcode = '42501';
  end if;
  if exists (select 1 from public.group_puzzles
              where group_id = p_group and puzzle_date = p_date and kind = p_kind) then
    return jsonb_build_object('status', 'published');
  end if;

  insert into public.group_puzzle_builds (group_id, puzzle_date, kind, user_id)
    values (p_group, p_date, p_kind, v_user)
    on conflict (group_id, puzzle_date, kind) do update
      set user_id = excluded.user_id, claimed_at = now()
      where group_puzzle_builds.user_id = excluded.user_id
         or group_puzzle_builds.claimed_at < now() - interval '5 minutes'
    returning * into v_claim;

  if v_claim.user_id = v_user then
    return jsonb_build_object('status', 'claimed');
  end if;

  select b.* into v_claim from public.group_puzzle_builds b
   where b.group_id = p_group and b.puzzle_date = p_date and b.kind = p_kind;
  select display_name into v_name from public.group_members
   where group_id = p_group and user_id = v_claim.user_id;
  return jsonb_build_object(
    'status', 'building',
    'by', coalesce(v_name, 'Someone'),
    'since', v_claim.claimed_at);
end;
$$;

revoke all on function public.group_claim_build(uuid, date, text) from public, anon;
grant execute on function public.group_claim_build(uuid, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Five groups each
-- ---------------------------------------------------------------------

create or replace function public.group_create(
  p_name           text,
  p_display_name   text,
  p_puzzle_kind    text default 'crossword',
  p_crossword_size text default 'midi'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_id   uuid;
  v_code text;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  if p_puzzle_kind not in ('crossword', 'hunt')
     or p_crossword_size not in ('mini', 'midi', 'mega') then
    raise exception 'invalid_puzzle_kind' using errcode = 'P0001';
  end if;
  if (select count(*) from public.group_members where user_id = v_user) >= 5 then
    raise exception 'too_many_groups' using errcode = 'P0001';
  end if;
  loop
    v_code := public.new_invite_code();
    exit when not exists (select 1 from public.groups where invite_code = v_code);
  end loop;
  insert into public.groups (name, owner_id, invite_code, puzzle_kind, crossword_size)
    values (trim(p_name), v_user, v_code, p_puzzle_kind, p_crossword_size)
    returning id into v_id;
  insert into public.group_members (group_id, user_id, role, display_name)
    values (v_id, v_user, 'owner', trim(p_display_name));
  return v_id;
end;
$$;

create or replace function public.group_join(p_code text, p_display_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_id   uuid;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  select id into v_id from public.groups where invite_code = upper(trim(p_code));
  if v_id is null then
    raise exception 'invalid_code' using errcode = 'P0001';
  end if;
  -- Rejoining is a no-op, whatever the counts say.
  if exists (select 1 from public.group_members where group_id = v_id and user_id = v_user) then
    return v_id;
  end if;
  if (select count(*) from public.group_members where user_id = v_user) >= 5 then
    raise exception 'too_many_groups' using errcode = 'P0001';
  end if;
  if (select count(*) from public.group_members where group_id = v_id) >= 12 then
    raise exception 'group_full' using errcode = 'P0001';
  end if;
  insert into public.group_members (group_id, user_id, role, display_name)
    values (v_id, v_user, 'member', trim(p_display_name))
    on conflict (group_id, user_id) do nothing;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Helped plays score nothing on the standings
-- ---------------------------------------------------------------------

create or replace function public.group_leaderboard(p_group uuid, p_since date default null)
returns table (
  rank         bigint,
  user_id      uuid,
  display_name text,
  points       bigint,
  puzzles      bigint,
  completed    bigint,
  is_me        boolean
)
language sql
security definer
stable
set search_path = public
as $$
  with totals as (
    select m.user_id,
           m.display_name,
           coalesce(sum(s.points) filter (where not s.aided), 0)::bigint           as points,
           count(s.puzzle_id)::bigint                                               as puzzles,
           count(s.puzzle_id) filter (where s.completed and not s.aided)::bigint    as completed
      from public.group_members m
      left join public.group_puzzles p
        on p.group_id = m.group_id
       and (p_since is null or p.puzzle_date >= p_since)
      left join public.group_scores s
        on s.puzzle_id = p.id and s.user_id = m.user_id
     where m.group_id = p_group
       and public.is_group_member(p_group)
     group by m.user_id, m.display_name
  )
  select rank() over (order by t.points desc, t.completed desc),
         t.user_id, t.display_name, t.points, t.puzzles, t.completed,
         t.user_id = auth.uid()
    from totals t
   order by 1, t.display_name;
$$;
