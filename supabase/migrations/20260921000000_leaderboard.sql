-- Global puzzle leaderboard.
--
-- Scores are computed on the device from each puzzle's own state
-- (lib/domain/games/scoring.dart) and uploaded per puzzle; the server
-- ranks people who opted in. Opting in means choosing a public name; the
-- name and the score are the only things shown. Nothing about a person's
-- vocabulary is involved.

alter table public.profiles
  add column public_name        text check (char_length(public_name) between 2 and 24),
  add column leaderboard_opt_in boolean not null default false;

-- Reserved and offensive names are the operator's problem to police;
-- uniqueness isn't enforced (two "Sam"s are fine — the rank is the point).

create table public.puzzle_scores (
  user_id     uuid not null references auth.users (id) on delete cascade,
  game        text not null check (game in ('crossword', 'hunt')),
  puzzle_key  text not null,               -- date + local puzzle id: one row per play
  played_on   date not null,
  difficulty  text not null default '',
  score       integer not null check (score >= 0 and score <= 100000),
  completed   boolean not null default false,
  words       integer not null default 0,
  active_ms   integer not null default 0,
  aided       boolean not null default false,
  updated_at  timestamptz not null default now(),
  primary key (user_id, game, puzzle_key)
);

create index puzzle_scores_by_day on public.puzzle_scores (played_on);

alter table public.puzzle_scores enable row level security;

create policy "scores: own rows"
  on public.puzzle_scores for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Anti-abuse: at most a handful of plays a day per game — the app
-- generates one daily puzzle per size plus "start new" retries.
create or replace function public.puzzle_scores_cap()
returns trigger
language plpgsql
as $$
begin
  if (select count(*) from public.puzzle_scores
        where user_id = new.user_id and game = new.game and played_on = new.played_on) >= 12 then
    raise exception 'too_many_plays' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger puzzle_scores_cap
  before insert on public.puzzle_scores
  for each row execute function public.puzzle_scores_cap();

-- ---------------------------------------------------------------------
-- The board. security definer so it can read everyone's rows, but it
-- returns only opted-in people, only their public name, and only sums.
-- p_period: 'week' (Monday to now, UTC) or 'all'.
-- ---------------------------------------------------------------------

create or replace function public.leaderboard(p_period text default 'week', p_limit integer default 50)
returns table (rank bigint, user_id uuid, public_name text, score bigint, puzzles bigint, is_me boolean)
language sql
security definer
stable
set search_path = public
as $$
  with since as (
    select case when p_period = 'week' then date_trunc('week', now())::date else date '1970-01-01' end as d
  ),
  totals as (
    select s.user_id, sum(s.score) as score, count(*) as puzzles
    from public.puzzle_scores s
    join public.profiles p on p.id = s.user_id
    where p.leaderboard_opt_in and p.public_name is not null
      and s.played_on >= (select d from since)
    group by s.user_id
  )
  select rank() over (order by t.score desc, t.puzzles asc, t.user_id) as rank,
         t.user_id, p.public_name, t.score, t.puzzles, t.user_id = auth.uid() as is_me
  from totals t join public.profiles p on p.id = t.user_id
  order by rank
  limit greatest(1, least(p_limit, 200));
$$;

-- Where the caller stands, even outside the top N. Null if not opted in
-- or nothing played.
create or replace function public.my_leaderboard_rank(p_period text default 'week')
returns table (rank bigint, score bigint, puzzles bigint, players bigint)
language sql
security definer
stable
set search_path = public
as $$
  with since as (
    select case when p_period = 'week' then date_trunc('week', now())::date else date '1970-01-01' end as d
  ),
  totals as (
    select s.user_id, sum(s.score) as score, count(*) as puzzles
    from public.puzzle_scores s
    join public.profiles p on p.id = s.user_id
    where p.leaderboard_opt_in and p.public_name is not null
      and s.played_on >= (select d from since)
    group by s.user_id
  ),
  ranked as (
    select user_id, score, puzzles,
           rank() over (order by score desc, puzzles asc, user_id) as rank,
           count(*) over () as players
    from totals
  )
  select rank, score, puzzles, players from ranked where user_id = auth.uid();
$$;

grant execute on function public.leaderboard(text, integer) to authenticated;
grant execute on function public.my_leaderboard_rank(text) to authenticated;
revoke all on function public.leaderboard(text, integer) from anon;
revoke all on function public.my_leaderboard_rank(text) from anon;
