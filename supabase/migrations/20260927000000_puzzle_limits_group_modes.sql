-- Puzzle-based AI limits, group puzzle modes, and a group leaderboard.
--
-- 1. The AI editor's allowance is counted in puzzles, not calls: two
--    AI-edited puzzles a day at each crossword size. `ai_usage_daily` and
--    `ai_requests` gain a `bucket` (the size) and `ai_reserve` takes it.
--    A limit in `ai_daily_limits` may now be a number (one allowance for
--    the kind) or an object of per-bucket allowances. A caller that sends
--    no bucket — an app build from before this change — is held to the
--    object's "*" entry when it has one, else to the object's total, and
--    measured against everything spent on the kind that day.
--
-- 2. A group plays either crosswords (at a size chosen with the group) or
--    Word Hunt boards. Chosen at creation; `group_publish_puzzle` refuses
--    a puzzle of any other kind or size, so every member plays the same
--    thing whichever build they're on.
--
-- 3. Group scores carry the play's leaderboard points (computed on the
--    device, lib/domain/games/scoring.dart, as for the global board), and
--    `group_leaderboard` sums them per member — this week or all time.

-- ---------------------------------------------------------------------
-- 1. AI allowances per puzzle
-- ---------------------------------------------------------------------

alter table public.ai_requests    add column bucket text not null default '';
alter table public.ai_usage_daily add column bucket text not null default '';

alter table public.ai_usage_daily drop constraint ai_usage_daily_pkey;
alter table public.ai_usage_daily add primary key (user_id, day, kind, bucket);

update public.app_config
   set value = '{
     "free":    {"crossword_review": {"mini": 0, "midi": 0, "mega": 0}, "feature_clues": 30},
     "premium": {"crossword_review": {"mini": 2, "midi": 2, "mega": 2}, "feature_clues": 400}
   }', updated_at = now()
 where key = 'ai_daily_limits';

drop function public.ai_reserve(uuid, public.ai_kind, text);

