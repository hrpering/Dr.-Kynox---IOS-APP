create table if not exists public.user_push_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null default 'ios',
  device_token text not null,
  notifications_enabled boolean not null default true,
  is_active boolean not null default true,
  apns_environment text not null default 'production',
  device_model text,
  app_version text,
  locale text,
  timezone text,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_push_devices_platform_check check (platform in ('ios')),
  constraint user_push_devices_apns_environment_check check (apns_environment in ('production', 'sandbox')),
  constraint user_push_devices_token_len_check check (char_length(device_token) between 32 and 512)
);

create unique index if not exists idx_user_push_devices_user_token
  on public.user_push_devices(user_id, device_token);

create index if not exists idx_user_push_devices_active
  on public.user_push_devices(is_active, notifications_enabled, last_seen_at desc);

create index if not exists idx_user_push_devices_user_last_seen
  on public.user_push_devices(user_id, last_seen_at desc);

create or replace function public.user_push_devices_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_user_push_devices_set_updated_at on public.user_push_devices;
create trigger trg_user_push_devices_set_updated_at
before update on public.user_push_devices
for each row execute function public.user_push_devices_set_updated_at();

alter table public.user_push_devices enable row level security;
alter table public.user_push_devices force row level security;

drop policy if exists user_push_devices_select_own on public.user_push_devices;
create policy user_push_devices_select_own
  on public.user_push_devices
  for select
  using (auth.uid() = user_id);

drop policy if exists user_push_devices_insert_own on public.user_push_devices;
create policy user_push_devices_insert_own
  on public.user_push_devices
  for insert
  with check (auth.uid() = user_id);

drop policy if exists user_push_devices_update_own on public.user_push_devices;
create policy user_push_devices_update_own
  on public.user_push_devices
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists user_push_devices_delete_own on public.user_push_devices;
create policy user_push_devices_delete_own
  on public.user_push_devices
  for delete
  using (auth.uid() = user_id);

revoke all on table public.user_push_devices from anon;
revoke all on table public.user_push_devices from authenticated;
grant select, insert, update, delete on table public.user_push_devices to authenticated;

create table if not exists public.app_broadcasts (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  deep_link text,
  push_enabled boolean not null default true,
  in_app_enabled boolean not null default true,
  expires_at timestamptz,
  created_by text,
  created_at timestamptz not null default now()
);

create index if not exists idx_app_broadcasts_created
  on public.app_broadcasts(created_at desc);

create table if not exists public.app_broadcast_targets (
  broadcast_id uuid not null references public.app_broadcasts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  push_status text not null default 'pending',
  push_sent_at timestamptz,
  push_error text,
  seen_at timestamptz,
  dismissed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint app_broadcast_targets_pk primary key (broadcast_id, user_id),
  constraint app_broadcast_targets_push_status_check check (push_status in ('pending', 'sent', 'failed', 'skipped'))
);

create index if not exists idx_app_broadcast_targets_user_created
  on public.app_broadcast_targets(user_id, created_at desc);

create index if not exists idx_app_broadcast_targets_push_status
  on public.app_broadcast_targets(push_status, created_at desc);

create or replace function public.app_broadcast_targets_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_app_broadcast_targets_set_updated_at on public.app_broadcast_targets;
create trigger trg_app_broadcast_targets_set_updated_at
before update on public.app_broadcast_targets
for each row execute function public.app_broadcast_targets_set_updated_at();

alter table public.app_broadcasts enable row level security;
alter table public.app_broadcasts force row level security;
alter table public.app_broadcast_targets enable row level security;
alter table public.app_broadcast_targets force row level security;

drop policy if exists app_broadcast_targets_select_own on public.app_broadcast_targets;
create policy app_broadcast_targets_select_own
  on public.app_broadcast_targets
  for select
  using (auth.uid() = user_id);

drop policy if exists app_broadcast_targets_update_own on public.app_broadcast_targets;
create policy app_broadcast_targets_update_own
  on public.app_broadcast_targets
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

revoke all on table public.app_broadcasts from anon;
revoke all on table public.app_broadcasts from authenticated;

revoke all on table public.app_broadcast_targets from anon;
revoke all on table public.app_broadcast_targets from authenticated;
grant select, update on table public.app_broadcast_targets to authenticated;
