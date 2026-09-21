-- The board is readable by everyone — the app shows it signed out — so it
-- no longer returns user ids: a public name, a score and a rank is all
-- there is to see. Uploading a score still needs an account (RLS on
-- puzzle_scores), and my_leaderboard_rank stays authenticated-only since
-- it has nothing to say to anyone else.

drop function public.leaderboard(text, integer);

create function public.leaderboard(p_period text default 'week', p_limit integer default 50)
returns table (rank bigint, public_name text, score bigint, puzzles bigint, is_me boolean)
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
         p.public_name, t.score, t.puzzles,
         coalesce(t.user_id = auth.uid(), false) as is_me
  from totals t join public.profiles p on p.id = t.user_id
  order by rank
  limit greatest(1, least(p_limit, 200));
$$;

revoke all on function public.leaderboard(text, integer) from public;
grant execute on function public.leaderboard(text, integer) to anon, authenticated, service_role;
