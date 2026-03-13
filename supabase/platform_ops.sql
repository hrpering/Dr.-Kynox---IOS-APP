create extension if not exists pgcrypto;

-- 1) Daily challenge attempt tracking (global stats + user progress)
create table if not exists public.daily_challenge_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  challenge_id text not null,
  date_key date not null,
  attempt_count integer not null default 0 check (attempt_count >= 0),
  completed_count integer not null default 0 check (completed_count >= 0),
  best_score numeric(5,2),
  last_score numeric(5,2),
  last_session_id text,
  first_attempted_at timestamptz,
  last_attempted_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, challenge_id)
);

alter table public.daily_challenge_attempts
  add column if not exists metadata jsonb not null default '{}'::jsonb;

create index if not exists idx_dca_user_date
  on public.daily_challenge_attempts (user_id, date_key desc);

create index if not exists idx_dca_challenge_date
  on public.daily_challenge_attempts (challenge_id, date_key desc);

do $$
declare
  p record;
begin
  for p in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'daily_challenge_attempts'
  loop
    execute format('drop policy if exists %I on public.daily_challenge_attempts', p.policyname);
  end loop;
end $$;

alter table public.daily_challenge_attempts enable row level security;
alter table public.daily_challenge_attempts force row level security;

create policy "dca_select_own"
  on public.daily_challenge_attempts
  for select
  using (auth.uid() = user_id);

create policy "dca_insert_own"
  on public.daily_challenge_attempts
  for insert
  with check (auth.uid() = user_id);

create policy "dca_update_own"
  on public.daily_challenge_attempts
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "dca_delete_own"
  on public.daily_challenge_attempts
  for delete
  using (auth.uid() = user_id);

revoke all on table public.daily_challenge_attempts from anon;
revoke all on table public.daily_challenge_attempts from authenticated;
grant select, insert, update, delete on table public.daily_challenge_attempts to authenticated;

-- 2) App sessions (app-level session telemetry / single-session audit trail)
create table if not exists public.app_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null default 'ios',
  device_id text,
  app_version text,
  status text not null default 'active',
  session_token_hash text,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists idx_app_sessions_token_hash_unique
  on public.app_sessions (session_token_hash)
  where session_token_hash is not null;

create index if not exists idx_app_sessions_user_last_seen
  on public.app_sessions (user_id, last_seen_at desc);

do $$
declare
  p record;
begin
  for p in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'app_sessions'
  loop
    execute format('drop policy if exists %I on public.app_sessions', p.policyname);
  end loop;
end $$;

alter table public.app_sessions enable row level security;
alter table public.app_sessions force row level security;

create policy "app_sessions_select_own"
  on public.app_sessions
  for select
  using (auth.uid() = user_id);

create policy "app_sessions_insert_own"
  on public.app_sessions
  for insert
  with check (auth.uid() = user_id);

create policy "app_sessions_update_own"
  on public.app_sessions
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "app_sessions_delete_own"
  on public.app_sessions
  for delete
  using (auth.uid() = user_id);

revoke all on table public.app_sessions from anon;
revoke all on table public.app_sessions from authenticated;
grant select, insert, update, delete on table public.app_sessions to authenticated;

-- 3) Scoring jobs (scoring queue/audit)
create table if not exists public.scoring_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  case_session_id uuid references public.case_sessions(id) on delete cascade,
  status text not null default 'queued',
  model text,
  prompt_version text,
  input_messages integer not null default 0,
  input_chars integer not null default 0,
  latency_ms integer,
  result_score numeric(5,2),
  error_message text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_scoring_jobs_user_created
  on public.scoring_jobs (user_id, created_at desc);

create index if not exists idx_scoring_jobs_status_created
  on public.scoring_jobs (status, created_at desc);

do $$
declare
  p record;
begin
  for p in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'scoring_jobs'
  loop
    execute format('drop policy if exists %I on public.scoring_jobs', p.policyname);
  end loop;
end $$;

alter table public.scoring_jobs enable row level security;
alter table public.scoring_jobs force row level security;

create policy "scoring_jobs_select_own"
  on public.scoring_jobs
  for select
  using (auth.uid() = user_id);

create policy "scoring_jobs_insert_own"
  on public.scoring_jobs
  for insert
  with check (auth.uid() = user_id);

-- Kullanici status/sonuc alanlarini update etmesin; update service-role tarafinda kalir.
revoke all on table public.scoring_jobs from anon;
revoke all on table public.scoring_jobs from authenticated;
grant select, insert on table public.scoring_jobs to authenticated;

-- 4) Widget event logs
create table if not exists public.widget_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  event_type text not null,
  widget_kind text not null default 'home',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_widget_events_user_created
  on public.widget_events (user_id, created_at desc);

do $$
declare
  p record;
