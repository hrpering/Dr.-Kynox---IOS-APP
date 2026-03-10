-- RLS audit checklist for Dr.Kynox core tables
-- Run in Supabase SQL editor to verify policy posture.

select
  n.nspname as schema_name,
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'r'
  and c.relname in (
    'profiles',
    'case_sessions',
    'daily_challenges',
    'daily_challenge_attempts',
    'app_sessions',
    'scoring_jobs',
    'widget_events',
    'gdpr_requests',
    'rate_limit_audit_events',
    'app_error_events',
    'suspicious_activity_events',
    'content_reports',
    'user_feedback'
  )
order by c.relname;

select
  tablename,
  policyname,
  cmd,
  permissive,
  roles,
  qual,
  with_check
from pg_policies
where schemaname = 'public'
  and tablename in (
    'profiles',
    'case_sessions',
    'daily_challenges',
    'daily_challenge_attempts',
    'app_sessions',
    'scoring_jobs',
    'widget_events',
    'gdpr_requests',
    'app_error_events',
    'content_reports',
    'user_feedback'
  )
order by tablename, policyname;
