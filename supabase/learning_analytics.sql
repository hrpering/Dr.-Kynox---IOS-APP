create extension if not exists pgcrypto;

create table if not exists public.case_session_messages (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid not null references auth.users(id) on delete cascade,
  case_session_id uuid not null references public.case_sessions(id) on delete cascade,
  session_id text not null,
  line_index integer not null default 0,
  source text not null,
  message text not null,
  timestamp_ms bigint,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint case_session_messages_source_check check (source in ('user', 'ai', 'system', 'tool')),
  constraint case_session_messages_line_index_check check (line_index >= 0)
);

create unique index if not exists idx_case_session_messages_unique_line
  on public.case_session_messages(case_session_id, line_index);

create index if not exists idx_case_session_messages_user_created
  on public.case_session_messages(user_id, created_at desc);

create table if not exists public.case_session_tool_results (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid not null references auth.users(id) on delete cascade,
  case_session_id uuid not null references public.case_sessions(id) on delete cascade,
  session_id text not null,
  tool_call_id text not null,
  tool_name text not null,
  tool_category text not null,
  title text,
  status text,
  summary text,
  raw_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint case_session_tool_results_tool_call_check check (char_length(tool_call_id) >= 1)
);

create unique index if not exists idx_case_session_tool_results_unique_call
  on public.case_session_tool_results(case_session_id, tool_call_id);

create index if not exists idx_case_session_tool_results_user_created
  on public.case_session_tool_results(user_id, created_at desc);

create table if not exists public.case_session_tool_metrics (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid not null references auth.users(id) on delete cascade,
  case_session_id uuid not null references public.case_sessions(id) on delete cascade,
  tool_result_id uuid not null references public.case_session_tool_results(id) on delete cascade,
  metric_key text not null,
  metric_label text,
  value_text text,
  unit text,
  status text,
  reference_range text,
  raw_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_case_session_tool_metrics_result
  on public.case_session_tool_metrics(tool_result_id, created_at asc);

create index if not exists idx_case_session_tool_metrics_user
  on public.case_session_tool_metrics(user_id, created_at desc);

create table if not exists public.weak_area_session_facts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid not null references auth.users(id) on delete cascade,
  case_session_id uuid not null references public.case_sessions(id) on delete cascade,
  session_id text not null,
  specialty text not null default '',
  difficulty text not null default '',
  dimension_key text not null,
  dimension_label text,
  score_pct numeric(5,2) not null,
  explanation text,
  recommendation text,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint weak_area_session_facts_score_check check (score_pct >= 0 and score_pct <= 100)
);

create unique index if not exists idx_weak_area_session_facts_unique
  on public.weak_area_session_facts(case_session_id, dimension_key, specialty, difficulty);

create index if not exists idx_weak_area_session_facts_user_date
  on public.weak_area_session_facts(user_id, occurred_at desc);

create table if not exists public.weak_area_daily_snapshots (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid not null references auth.users(id) on delete cascade,
  snapshot_date date not null,
  specialty text not null default '',
  difficulty text not null default '',
  dimension_key text not null,
  dimension_label text,
  user_avg_score numeric(5,2) not null,
  user_case_count integer not null default 0,
  global_avg_score numeric(5,2),
  global_case_count integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint weak_area_daily_user_avg_score_check check (user_avg_score >= 0 and user_avg_score <= 100),
  constraint weak_area_daily_user_case_count_check check (user_case_count >= 0)
);

create unique index if not exists idx_weak_area_daily_unique
  on public.weak_area_daily_snapshots(user_id, snapshot_date, specialty, difficulty, dimension_key);

create index if not exists idx_weak_area_daily_user_date
  on public.weak_area_daily_snapshots(user_id, snapshot_date desc);

create table if not exists public.flashcard_review_events (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid not null references auth.users(id) on delete cascade,
  flashcard_id uuid not null references public.flashcards(id) on delete cascade,
  session_id text,
  specialty text not null default '',
  card_type text not null default '',
  rating text not null,
  was_due boolean not null default false,
  interval_days_before integer,
  interval_days_after integer,
  ease_factor_before numeric(4,2),
  ease_factor_after numeric(4,2),
  reviewed_at timestamptz not null default now(),
  idempotency_key text,
  created_at timestamptz not null default now(),
  constraint flashcard_review_events_rating_check check (rating in ('again', 'hard', 'easy')),
  constraint flashcard_review_events_interval_before_check check (interval_days_before is null or interval_days_before >= 0),
  constraint flashcard_review_events_interval_after_check check (interval_days_after is null or interval_days_after >= 0)
);

create unique index if not exists idx_flashcard_review_events_idempotency
  on public.flashcard_review_events(user_id, idempotency_key)
  where idempotency_key is not null;

