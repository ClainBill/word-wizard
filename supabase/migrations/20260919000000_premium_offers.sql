-- Premium offers (docs/Premium Offers Implementation Specification):
--   * entitlements learn the access state and the Founding Member marker;
--   * the Founding Member allocation — a real cap of 500 completed
--     purchases — lives here, with short reservations taken right before
--     the store sheet opens so the last place can't be sold twice;
--   * app_config gains the paywall/prompt knobs the app reads.
--
-- Nothing here grants an entitlement: RevenueCat remains the source of
-- truth, and founder sales are recorded from what it reports.

-- ---------------------------------------------------------------------
-- Entitlements: access state (spec §2.2) and founder cohort (spec §6.1).
-- ---------------------------------------------------------------------

alter table public.entitlements
  add column access         text not null default 'free'
    check (access in ('free', 'subscription', 'lifetime', 'grace_period', 'billing_retry', 'expired')),
  add column founder        boolean not null default false,
  add column founder_cohort text;

-- ---------------------------------------------------------------------
-- Founding Member campaign and inventory.
-- ---------------------------------------------------------------------

create table public.founder_campaigns (
  id          text primary key,            -- founder_cohort_2026
  product_id  text not null,               -- the store product that counts
  cap         integer not null check (cap > 0),
  active      boolean not null default true,
  version     integer not null default 1,  -- bumped on every change, for clients
  updated_at  timestamptz not null default now()
);

alter table public.founder_campaigns enable row level security;
-- No policies: service role only; the app reads through founder-status.

insert into public.founder_campaigns (id, product_id, cap)
  values ('founder_cohort_2026', 'premium_founder_lifetime_v1', 500);

-- One slot held for a few minutes while the store sheet is open.
create table public.founder_reservations (
  id           uuid primary key default gen_random_uuid(),
  campaign_id  text not null references public.founder_campaigns (id),
  user_id      uuid not null references auth.users (id) on delete cascade,
  state        text not null default 'reserved'
    check (state in ('reserved', 'converted', 'expired')),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null
);

create index founder_reservations_open
  on public.founder_reservations (campaign_id, expires_at)
  where state = 'reserved';

alter table public.founder_reservations enable row level security;
-- No policies: service role only.

-- Completed purchases of the founder product, one per store transaction,
-- as RevenueCat reports them. A refund keeps the row and sets refunded_at,
-- which returns the place to inventory while the campaign is active.
create table public.founder_sales (
  transaction_id  text primary key,
  campaign_id     text not null references public.founder_campaigns (id),
  user_id         uuid references auth.users (id) on delete set null,
  sold_at         timestamptz not null default now(),
  refunded_at     timestamptz
);

create index founder_sales_live on public.founder_sales (campaign_id) where refunded_at is null;

alter table public.founder_sales enable row level security;
-- No policies: service role only.

-- ---------------------------------------------------------------------
-- The status the app shows: sold, reserved, remaining. `remaining`
-- counts open reservations as taken so two people at the end of the
-- line don't both see "1 left".
-- ---------------------------------------------------------------------

create or replace function public.founder_status(p_campaign text default 'founder_cohort_2026')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c        public.founder_campaigns%rowtype;
  v_sold   integer;
  v_held   integer;
