alter table if exists public.case_sessions
  add column if not exists text_runtime jsonb not null default '{}'::jsonb;