create or replace function public.ai_reserve(
  p_user_id uuid,
  p_kind    public.ai_kind,
  p_key     text,
  p_bucket  text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_enabled   boolean;
  v_premium   boolean;
  v_limits    jsonb;
  v_entry     jsonb;
  v_bucket    text := coalesce(p_bucket, '');
  v_limit     integer;
  v_used      integer;
  v_global    jsonb;
  v_today     public.ai_global_daily%rowtype;
  v_existing  public.ai_requests%rowtype;
  v_model     text;
  v_id        uuid;
begin
  select (value)::boolean into v_enabled from public.app_config where key = 'ai_enabled';
  if not coalesce(v_enabled, false) then
    return jsonb_build_object('allowed', false, 'reason', 'ai_disabled');
  end if;

  -- Idempotency: the same key again gets the same answer, free.
  select * into v_existing
    from public.ai_requests
   where user_id = p_user_id and kind = p_kind and idempotency_key = p_key;
  if found then
    if v_existing.status = 'done' then
      return jsonb_build_object(
        'allowed', true, 'cached', true, 'request_id', v_existing.id,
        'response', v_existing.response, 'model', v_existing.model,
        'usage', jsonb_build_object(
          'prompt_tokens', v_existing.prompt_tokens,
          'completion_tokens', v_existing.completion_tokens,
          'reasoning_tokens', v_existing.reasoning_tokens));
    elsif v_existing.status = 'pending' and v_existing.created_at > now() - interval '10 minutes' then
      return jsonb_build_object('allowed', false, 'reason', 'in_progress');
    else
      -- failed, or abandoned: let it be retried under the same key.
      delete from public.ai_requests where id = v_existing.id;
    end if;
  end if;

  select coalesce(e.premium and (e.expires_at is null or e.expires_at > now()), false)
    into v_premium
    from public.entitlements e where e.user_id = p_user_id;
  v_premium := coalesce(v_premium, false);

  select value into v_limits from public.app_config where key = 'ai_daily_limits';
  v_entry := v_limits -> (case when v_premium then 'premium' else 'free' end) -> p_kind::text;

  if jsonb_typeof(v_entry) = 'object' then
    if v_bucket <> '' and v_entry ? v_bucket then
      v_limit := coalesce((v_entry ->> v_bucket)::integer, 0);
      select coalesce(sum(requests), 0) into v_used
        from public.ai_usage_daily
       where user_id = p_user_id and day = current_date and kind = p_kind and bucket = v_bucket;
    else
      -- No bucket, or one the config doesn't name: the "*" allowance if
      -- there is one, else the kind's total, measured against everything
      -- spent on the kind today.
      if v_entry ? '*' then
        v_limit := coalesce((v_entry ->> '*')::integer, 0);
      else
        select coalesce(sum(value::integer), 0) into v_limit from jsonb_each_text(v_entry);
      end if;
      select coalesce(sum(requests), 0) into v_used
        from public.ai_usage_daily
       where user_id = p_user_id and day = current_date and kind = p_kind;
    end if;
  else
    v_limit := coalesce((v_entry #>> '{}')::integer, 0);
    select coalesce(sum(requests), 0) into v_used
      from public.ai_usage_daily
     where user_id = p_user_id and day = current_date and kind = p_kind;
  end if;

  if coalesce(v_used, 0) >= v_limit then
    return jsonb_build_object(
      'allowed', false, 'reason', 'quota_exceeded',
      'limit', v_limit, 'premium', v_premium, 'bucket', v_bucket,
      'resets_at', (current_date + 1)::timestamptz);
  end if;

  select value into v_global from public.app_config where key = 'ai_global_daily_cap';
  insert into public.ai_global_daily (day) values (current_date) on conflict do nothing;
  select * into v_today from public.ai_global_daily where day = current_date for update;
  if v_today.requests >= coalesce((v_global ->> 'requests')::integer, 0)
     or v_today.cost_micros >= coalesce((v_global ->> 'cost_micros')::bigint, 0) then
    return jsonb_build_object('allowed', false, 'reason', 'global_cap');
  end if;

  select value ->> p_kind::text into v_model from public.app_config where key = 'ai_models';

  -- Reserve: the request counts against the user and the global tally
  -- now, before the provider call, so two concurrent calls can't both
  -- slip under the limit. A failure is credited back by ai_fail.
  insert into public.ai_requests (user_id, kind, idempotency_key, model, bucket)
    values (p_user_id, p_kind, p_key, v_model, v_bucket)
    returning id into v_id;
  insert into public.ai_usage_daily (user_id, day, kind, bucket, requests)
    values (p_user_id, current_date, p_kind, v_bucket, 1)
    on conflict (user_id, day, kind, bucket) do update set requests = ai_usage_daily.requests + 1;
  update public.ai_global_daily set requests = requests + 1 where day = current_date;

  return jsonb_build_object(
    'allowed', true, 'cached', false, 'request_id', v_id,
    'model', v_model, 'premium', v_premium,
    'remaining', v_limit - coalesce(v_used, 0) - 1);
end;
$$;

create or replace function public.ai_complete(
  p_request_id        uuid,
  p_response          jsonb,
  p_prompt_tokens     integer,
  p_completion_tokens integer,
  p_reasoning_tokens  integer,
  p_cost_micros       bigint
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.ai_requests%rowtype;
begin
  update public.ai_requests
     set status = 'done', response = p_response,
         prompt_tokens = p_prompt_tokens, completion_tokens = p_completion_tokens,
         reasoning_tokens = p_reasoning_tokens, cost_micros = p_cost_micros,
         completed_at = now()
   where id = p_request_id
   returning * into v_req;
  if not found then return; end if;
  update public.ai_usage_daily
     set tokens = tokens + p_prompt_tokens + p_completion_tokens
   where user_id = v_req.user_id and day = v_req.created_at::date
     and kind = v_req.kind and bucket = v_req.bucket;
  update public.ai_global_daily
     set cost_micros = cost_micros + p_cost_micros
   where day = v_req.created_at::date;
end;
$$;

create or replace function public.ai_fail(p_request_id uuid, p_error text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.ai_requests%rowtype;
begin
  update public.ai_requests
     set status = 'failed', error = left(p_error, 500), completed_at = now()
   where id = p_request_id
   returning * into v_req;
  if not found then return; end if;
  -- A provider failure costs the user nothing.
  update public.ai_usage_daily
     set requests = greatest(requests - 1, 0)
   where user_id = v_req.user_id and day = v_req.created_at::date
     and kind = v_req.kind and bucket = v_req.bucket;
  update public.ai_global_daily
     set requests = greatest(requests - 1, 0)
   where day = v_req.created_at::date;
end;
$$;

revoke all on function public.ai_reserve(uuid, public.ai_kind, text, text) from public, anon, authenticated;
grant execute on function public.ai_reserve(uuid, public.ai_kind, text, text) to service_role;

-- ---------------------------------------------------------------------
-- 2. What a group plays
-- ---------------------------------------------------------------------

alter table public.groups
  add column puzzle_kind    text not null default 'crossword'
    check (puzzle_kind in ('crossword', 'hunt')),
  add column crossword_size text not null default 'midi'
    check (crossword_size in ('mini', 'midi', 'mega'));

drop function public.group_create(text, text);

-- Creates a group and seats the caller as its owner. Returns the group id.
-- What it plays is fixed here: crosswords at one size, or Word Hunts.
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
  if (select count(*) from public.groups where owner_id = v_user) >= 10 then
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

-- The mode is chosen once. The owner may still rename the group, but not
-- switch what it plays under members mid-week.
create or replace function public.groups_mode_is_fixed()
returns trigger
language plpgsql
as $$
begin
  if new.puzzle_kind is distinct from old.puzzle_kind
     or new.crossword_size is distinct from old.crossword_size then
    raise exception 'puzzle_kind_fixed' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger groups_mode_is_fixed
  before update of puzzle_kind, crossword_size on public.groups
  for each row execute function public.groups_mode_is_fixed();

-- First writer wins, as before — and only a puzzle of the group's own
-- kind and size is accepted.
create or replace function public.group_publish_puzzle(
  p_group      uuid,
  p_date       date,
  p_kind       text,
  p_difficulty text,
  p_seed       bigint,
  p_grid       jsonb,
  p_anchors    text[]
)
returns public.group_puzzles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user  uuid := auth.uid();
  v_group public.groups;
  v_row   public.group_puzzles;
begin
  if v_user is null or not public.is_group_member(p_group) then
    raise exception 'not_a_member' using errcode = '42501';
  end if;
  select * into v_group from public.groups where id = p_group;
  if p_kind <> v_group.puzzle_kind
     or (p_kind = 'crossword' and p_difficulty <> v_group.crossword_size) then
    raise exception 'wrong_puzzle_kind' using errcode = 'P0001';
  end if;
  insert into public.group_puzzles (group_id, puzzle_date, kind, difficulty, seed, grid, anchors, generated_by)
    values (p_group, p_date, p_kind, p_difficulty, p_seed, p_grid, p_anchors, v_user)
    on conflict (group_id, puzzle_date, kind) do nothing
    returning * into v_row;
  if v_row.id is null then
    select * into v_row from public.group_puzzles
      where group_id = p_group and puzzle_date = p_date and kind = p_kind;
  end if;
  return v_row;
end;
$$;

grant execute on function public.group_create(text, text, text, text) to authenticated;
revoke all on function public.group_create(text, text, text, text) from public, anon;

-- ---------------------------------------------------------------------
-- 3. The group leaderboard
-- ---------------------------------------------------------------------

alter table public.group_scores
  add column points integer not null default 0 check (points between 0 and 100000);

-- Every current member with their summed points over the group's puzzles
-- since p_since (all time when null), ranked. Members who haven't played
-- are listed with nothing, so the board shows the whole group.
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
           coalesce(sum(s.points), 0)::bigint                  as points,
           count(s.puzzle_id)::bigint                           as puzzles,
           count(s.puzzle_id) filter (where s.completed)::bigint as completed
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

revoke all on function public.group_leaderboard(uuid, date) from public, anon;
grant execute on function public.group_leaderboard(uuid, date) to authenticated;
