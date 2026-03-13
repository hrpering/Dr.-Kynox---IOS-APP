create extension if not exists pgcrypto;

create table if not exists public.user_feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  topic text not null,
  message text not null,
  status text not null default 'open',
  email text,
  full_name text,
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
    where schemaname = 'public' and tablename = 'user_feedback'
  loop
    execute format('drop policy if exists %I on public.user_feedback', p.policyname);
  end loop;
end $$;

alter table public.user_feedback enable row level security;
alter table public.user_feedback force row level security;

create policy "user_feedback_select_own"
  on public.user_feedback
  for select
  using (auth.uid() = user_id);

create policy "user_feedback_insert_own"
  on public.user_feedback
  for insert
  with check (auth.uid() = user_id);

create policy "user_feedback_update_own"
  on public.user_feedback
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "user_feedback_delete_own"
  on public.user_feedback
  for delete
  using (auth.uid() = user_id);

create index if not exists idx_user_feedback_user_created
  on public.user_feedback (user_id, created_at desc);

create index if not exists idx_user_feedback_status
  on public.user_feedback (status, created_at desc);

revoke all on table public.user_feedback from anon;
revoke all on table public.user_feedback from authenticated;
grant select, insert, update, delete on table public.user_feedback to authenticated;
