-- V2 Learning Analytics + Subscription schema rollout.
-- Bu repoda schema bootstrap server tarafinda supabase/*.sql dosyalarindan uygulanir.
-- Bu migration, deploy pipeline'larinin degisiklik setini takip etmesi icin eklendi.
-- Uygulanacak dosyalar:
--   1) supabase/learning_analytics.sql
--   2) supabase/subscriptions.sql

select 'v2_learning_analytics_subscription_registered' as migration_tag;
