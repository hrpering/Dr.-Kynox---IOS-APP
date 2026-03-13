create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  first_name text,
  last_name text,
  full_name text,
  phone_number text,
  preferred_language_code text default 'tr',
  country_code text default '',
  language_source text default 'default',
  ai_enabled boolean not null default true,
  ai_disabled_reason text,
  ai_disabled_at timestamptz,
  marketing_opt_in boolean default false,
  onboarding_completed boolean default false,
  age_range text,
  role text,
  goals jsonb default '[]'::jsonb,
  interest_areas jsonb default '[]'::jsonb,
  learning_level text,
  updated_at timestamptz default now()
);

-- Eski/yanlis policy'leri temizle ve tek kaynak dogruyu yeniden kur.
do $$
declare
  p record;
begin
  for p in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'profiles'
  loop
    execute format('drop policy if exists %I on public.profiles', p.policyname);
  end loop;
end $$;

alter table public.profiles
  add column if not exists email text,
  add column if not exists first_name text,
  add column if not exists last_name text,
  add column if not exists full_name text,
  add column if not exists phone_number text,
  add column if not exists preferred_language_code text default 'tr',
  add column if not exists country_code text default '',
  add column if not exists language_source text default 'default',
  add column if not exists ai_enabled boolean not null default true,
  add column if not exists ai_disabled_reason text,
  add column if not exists ai_disabled_at timestamptz,
  add column if not exists marketing_opt_in boolean default false,
  add column if not exists onboarding_completed boolean default false,
  add column if not exists age_range text,
  add column if not exists role text,
  add column if not exists goals jsonb default '[]'::jsonb,
  add column if not exists interest_areas jsonb default '[]'::jsonb,
  add column if not exists learning_level text,
  add column if not exists updated_at timestamptz default now();

alter table public.profiles
  alter column goals set default '[]'::jsonb,
  alter column interest_areas set default '[]'::jsonb,
  alter column preferred_language_code set default 'tr',
  alter column country_code set default '',
  alter column language_source set default 'default',
  alter column ai_enabled set default true,
  alter column onboarding_completed set default false,
  alter column marketing_opt_in set default false;

alter table public.profiles enable row level security;
alter table public.profiles force row level security;

create policy "profiles_select_own"
  on public.profiles
  for select
  using (auth.uid() = id);

create policy "profiles_insert_own"
  on public.profiles
  for insert
  with check (auth.uid() = id);

create policy "profiles_update_own"
  on public.profiles
  for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

create policy "profiles_delete_own"
  on public.profiles
  for delete
  using (auth.uid() = id);

-- Hassas alanlari (AI ac/kapa ve kimlik alani) istemciden guncellemeyi engelle.
-- Backend service_role bu kisittan etkilenmez.
create or replace function public.profiles_guard_sensitive_fields()
returns trigger
language plpgsql
as $$
begin
  if auth.role() in ('authenticated', 'anon') then
    if new.id is distinct from old.id
      or new.email is distinct from old.email
      or new.ai_enabled is distinct from old.ai_enabled
      or new.ai_disabled_reason is distinct from old.ai_disabled_reason
      or new.ai_disabled_at is distinct from old.ai_disabled_at then
      raise exception 'Bu alanlari guncelleme yetkin yok.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_profiles_guard_sensitive_fields on public.profiles;
create trigger trg_profiles_guard_sensitive_fields
before update on public.profiles
for each row
execute function public.profiles_guard_sensitive_fields();

-- Asgari yetki: istemci rollerinde sadece gerekli islemler acik.
revoke all on table public.profiles from anon;
revoke all on table public.profiles from authenticated;
grant select, insert, update, delete on table public.profiles to authenticated;

-- E-posta doğrulanan auth.user kaydını otomatik olarak profiles tablosuna senkronize et.
create or replace function public.sync_profile_from_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_first_name text;
  v_last_name text;
  v_full_name text;
  v_phone text;
  v_confirmed boolean;
begin
  v_confirmed := (new.email_confirmed_at is not null) or (new.confirmed_at is not null);
  if not v_confirmed then
    return new;
  end if;

  v_first_name := nullif(trim(coalesce(new.raw_user_meta_data->>'first_name', new.raw_user_meta_data->>'given_name')), '');
  v_last_name := nullif(trim(coalesce(new.raw_user_meta_data->>'last_name', new.raw_user_meta_data->>'family_name')), '');
  v_full_name := nullif(
    trim(
      coalesce(
        new.raw_user_meta_data->>'full_name',
        new.raw_user_meta_data->>'name',
        concat_ws(' ', v_first_name, v_last_name)
      )
    ),
    ''
  );
  v_phone := nullif(trim(coalesce(new.raw_user_meta_data->>'phone_number', new.raw_user_meta_data->>'phone')), '');

  insert into public.profiles (
    id,
    email,
    first_name,
    last_name,
    full_name,
    phone_number,
    updated_at
  )
  values (
    new.id,
    new.email,
    v_first_name,
    v_last_name,
    v_full_name,
    v_phone,
    now()
  )
  on conflict (id) do update set
    email = excluded.email,
    first_name = coalesce(excluded.first_name, public.profiles.first_name),
    last_name = coalesce(excluded.last_name, public.profiles.last_name),
    full_name = coalesce(excluded.full_name, public.profiles.full_name),
    phone_number = coalesce(excluded.phone_number, public.profiles.phone_number),
    updated_at = now();

  return new;
end;
$$;

drop trigger if exists trg_sync_profile_from_auth_user on auth.users;
create trigger trg_sync_profile_from_auth_user
after insert or update of email, raw_user_meta_data, email_confirmed_at, confirmed_at
on auth.users
for each row
execute function public.sync_profile_from_auth_user();
