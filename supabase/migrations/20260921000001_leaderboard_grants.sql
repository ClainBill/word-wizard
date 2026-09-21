-- Functions are executable by PUBLIC unless revoked from PUBLIC itself;
-- revoking from anon alone left the board readable with the anon key.
revoke all on function public.leaderboard(text, integer) from public, anon;
revoke all on function public.my_leaderboard_rank(text) from public, anon;
grant execute on function public.leaderboard(text, integer) to authenticated, service_role;
grant execute on function public.my_leaderboard_rank(text) to authenticated, service_role;
