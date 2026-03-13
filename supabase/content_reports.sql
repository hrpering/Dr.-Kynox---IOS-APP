create extension if not exists pgcrypto;

create table if not exists public.content_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  case_session_id uuid references public.case_sessions(id) on delete set null,
  case_session_ref text,
  case_title text,
  mode text,
  difficulty text,
  specialty text,
  category text not null,
  details text not null,
  status text not null default 'open',
  metadata jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

do $$
declare
  p record;
begin
  for p in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'content_reports'
  loop
    execute format('drop policy if exists %I on public.content_reports', p.policyname);
  end loop;
end $$;

alter table public.content_reports enable row level security;
alter table public.content_reports force row level security;

create policy "content_reports_select_own"
  on public.content_reports
  for select
  using (auth.uid() = user_id);

create policy "content_reports_insert_own"
  on public.content_reports
  for insert
  with check (auth.uid() = user_id);

create policy "content_reports_update_own"
  on public.content_reports
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "content_reports_delete_own"
  on public.content_reports
  for delete
  using (auth.uid() = user_id);

create index if not exists idx_content_reports_user_created
  on public.content_reports (user_id, created_at desc);

create index if not exists idx_content_reports_status
  on public.content_reports (status, created_at desc);

revoke all on table public.content_reports from anon;
revoke all on table public.content_reports from authenticated;
grant select, insert, update, delete on table public.content_reports to authenticated;
