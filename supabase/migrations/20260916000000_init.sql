-- Lexery backend, first migration.
--
-- Principles (docs/Launch Checklist.md §3):
--   * Private data is readable only by its owner; nothing about premium
--     status or AI allowance is writable by a user at all — those rows are
--     written by Edge Functions with the service role, after verifying
--     RevenueCat or spending real tokens.
--   * Every table has a uuid or natural key that is globally unique, so a
--     row can later be synced, exported or merged without renumbering.
--   * Changes are additive from here on: older app versions keep working
--     against a newer schema.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Profiles: one row per auth user, created by trigger.
-- ---------------------------------------------------------------------

create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles: owner reads"
  on public.profiles for select
  using (auth.uid() = id);

create policy "profiles: owner updates display name"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_touch
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- Entitlements: what RevenueCat says the user has bought. Written only
-- by the revenuecat-webhook / entitlement-refresh functions (service
-- role). A user can read their own row; no user can write one.
-- ---------------------------------------------------------------------

create table public.entitlements (
  user_id         uuid primary key references auth.users (id) on delete cascade,
  premium         boolean not null default false,
  product_id      text,
  store           text,                 -- app_store | play_store | ...
  expires_at      timestamptz,
  will_renew      boolean,
  billing_issue   boolean not null default false,
  rc_app_user_id  text,
  raw             jsonb,                -- the subscriber object it was derived from
  updated_at      timestamptz not null default now()
);

alter table public.entitlements enable row level security;

create policy "entitlements: owner reads"
  on public.entitlements for select
  using (auth.uid() = user_id);

create trigger entitlements_touch
  before update on public.entitlements
  for each row execute function public.touch_updated_at();

-- Every webhook delivery, keyed by RevenueCat's event id, so a redelivery
-- is a no-op rather than a second application.
create table public.revenuecat_events (
  id           text primary key,
  type         text not null,
  app_user_id  text,
  received_at  timestamptz not null default now(),
  payload      jsonb not null
);

alter table public.revenuecat_events enable row level security;
-- No policies: service role only.

-- ---------------------------------------------------------------------
-- App configuration the server reads at request time, so limits, models
-- and the kill switch change without a deploy. Readable by no client.
-- ---------------------------------------------------------------------

create table public.app_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.app_config enable row level security;
-- No policies: service role only.

insert into public.app_config (key, value) values
  -- The emergency switch: false refuses every AI request with
  -- `ai_disabled`, at no cost, until it is flipped back.
  ('ai_enabled', 'true'),
  -- Per-user daily caps by plan and request kind.
  ('ai_daily_limits', '{
     "free":    {"crossword_review": 1,  "feature_clues": 30},
     "premium": {"crossword_review": 12, "feature_clues": 400}
   }'),
  -- Global daily ceilings across all users: whichever trips first wins.
  -- cost is in micro-dollars (1 USD = 1,000,000).
  ('ai_global_daily_cap', '{"requests": 5000, "cost_micros": 20000000}'),
  -- Which model each kind may use. The server ignores anything the
  -- client says about models.
  ('ai_models', '{"crossword_review": "gpt-5-mini", "feature_clues": "gpt-5-mini"}'),
  -- Per-million-token prices for the cost ledger (USD input, output).
  ('ai_prices', '{"gpt-5": [1.25, 10.0], "gpt-5-mini": [0.25, 2.0], "gpt-5-nano": [0.05, 0.4]}');

-- ---------------------------------------------------------------------
-- AI requests and usage. One row per attempt, unique per
-- (user, kind, idempotency key) so a retry — a second tap, a lost
-- response — returns the stored answer instead of spending again.
-- ---------------------------------------------------------------------

create type public.ai_kind as enum ('crossword_review', 'feature_clues');
create type public.ai_status as enum ('pending', 'done', 'failed');

create table public.ai_requests (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users (id) on delete cascade,
  kind              public.ai_kind not null,
  idempotency_key   text not null,
  status            public.ai_status not null default 'pending',
  model             text,
  prompt_tokens     integer not null default 0,
  completion_tokens integer not null default 0,
  reasoning_tokens  integer not null default 0,
  cost_micros       bigint  not null default 0,
  response          jsonb,
  error             text,
  created_at        timestamptz not null default now(),
  completed_at      timestamptz,
  unique (user_id, kind, idempotency_key)
);

