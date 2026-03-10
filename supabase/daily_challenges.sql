create table if not exists public.daily_challenges (
  date_key date primary key,
  payload jsonb not null,
  expires_at timestamptz not null default (now() + interval '24 hours'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Eski/yanlis policy'leri temizle ve tek kaynak dogruyu yeniden kur.
do $$
declare
  p record;
begin
  for p in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'daily_challenges'
  loop
    execute format('drop policy if exists %I on public.daily_challenges', p.policyname);
  end loop;
end $$;

alter table public.daily_challenges
  add column if not exists expires_at timestamptz not null default (now() + interval '24 hours');

create index if not exists daily_challenges_expires_at_idx
  on public.daily_challenges (expires_at desc);

alter table public.daily_challenges enable row level security;
alter table public.daily_challenges force row level security;

-- Gunluk vaka herkes okuyabilir, yazma ise sadece service role/backend tarafinda.
create policy "daily_challenges_select_public"
  on public.daily_challenges
  for select
  using (true);

revoke all on table public.daily_challenges from anon;
revoke all on table public.daily_challenges from authenticated;
grant select on table public.daily_challenges to anon, authenticated;