begin
  select * into c from public.founder_campaigns where id = p_campaign;
  if not found then
    return jsonb_build_object('active', false, 'cap', 0, 'sold', 0, 'reserved', 0, 'remaining', 0, 'version', 0);
  end if;
  select count(*) into v_sold from public.founder_sales
    where campaign_id = c.id and refunded_at is null;
  select count(*) into v_held from public.founder_reservations
    where campaign_id = c.id and state = 'reserved' and expires_at > now();
  return jsonb_build_object(
    'active', c.active and v_sold + v_held < c.cap,
    'cap', c.cap,
    'sold', v_sold,
    'reserved', v_held,
    'remaining', greatest(c.cap - v_sold - v_held, 0),
    'version', c.version,
    'last_updated_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Reserve one place for p_minutes. Atomic: the campaign row is locked
-- while counting, so concurrent reservations at the cap can't both
-- succeed (spec §9.1). Returns the reservation id, or null if sold out.
-- A user re-reserving replaces their own open reservation.
-- ---------------------------------------------------------------------

create or replace function public.founder_reserve(
  p_user     uuid,
  p_campaign text default 'founder_cohort_2026',
  p_minutes  integer default 10
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c      public.founder_campaigns%rowtype;
  v_sold integer;
  v_held integer;
  v_id   uuid;
begin
  select * into c from public.founder_campaigns where id = p_campaign for update;
  if not found or not c.active then
    return null;
  end if;
  -- Tidy: this user's earlier hold, and anyone's that has lapsed.
  update public.founder_reservations set state = 'expired'
    where campaign_id = c.id and state = 'reserved'
      and (expires_at <= now() or user_id = p_user);
  select count(*) into v_sold from public.founder_sales
    where campaign_id = c.id and refunded_at is null;
  select count(*) into v_held from public.founder_reservations
    where campaign_id = c.id and state = 'reserved';
  if v_sold + v_held >= c.cap then
    return null;
  end if;
  insert into public.founder_reservations (campaign_id, user_id, expires_at)
    values (c.id, p_user, now() + make_interval(mins => p_minutes))
    returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Record what RevenueCat says about one founder transaction. Idempotent
-- on the transaction id. Converts the buyer's open reservation. Closes
-- the campaign when the cap is reached; never reopens it (spec §1.4:
-- the cap is not silently expanded — a refund returns a place only while
-- the campaign is still active).
-- ---------------------------------------------------------------------

create or replace function public.founder_record_sale(
  p_user        uuid,
  p_transaction text,
  p_refunded    boolean,
  p_campaign    text default 'founder_cohort_2026'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c      public.founder_campaigns%rowtype;
  v_sold integer;
begin
  select * into c from public.founder_campaigns where id = p_campaign for update;
  if not found then
    return;
  end if;
  insert into public.founder_sales (transaction_id, campaign_id, user_id, refunded_at)
    values (p_transaction, c.id, p_user, case when p_refunded then now() end)
    on conflict (transaction_id) do update
      set user_id     = coalesce(excluded.user_id, public.founder_sales.user_id),
          refunded_at = case when p_refunded then coalesce(public.founder_sales.refunded_at, now()) end;
  if not p_refunded then
    update public.founder_reservations set state = 'converted'
      where campaign_id = c.id and user_id = p_user and state = 'reserved';
  end if;
  select count(*) into v_sold from public.founder_sales
    where campaign_id = c.id and refunded_at is null;
  if c.active and v_sold >= c.cap then
    update public.founder_campaigns
      set active = false, version = version + 1, updated_at = now()
      where id = c.id;
  end if;
end;
$$;

revoke all on function public.founder_status(text) from public, anon, authenticated;
revoke all on function public.founder_reserve(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.founder_record_sale(uuid, text, boolean, text) from public, anon, authenticated;
grant execute on function public.founder_status(text) to service_role;
grant execute on function public.founder_reserve(uuid, text, integer) to service_role;
grant execute on function public.founder_record_sale(uuid, text, boolean, text) to service_role;

-- ---------------------------------------------------------------------
-- Paywall and prompt knobs (spec §5.5). Read by founder-status and handed
-- to the app; conservative defaults are compiled into the app for when
-- this can't be reached. Never grants anything.
-- ---------------------------------------------------------------------

insert into public.app_config (key, value) values
  ('premium_offers', '{
     "founding_visible": true,
     "paywall_variant": "founder_first",
     "prompts": {
       "min_sessions": 3, "min_words": 5, "cooldown_days": 7,
       "dismissed_1_days": 7, "dismissed_2_days": 14, "dismissed_3_days": 30,
       "cancelled_purchase_hours": 24
     }
   }')
  on conflict (key) do nothing;