create index ai_requests_user_day on public.ai_requests (user_id, created_at);

alter table public.ai_requests enable row level security;

create policy "ai_requests: owner reads"
  on public.ai_requests for select
  using (auth.uid() = user_id);

create table public.ai_usage_daily (
  user_id  uuid not null references auth.users (id) on delete cascade,
  day      date not null,
  kind     public.ai_kind not null,
  requests integer not null default 0,
  tokens   integer not null default 0,
  primary key (user_id, day, kind)
);

alter table public.ai_usage_daily enable row level security;

create policy "ai_usage_daily: owner reads"
  on public.ai_usage_daily for select
  using (auth.uid() = user_id);

create table public.ai_global_daily (
  day         date primary key,
  requests    integer not null default 0,
  cost_micros bigint  not null default 0
);

alter table public.ai_global_daily enable row level security;
-- No policies: service role only.

-- A pending request older than this is treated as abandoned: the
-- function that made it died before completing, so a retry may proceed.
create or replace function public.ai_reserve(
  p_user_id uuid,
  p_kind    public.ai_kind,
  p_key     text
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
  v_limit := coalesce((v_limits -> (case when v_premium then 'premium' else 'free' end) ->> p_kind::text)::integer, 0);

  select coalesce(requests, 0) into v_used
    from public.ai_usage_daily
   where user_id = p_user_id and day = current_date and kind = p_kind;
  if coalesce(v_used, 0) >= v_limit then
    return jsonb_build_object(
      'allowed', false, 'reason', 'quota_exceeded',
      'limit', v_limit, 'premium', v_premium,
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
  insert into public.ai_requests (user_id, kind, idempotency_key, model)
    values (p_user_id, p_kind, p_key, v_model)
    returning id into v_id;
  insert into public.ai_usage_daily (user_id, day, kind, requests)
    values (p_user_id, current_date, p_kind, 1)
    on conflict (user_id, day, kind) do update set requests = ai_usage_daily.requests + 1;
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
   where user_id = v_req.user_id and day = v_req.created_at::date and kind = v_req.kind;
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
   where user_id = v_req.user_id and day = v_req.created_at::date and kind = v_req.kind;
  update public.ai_global_daily
     set requests = greatest(requests - 1, 0)
   where day = v_req.created_at::date;
end;
$$;

-- Only the service role (Edge Functions) may call these.
revoke all on function public.ai_reserve(uuid, public.ai_kind, text) from public, anon, authenticated;
revoke all on function public.ai_complete(uuid, jsonb, integer, integer, integer, bigint) from public, anon, authenticated;
revoke all on function public.ai_fail(uuid, text) from public, anon, authenticated;
grant execute on function public.ai_reserve(uuid, public.ai_kind, text) to service_role;
grant execute on function public.ai_complete(uuid, jsonb, integer, integer, integer, bigint) to service_role;
grant execute on function public.ai_fail(uuid, text) to service_role;

-- ---------------------------------------------------------------------
-- Feedback: bug reports and suggestions from the in-app form. Signed-in
-- or not. Attachments live in the private `feedback` storage bucket.
-- ---------------------------------------------------------------------

create table public.feedback (
  id          uuid primary key default gen_random_uuid(),
  client_id   text unique,                -- the app's report id, for idempotent resends
  user_id     uuid references auth.users (id) on delete set null,
  kind        text not null check (kind in ('bug', 'feature')),
  message     text not null check (length(message) <= 10000),
  link        text,
  email       text,
  app         jsonb,                      -- version, platform, screen
  attachments jsonb not null default '[]', -- [{name, mime, path, bytes}]
  status      text not null default 'new' check (status in ('new', 'seen', 'done')),
  created_at  timestamptz not null default now()
);

alter table public.feedback enable row level security;
-- No policies: written and read by service role only.

insert into storage.buckets (id, name, public)
  values ('feedback', 'feedback', false)
  on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- Account deletion. In-app deletion is immediate (delete-account
-- function, service role). Requests from the external web page — the
-- route Google requires — are recorded here for the developer to act on
-- after confirming the address.
-- ---------------------------------------------------------------------

create table public.deletion_requests (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,
  note       text,
  status     text not null default 'new' check (status in ('new', 'done', 'rejected')),
  created_at timestamptz not null default now()
);

alter table public.deletion_requests enable row level security;
-- No policies: service role only.
