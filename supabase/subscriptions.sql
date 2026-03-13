create extension if not exists pgcrypto;

create table if not exists public.subscription_plans (
  id uuid primary key default gen_random_uuid(),
  plan_code text not null unique,
  title text not null,
  billing_source text not null default 'app_store',
  app_store_product_id text,
  is_active boolean not null default true,
  features jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists idx_subscription_plans_app_store_product
  on public.subscription_plans(app_store_product_id)
  where app_store_product_id is not null;

create table if not exists public.subscription_plan_limits (
  id uuid primary key default gen_random_uuid(),
  plan_code text not null references public.subscription_plans(plan_code) on delete cascade,
  feature_key text not null,
  limit_value bigint,
  is_unlimited boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint subscription_plan_limits_value_check check (limit_value is null or limit_value >= 0)
);

create unique index if not exists idx_subscription_plan_limits_unique
  on public.subscription_plan_limits(plan_code, feature_key);

create table if not exists public.user_subscriptions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid not null references auth.users(id) on delete cascade,
  plan_code text not null default 'free',
  source text not null default 'app_store',
  source_subscription_id text,
  source_transaction_id text,
  product_id text,
  status text not null default 'active',
  current_period_start timestamptz,
  current_period_end timestamptz,
  billing_anchor_day integer,
  cancel_at_period_end boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_subscriptions_anchor_day_check check (billing_anchor_day is null or (billing_anchor_day >= 1 and billing_anchor_day <= 31))
);

create unique index if not exists idx_user_subscriptions_unique_source
  on public.user_subscriptions(user_id, source, source_subscription_id)
  where source_subscription_id is not null;

create index if not exists idx_user_subscriptions_user_updated
  on public.user_subscriptions(user_id, updated_at desc);

create table if not exists public.app_store_receipts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid references auth.users(id) on delete set null,
  event_id text,
  external_transaction_id text,
  original_transaction_id text,
  product_id text,
  environment text,
  notification_type text,
  notification_subtype text not null default '',
  status text,
  expires_at timestamptz,
  signed_payload text,
  raw_payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create unique index if not exists idx_app_store_receipts_event_id
  on public.app_store_receipts(event_id)
  where event_id is not null;

create unique index if not exists idx_app_store_receipts_dedupe
  on public.app_store_receipts(external_transaction_id, notification_type, notification_subtype)
  where external_transaction_id is not null;

create index if not exists idx_app_store_receipts_user_received
  on public.app_store_receipts(user_id, received_at desc);

create table if not exists public.usage_ledger (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid not null references auth.users(id) on delete cascade,
  plan_code text not null,
  feature_key text not null,
  amount bigint not null default 0,
  unit text not null default 'count',
  source text,
  request_id text,
  session_id text,
  idempotency_key text,
  cycle_start timestamptz,
  cycle_end timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint usage_ledger_amount_check check (amount >= 0)
);

create unique index if not exists idx_usage_ledger_idempotency
  on public.usage_ledger(user_id, idempotency_key)
  where idempotency_key is not null;

create index if not exists idx_usage_ledger_user_feature
  on public.usage_ledger(user_id, feature_key, created_at desc);

create table if not exists public.usage_cycle_counters (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid not null references auth.users(id) on delete cascade,
  plan_code text not null,
  feature_key text not null,
  cycle_start timestamptz not null,
  cycle_end timestamptz not null,
  consumed bigint not null default 0,
  limit_value bigint,
  is_unlimited boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint usage_cycle_counters_consumed_check check (consumed >= 0),
  constraint usage_cycle_counters_limit_check check (limit_value is null or limit_value >= 0),
  constraint usage_cycle_counters_window_check check (cycle_end > cycle_start)
);

create unique index if not exists idx_usage_cycle_counters_unique
  on public.usage_cycle_counters(user_id, feature_key, cycle_start, cycle_end);

create index if not exists idx_usage_cycle_counters_user_window
  on public.usage_cycle_counters(user_id, cycle_start desc);

create or replace function public.subscriptions_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_subscription_plans_set_updated_at on public.subscription_plans;
create trigger trg_subscription_plans_set_updated_at
before update on public.subscription_plans
for each row execute function public.subscriptions_set_updated_at();

drop trigger if exists trg_subscription_plan_limits_set_updated_at on public.subscription_plan_limits;
create trigger trg_subscription_plan_limits_set_updated_at
before update on public.subscription_plan_limits
for each row execute function public.subscriptions_set_updated_at();

drop trigger if exists trg_user_subscriptions_set_updated_at on public.user_subscriptions;
create trigger trg_user_subscriptions_set_updated_at
before update on public.user_subscriptions
for each row execute function public.subscriptions_set_updated_at();

drop trigger if exists trg_usage_cycle_counters_set_updated_at on public.usage_cycle_counters;
create trigger trg_usage_cycle_counters_set_updated_at
before update on public.usage_cycle_counters
for each row execute function public.subscriptions_set_updated_at();

alter table public.subscription_plans enable row level security;
alter table public.subscription_plans force row level security;

