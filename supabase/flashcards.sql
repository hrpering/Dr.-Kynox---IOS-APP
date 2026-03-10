create table if not exists public.flashcards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id text,
  source_id text,
  card_type text not null,
  specialty text,
  difficulty text,
  title text not null,
  front text not null,
  back text not null,
  tags jsonb not null default '[]'::jsonb,
  interval_days integer not null default 1,
  repetition_count integer not null default 0,
  ease_factor numeric(4,2) not null default 2.50,
  due_at timestamptz not null default now(),
  last_reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint flashcards_card_type_check check (
    card_type in (
      'diagnosis',
      'drug',
      'red_flag',
      'differential',
      'management',
      'lab',
      'imaging',
      'procedure',
      'concept'
    )
  ),
  constraint flashcards_interval_days_check check (interval_days between 1 and 365),
  constraint flashcards_repetition_count_check check (repetition_count between 0 and 100),
  constraint flashcards_ease_factor_check check (ease_factor between 1.30 and 3.00)
);

do $$
begin
  if not exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and indexname = 'idx_flashcards_user_due'
  ) then
    create index idx_flashcards_user_due
      on public.flashcards(user_id, due_at asc, updated_at desc);
  end if;
end $$;

create index if not exists idx_flashcards_user_specialty
  on public.flashcards(user_id, specialty, updated_at desc);

create index if not exists idx_flashcards_user_card_type
  on public.flashcards(user_id, card_type, updated_at desc);

create unique index if not exists idx_flashcards_user_source
  on public.flashcards(user_id, source_id)
  where source_id is not null;

create or replace function public.flashcards_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_flashcards_set_updated_at on public.flashcards;
create trigger trg_flashcards_set_updated_at
before update on public.flashcards
for each row execute function public.flashcards_set_updated_at();

alter table public.flashcards enable row level security;
alter table public.flashcards force row level security;

drop policy if exists flashcards_select_own on public.flashcards;
create policy flashcards_select_own
  on public.flashcards
  for select
  using (auth.uid() = user_id);

drop policy if exists flashcards_insert_own on public.flashcards;
create policy flashcards_insert_own
  on public.flashcards
  for insert
  with check (auth.uid() = user_id);

drop policy if exists flashcards_update_own on public.flashcards;
create policy flashcards_update_own
  on public.flashcards
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists flashcards_delete_own on public.flashcards;
create policy flashcards_delete_own
  on public.flashcards
  for delete
  using (auth.uid() = user_id);

revoke all on table public.flashcards from anon;
revoke all on table public.flashcards from authenticated;
grant select, insert, update, delete on table public.flashcards to authenticated;
