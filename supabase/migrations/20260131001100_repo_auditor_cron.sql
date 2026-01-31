-- ============================================================================
-- REPO AUDITOR: Cron Job Scheduling
-- ============================================================================
-- Purpose: Schedule daily repo auditor runs via pg_cron + pg_net
-- Pattern: Cron triggers Edge Function via HTTP POST
-- ============================================================================

BEGIN;

-- Ensure extensions are enabled
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- ============================================================================
-- Register the cron job metadata in ops.cron_jobs
-- ============================================================================

INSERT INTO ops.cron_jobs (
  job_name,
  description,
  schedule,
  timezone,
  command_type,
  command,
  enabled,
  alert_on_failure,
  tags,
  metadata
) VALUES (
  'repo-auditor-daily',
  'Daily repository security and hardening audit via GitHub App',
  '15 18 * * *',  -- 18:15 UTC = 02:15 Asia/Manila (UTC+8)
  'UTC',
  'http',
  '/functions/v1/repo-auditor',
  true,
  true,
  ARRAY['security', 'hardening', 'github', 'automated'],
  jsonb_build_object(
    'function_name', 'repo-auditor',
    'requires_admin_key', true,
    'notes', 'Crawls GitHub repos, checks security posture, creates issues for findings'
  )
)
ON CONFLICT (job_name)
DO UPDATE SET
  description = EXCLUDED.description,
  schedule = EXCLUDED.schedule,
  command = EXCLUDED.command,
  metadata = EXCLUDED.metadata;

-- ============================================================================
-- Create the pg_cron job
-- ============================================================================
-- NOTE: The admin key must be set as a database setting via:
--   ALTER DATABASE postgres SET app.repo_auditor_admin_key = 'YOUR_KEY';
--
-- This is done separately in CI/CD to avoid committing secrets.
-- ============================================================================

-- First, try to unschedule if it exists (idempotent)
DO $$
BEGIN
  PERFORM cron.unschedule('repo-auditor-daily');
EXCEPTION WHEN OTHERS THEN
  -- Job doesn't exist, that's fine
  NULL;
END;
$$;

-- Schedule the job
-- Runs at 18:15 UTC daily (02:15 Manila time)
SELECT cron.schedule(
  'repo-auditor-daily',
  '15 18 * * *',
  $$
  SELECT
    net.http_post(
      url := current_setting('app.supabase_url', true) || '/functions/v1/repo-auditor',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-admin-key', current_setting('app.repo_auditor_admin_key', true)
      ),
      body := jsonb_build_object(
        'triggered_by', 'pg_cron',
        'scheduled_at', now()::text
      )
    );
  $$
);

-- ============================================================================
-- Alternative: Schedule via Supabase service role key (if no admin key)
-- ============================================================================
-- If you don't want to use a separate admin key, you can use the service role
-- key directly. This is less secure but simpler for testing.
--
-- Uncomment below and comment out the above schedule if needed:
-- ============================================================================

-- SELECT cron.schedule(
--   'repo-auditor-daily-alt',
--   '15 18 * * *',
--   $$
--   SELECT
--     net.http_post(
--       url := current_setting('app.supabase_url', true) || '/functions/v1/repo-auditor',
--       headers := jsonb_build_object(
--         'Content-Type', 'application/json',
--         'Authorization', 'Bearer ' || current_setting('app.supabase_service_role_key', true)
--       ),
--       body := '{}'::jsonb
--     );
--   $$
-- );

-- ============================================================================
-- Helper function to manually trigger the auditor
-- ============================================================================

CREATE OR REPLACE FUNCTION ops.trigger_repo_auditor()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result jsonb;
  v_response_id bigint;
BEGIN
  SELECT net.http_post(
    url := current_setting('app.supabase_url', true) || '/functions/v1/repo-auditor',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-admin-key', current_setting('app.repo_auditor_admin_key', true)
    ),
    body := jsonb_build_object(
      'triggered_by', 'manual',
      'triggered_at', now()::text
    )
  ) INTO v_response_id;

  RETURN jsonb_build_object(
    'triggered', true,
    'response_id', v_response_id,
    'note', 'Check ops.repo_audit_runs for results'
  );
END;
$$;

COMMENT ON FUNCTION ops.trigger_repo_auditor IS 'Manually trigger the repo auditor Edge Function';

-- ============================================================================
-- Database settings required (set these in CI/CD, not in migration)
-- ============================================================================
-- These must be set via psql or your deployment process:
--
-- ALTER DATABASE postgres SET app.supabase_url = 'https://YOUR_PROJECT_REF.supabase.co';
-- ALTER DATABASE postgres SET app.repo_auditor_admin_key = 'YOUR_STRONG_RANDOM_KEY';
--
-- Optional (only if using service role auth instead of admin key):
-- ALTER DATABASE postgres SET app.supabase_service_role_key = 'YOUR_SERVICE_ROLE_KEY';
-- ============================================================================

COMMIT;