alter table public.subscription_plan_limits enable row level security;
alter table public.subscription_plan_limits force row level security;

alter table public.user_subscriptions enable row level security;
alter table public.user_subscriptions force row level security;

alter table public.app_store_receipts enable row level security;
alter table public.app_store_receipts force row level security;

alter table public.usage_ledger enable row level security;
alter table public.usage_ledger force row level security;

alter table public.usage_cycle_counters enable row level security;
alter table public.usage_cycle_counters force row level security;

drop policy if exists subscription_plans_select_auth on public.subscription_plans;
create policy subscription_plans_select_auth
  on public.subscription_plans
  for select
  using (auth.role() in ('authenticated', 'service_role'));

drop policy if exists subscription_plan_limits_select_auth on public.subscription_plan_limits;
create policy subscription_plan_limits_select_auth
  on public.subscription_plan_limits
  for select
  using (auth.role() in ('authenticated', 'service_role'));

drop policy if exists user_subscriptions_select_own on public.user_subscriptions;
create policy user_subscriptions_select_own
  on public.user_subscriptions
  for select
  using (auth.uid() = user_id);

drop policy if exists user_subscriptions_insert_own on public.user_subscriptions;
create policy user_subscriptions_insert_own
  on public.user_subscriptions
  for insert
  with check (auth.uid() = user_id);

drop policy if exists user_subscriptions_update_own on public.user_subscriptions;
create policy user_subscriptions_update_own
  on public.user_subscriptions
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists usage_ledger_select_own on public.usage_ledger;
create policy usage_ledger_select_own
  on public.usage_ledger
  for select
  using (auth.uid() = user_id);

drop policy if exists usage_ledger_insert_own on public.usage_ledger;
create policy usage_ledger_insert_own
  on public.usage_ledger
  for insert
  with check (auth.uid() = user_id);

drop policy if exists usage_cycle_counters_select_own on public.usage_cycle_counters;
create policy usage_cycle_counters_select_own
  on public.usage_cycle_counters
  for select
  using (auth.uid() = user_id);

drop policy if exists usage_cycle_counters_insert_own on public.usage_cycle_counters;
create policy usage_cycle_counters_insert_own
  on public.usage_cycle_counters
  for insert
  with check (auth.uid() = user_id);

drop policy if exists usage_cycle_counters_update_own on public.usage_cycle_counters;
create policy usage_cycle_counters_update_own
  on public.usage_cycle_counters
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists app_store_receipts_select_own on public.app_store_receipts;
create policy app_store_receipts_select_own
  on public.app_store_receipts
  for select
  using (auth.uid() = user_id);

revoke all on table public.subscription_plans from anon;
revoke all on table public.subscription_plan_limits from anon;
revoke all on table public.user_subscriptions from anon;
revoke all on table public.app_store_receipts from anon;
revoke all on table public.usage_ledger from anon;
revoke all on table public.usage_cycle_counters from anon;

revoke all on table public.subscription_plans from authenticated;
revoke all on table public.subscription_plan_limits from authenticated;
revoke all on table public.user_subscriptions from authenticated;
revoke all on table public.app_store_receipts from authenticated;
revoke all on table public.usage_ledger from authenticated;
revoke all on table public.usage_cycle_counters from authenticated;

grant select on table public.subscription_plans to authenticated;
grant select on table public.subscription_plan_limits to authenticated;
grant select, insert, update on table public.user_subscriptions to authenticated;
grant select on table public.app_store_receipts to authenticated;
grant select, insert on table public.usage_ledger to authenticated;
grant select, insert, update on table public.usage_cycle_counters to authenticated;

insert into public.subscription_plans (plan_code, title, billing_source, app_store_product_id, is_active)
values
  ('free', 'Free', 'app_store', null, true),
  ('basic', 'Basic', 'app_store', 'com.drkynox.basic.monthly', true),
  ('pro', 'Pro', 'app_store', 'com.drkynox.pro.monthly', true)
on conflict (plan_code) do update set
  title = excluded.title,
  billing_source = excluded.billing_source,
  app_store_product_id = coalesce(excluded.app_store_product_id, public.subscription_plans.app_store_product_id),
  is_active = excluded.is_active,
  updated_at = now();

insert into public.subscription_plan_limits (plan_code, feature_key, limit_value, is_unlimited)
values
  ('free', 'case_starts', 30, false),
  ('free', 'tool_calls', 120, false),
  ('free', 'premium_analytics', 10, false),
  ('free', 'monthly_characters', 70000, false),
  ('basic', 'case_starts', 200, false),
  ('basic', 'tool_calls', 1000, false),
  ('basic', 'premium_analytics', 200, false),
  ('basic', 'monthly_characters', 500000, false),
  ('pro', 'case_starts', null, true),
  ('pro', 'tool_calls', null, true),
  ('pro', 'premium_analytics', null, true),
  ('pro', 'monthly_characters', null, true)
on conflict (plan_code, feature_key) do update set
  limit_value = excluded.limit_value,
  is_unlimited = excluded.is_unlimited,
  updated_at = now();