begin
  for p in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'widget_events'
  loop
    execute format('drop policy if exists %I on public.widget_events', p.policyname);
  end loop;
end $$;

alter table public.widget_events enable row level security;
alter table public.widget_events force row level security;

create policy "widget_events_select_own"
  on public.widget_events
  for select
  using (auth.uid() = user_id);

create policy "widget_events_insert_own"
  on public.widget_events
  for insert
  with check (auth.uid() = user_id);

revoke all on table public.widget_events from anon;
revoke all on table public.widget_events from authenticated;
grant select, insert on table public.widget_events to authenticated;

-- 5) GDPR requests
create table if not exists public.gdpr_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  request_type text not null,
  status text not null default 'open',
  note text,
  resolved_note text,
  requested_at timestamptz not null default now(),
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_gdpr_requests_user_created
  on public.gdpr_requests (user_id, created_at desc);

create index if not exists idx_gdpr_requests_status_created
  on public.gdpr_requests (status, created_at desc);

do $$
declare
  p record;
begin
  for p in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'gdpr_requests'
  loop
    execute format('drop policy if exists %I on public.gdpr_requests', p.policyname);
  end loop;
end $$;

alter table public.gdpr_requests enable row level security;
alter table public.gdpr_requests force row level security;

create policy "gdpr_requests_select_own"
  on public.gdpr_requests
  for select
  using (auth.uid() = user_id);

create policy "gdpr_requests_insert_own"
  on public.gdpr_requests
  for insert
  with check (auth.uid() = user_id);

create policy "gdpr_requests_update_own"
  on public.gdpr_requests
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

revoke all on table public.gdpr_requests from anon;
revoke all on table public.gdpr_requests from authenticated;
grant select, insert, update on table public.gdpr_requests to authenticated;

-- 6) Rate limit / security audit events (service role only)
create table if not exists public.rate_limit_audit_events (
  id uuid primary key default gen_random_uuid(),
  scope text not null,
  identity_hash text not null,
  endpoint text,
  decision text not null,
  request_count integer,
  window_ms integer,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_rate_limit_audit_scope_created
  on public.rate_limit_audit_events (scope, created_at desc);

create index if not exists idx_rate_limit_audit_identity_created
  on public.rate_limit_audit_events (identity_hash, created_at desc);

alter table public.rate_limit_audit_events enable row level security;
alter table public.rate_limit_audit_events force row level security;

revoke all on table public.rate_limit_audit_events from anon;
revoke all on table public.rate_limit_audit_events from authenticated;

-- 7) Suspicious activity events (service role only)
create table if not exists public.suspicious_activity_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  scope text not null,
  user_id uuid references auth.users(id) on delete set null,
  identity_hash text not null,
  endpoint text,
  request_count integer,
  threshold integer,
  window_ms integer,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_suspicious_activity_type_created
  on public.suspicious_activity_events (event_type, created_at desc);

create index if not exists idx_suspicious_activity_scope_created
  on public.suspicious_activity_events (scope, created_at desc);

create index if not exists idx_suspicious_activity_user_created
  on public.suspicious_activity_events (user_id, created_at desc);

alter table public.suspicious_activity_events enable row level security;
alter table public.suspicious_activity_events force row level security;

revoke all on table public.suspicious_activity_events from anon;
revoke all on table public.suspicious_activity_events from authenticated;

-- 8) Application error events (service role only)
create table if not exists public.app_error_events (
  id uuid primary key default gen_random_uuid(),
  request_id text,
  service text not null default 'app',
  code text not null default 'UNKNOWN',
  message text not null,
  status integer not null default 500,
  method text,
  path text,
  user_id uuid references auth.users(id) on delete set null,
  identity_hash text,
  latency_ms integer,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_app_error_events_created
  on public.app_error_events (created_at desc);

create index if not exists idx_app_error_events_status_created
  on public.app_error_events (status, created_at desc);

create index if not exists idx_app_error_events_service_created
  on public.app_error_events (service, created_at desc);

alter table public.app_error_events enable row level security;
alter table public.app_error_events force row level security;

revoke all on table public.app_error_events from anon;
revoke all on table public.app_error_events from authenticated;

-- 9) Global daily challenge aggregate view (backend/service role icin)
create or replace view public.daily_challenge_public_stats as
select
  challenge_id,
  date_key,
  count(*)::integer as attempted_users,
  count(best_score)::integer as participant_count,
  case
    when count(best_score) = 0 then null
    else round(avg(best_score)::numeric, 1)
  end as average_score,
  max(updated_at) as updated_at
from public.daily_challenge_attempts
group by challenge_id, date_key;

revoke all on table public.daily_challenge_public_stats from public;
revoke all on table public.daily_challenge_public_stats from anon;
revoke all on table public.daily_challenge_public_stats from authenticated;
grant select on table public.daily_challenge_public_stats to service_role;
