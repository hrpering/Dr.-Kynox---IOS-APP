create extension if not exists pgcrypto;

create table if not exists public.case_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id text not null,
  mode text not null,
  status text not null,
  started_at timestamptz,
  ended_at timestamptz,
  duration_min integer,
  message_count integer,
  difficulty text,
  case_context jsonb,
  transcript jsonb,
  score jsonb,
  text_runtime jsonb not null default '{}'::jsonb,
  usage_metrics jsonb not null default '{}'::jsonb,
  cost_metrics jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, session_id)
);

alter table public.case_sessions
  add column if not exists text_runtime jsonb not null default '{}'::jsonb,
  add column if not exists usage_metrics jsonb not null default '{}'::jsonb,
  add column if not exists cost_metrics jsonb not null default '{}'::jsonb;

-- Eski/yanlis policy'leri temizle ve tek kaynak dogruyu yeniden kur.
do $$
declare
  p record;
begin
  for p in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'case_sessions'
  loop
    execute format('drop policy if exists %I on public.case_sessions', p.policyname);
  end loop;
end $$;

alter table public.case_sessions enable row level security;
alter table public.case_sessions force row level security;

create policy "case_sessions_select_own"
  on public.case_sessions
  for select
  using (auth.uid() = user_id);

create policy "case_sessions_insert_own"
  on public.case_sessions
  for insert
  with check (auth.uid() = user_id);

create policy "case_sessions_update_own"
  on public.case_sessions
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "case_sessions_delete_own"
  on public.case_sessions
  for delete
  using (auth.uid() = user_id);

-- Kullanici dogrudan skor/manipulasyon yapamasin:
-- score, user_id ve session_id alanlari istemci tarafindan update edilemez.
create or replace function public.case_sessions_guard_sensitive_fields()
returns trigger
language plpgsql
as $$
begin
  if auth.role() in ('authenticated', 'anon') then
    if new.user_id is distinct from old.user_id
      or new.session_id is distinct from old.session_id
      or new.score is distinct from old.score
      or new.usage_metrics is distinct from old.usage_metrics
      or new.cost_metrics is distinct from old.cost_metrics then
      raise exception 'Bu alanlari guncelleme yetkin yok.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_case_sessions_guard_sensitive_fields on public.case_sessions;
create trigger trg_case_sessions_guard_sensitive_fields
before update on public.case_sessions
for each row
execute function public.case_sessions_guard_sensitive_fields();

create index if not exists idx_case_sessions_user_updated
  on public.case_sessions (user_id, updated_at desc);

create index if not exists idx_case_sessions_user_created
  on public.case_sessions (user_id, created_at desc);

create index if not exists idx_case_sessions_mode_created
  on public.case_sessions (mode, created_at desc);

-- Asgari yetki: istemci rollerinde sadece gerekli islemler acik.
revoke all on table public.case_sessions from anon;
revoke all on table public.case_sessions from authenticated;
grant select, insert, update, delete on table public.case_sessions to authenticated;
