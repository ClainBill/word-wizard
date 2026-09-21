-- Same tidy-up for the group functions (they refuse anonymous callers
-- inside, but there's no reason to let the anon key reach them).
revoke all on function public.group_create(text, text) from public, anon;
revoke all on function public.group_join(text, text) from public, anon;
revoke all on function public.group_publish_puzzle(uuid, date, text, text, bigint, jsonb, text[]) from public, anon;