create index if not exists idx_flashcard_review_events_user_date
  on public.flashcard_review_events(user_id, reviewed_at desc);

create table if not exists public.flashcard_daily_performance (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid not null references auth.users(id) on delete cascade,
  snapshot_date date not null,
  specialty text not null default '',
  card_type text not null default '',
  review_count integer not null default 0,
  success_count integer not null default 0,
  again_count integer not null default 0,
  hard_count integer not null default 0,
  easy_count integer not null default 0,
  retention_rate numeric(5,2) not null default 0,
  avg_interval_days numeric(8,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint flashcard_daily_performance_review_count_check check (review_count >= 0),
  constraint flashcard_daily_performance_success_count_check check (success_count >= 0),
  constraint flashcard_daily_performance_retention_rate_check check (retention_rate >= 0 and retention_rate <= 100)
);

create unique index if not exists idx_flashcard_daily_performance_unique
  on public.flashcard_daily_performance(user_id, snapshot_date, specialty, card_type);

create index if not exists idx_flashcard_daily_performance_user_date
  on public.flashcard_daily_performance(user_id, snapshot_date desc);

create or replace function public.set_updated_at_now()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_weak_area_daily_snapshots_set_updated_at on public.weak_area_daily_snapshots;
create trigger trg_weak_area_daily_snapshots_set_updated_at
before update on public.weak_area_daily_snapshots
for each row execute function public.set_updated_at_now();

drop trigger if exists trg_flashcard_daily_performance_set_updated_at on public.flashcard_daily_performance;
create trigger trg_flashcard_daily_performance_set_updated_at
before update on public.flashcard_daily_performance
for each row execute function public.set_updated_at_now();

alter table public.case_session_messages enable row level security;
alter table public.case_session_messages force row level security;

drop policy if exists case_session_messages_select_own on public.case_session_messages;
create policy case_session_messages_select_own
  on public.case_session_messages
  for select
  using (auth.uid() = user_id);

drop policy if exists case_session_messages_insert_own on public.case_session_messages;
create policy case_session_messages_insert_own
  on public.case_session_messages
  for insert
  with check (auth.uid() = user_id);

drop policy if exists case_session_messages_update_own on public.case_session_messages;
create policy case_session_messages_update_own
  on public.case_session_messages
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists case_session_messages_delete_own on public.case_session_messages;
create policy case_session_messages_delete_own
  on public.case_session_messages
  for delete
  using (auth.uid() = user_id);

alter table public.case_session_tool_results enable row level security;
alter table public.case_session_tool_results force row level security;

drop policy if exists case_session_tool_results_select_own on public.case_session_tool_results;
create policy case_session_tool_results_select_own
  on public.case_session_tool_results
  for select
  using (auth.uid() = user_id);

drop policy if exists case_session_tool_results_insert_own on public.case_session_tool_results;
create policy case_session_tool_results_insert_own
  on public.case_session_tool_results
  for insert
  with check (auth.uid() = user_id);

drop policy if exists case_session_tool_results_update_own on public.case_session_tool_results;
create policy case_session_tool_results_update_own
  on public.case_session_tool_results
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists case_session_tool_results_delete_own on public.case_session_tool_results;
create policy case_session_tool_results_delete_own
  on public.case_session_tool_results
  for delete
  using (auth.uid() = user_id);

alter table public.case_session_tool_metrics enable row level security;
alter table public.case_session_tool_metrics force row level security;

drop policy if exists case_session_tool_metrics_select_own on public.case_session_tool_metrics;
create policy case_session_tool_metrics_select_own
  on public.case_session_tool_metrics
  for select
  using (auth.uid() = user_id);

drop policy if exists case_session_tool_metrics_insert_own on public.case_session_tool_metrics;
create policy case_session_tool_metrics_insert_own
  on public.case_session_tool_metrics
  for insert
  with check (auth.uid() = user_id);

drop policy if exists case_session_tool_metrics_update_own on public.case_session_tool_metrics;
create policy case_session_tool_metrics_update_own
  on public.case_session_tool_metrics
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists case_session_tool_metrics_delete_own on public.case_session_tool_metrics;
create policy case_session_tool_metrics_delete_own
  on public.case_session_tool_metrics
  for delete
  using (auth.uid() = user_id);

alter table public.weak_area_session_facts enable row level security;
alter table public.weak_area_session_facts force row level security;

drop policy if exists weak_area_session_facts_select_own on public.weak_area_session_facts;
create policy weak_area_session_facts_select_own
  on public.weak_area_session_facts
  for select
  using (auth.uid() = user_id);

drop policy if exists weak_area_session_facts_insert_own on public.weak_area_session_facts;
create policy weak_area_session_facts_insert_own
  on public.weak_area_session_facts
  for insert
  with check (auth.uid() = user_id);

drop policy if exists weak_area_session_facts_update_own on public.weak_area_session_facts;
create policy weak_area_session_facts_update_own
  on public.weak_area_session_facts
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists weak_area_session_facts_delete_own on public.weak_area_session_facts;
create policy weak_area_session_facts_delete_own
  on public.weak_area_session_facts
  for delete
  using (auth.uid() = user_id);

alter table public.weak_area_daily_snapshots enable row level security;
alter table public.weak_area_daily_snapshots force row level security;

drop policy if exists weak_area_daily_snapshots_select_own on public.weak_area_daily_snapshots;
create policy weak_area_daily_snapshots_select_own
  on public.weak_area_daily_snapshots
  for select
  using (auth.uid() = user_id);

drop policy if exists weak_area_daily_snapshots_insert_own on public.weak_area_daily_snapshots;
create policy weak_area_daily_snapshots_insert_own
  on public.weak_area_daily_snapshots
  for insert
  with check (auth.uid() = user_id);

drop policy if exists weak_area_daily_snapshots_update_own on public.weak_area_daily_snapshots;
create policy weak_area_daily_snapshots_update_own
  on public.weak_area_daily_snapshots
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists weak_area_daily_snapshots_delete_own on public.weak_area_daily_snapshots;
create policy weak_area_daily_snapshots_delete_own
  on public.weak_area_daily_snapshots
  for delete
  using (auth.uid() = user_id);

alter table public.flashcard_review_events enable row level security;
alter table public.flashcard_review_events force row level security;

drop policy if exists flashcard_review_events_select_own on public.flashcard_review_events;
create policy flashcard_review_events_select_own
  on public.flashcard_review_events
  for select
  using (auth.uid() = user_id);

drop policy if exists flashcard_review_events_insert_own on public.flashcard_review_events;
create policy flashcard_review_events_insert_own
  on public.flashcard_review_events
  for insert
  with check (auth.uid() = user_id);

drop policy if exists flashcard_review_events_update_own on public.flashcard_review_events;
create policy flashcard_review_events_update_own
  on public.flashcard_review_events
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists flashcard_review_events_delete_own on public.flashcard_review_events;
create policy flashcard_review_events_delete_own
  on public.flashcard_review_events
  for delete
  using (auth.uid() = user_id);

alter table public.flashcard_daily_performance enable row level security;
alter table public.flashcard_daily_performance force row level security;

drop policy if exists flashcard_daily_performance_select_own on public.flashcard_daily_performance;
create policy flashcard_daily_performance_select_own
  on public.flashcard_daily_performance
  for select
  using (auth.uid() = user_id);

drop policy if exists flashcard_daily_performance_insert_own on public.flashcard_daily_performance;
create policy flashcard_daily_performance_insert_own
  on public.flashcard_daily_performance
  for insert
  with check (auth.uid() = user_id);

drop policy if exists flashcard_daily_performance_update_own on public.flashcard_daily_performance;
create policy flashcard_daily_performance_update_own
  on public.flashcard_daily_performance
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists flashcard_daily_performance_delete_own on public.flashcard_daily_performance;
create policy flashcard_daily_performance_delete_own
  on public.flashcard_daily_performance
  for delete
  using (auth.uid() = user_id);

revoke all on table public.case_session_messages from anon;
revoke all on table public.case_session_tool_results from anon;
revoke all on table public.case_session_tool_metrics from anon;
revoke all on table public.weak_area_session_facts from anon;
revoke all on table public.weak_area_daily_snapshots from anon;
revoke all on table public.flashcard_review_events from anon;
revoke all on table public.flashcard_daily_performance from anon;

revoke all on table public.case_session_messages from authenticated;
revoke all on table public.case_session_tool_results from authenticated;
revoke all on table public.case_session_tool_metrics from authenticated;
revoke all on table public.weak_area_session_facts from authenticated;
revoke all on table public.weak_area_daily_snapshots from authenticated;
revoke all on table public.flashcard_review_events from authenticated;
revoke all on table public.flashcard_daily_performance from authenticated;

grant select, insert, update, delete on table public.case_session_messages to authenticated;
grant select, insert, update, delete on table public.case_session_tool_results to authenticated;
grant select, insert, update, delete on table public.case_session_tool_metrics to authenticated;
grant select, insert, update, delete on table public.weak_area_session_facts to authenticated;
grant select, insert, update, delete on table public.weak_area_daily_snapshots to authenticated;
grant select, insert, update, delete on table public.flashcard_review_events to authenticated;
grant select, insert, update, delete on table public.flashcard_daily_performance to authenticated;
