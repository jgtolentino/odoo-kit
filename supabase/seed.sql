-- ============================================================================
-- SEED DATA: Initial Configuration for Observability & Governance
-- ============================================================================
-- This file contains initial data for the observability platform.
-- Run after migrations: supabase db seed
-- ============================================================================

-- ============================================================================
-- OPS: Sample configuration snapshots (baselines)
-- ============================================================================

-- Sample GitHub repository baseline (replace with your actual repo)
INSERT INTO ops.config_snapshots (system, resource, config, checksum, is_baseline, description)
VALUES (
  'github',
  'your-org/your-repo',
  '{
    "default_branch": "main",
    "has_issues": true,
    "has_wiki": false,
    "has_discussions": false,
    "allow_squash_merge": true,
    "allow_merge_commit": false,
    "allow_rebase_merge": true,
    "delete_branch_on_merge": true,
    "visibility": "private",
    "archived": false
  }'::JSONB,
  'baseline-001',
  TRUE,
  'GitHub repository baseline configuration'
) ON CONFLICT DO NOTHING;

-- Sample Supabase extensions baseline
INSERT INTO ops.config_snapshots (system, resource, config, checksum, is_baseline, description)
VALUES (
  'supabase',
  'extensions',
  '{
    "plpgsql": "1.0",
    "pg_cron": "1.6",
    "uuid-ossp": "1.1"
  }'::JSONB,
  'baseline-002',
  TRUE,
  'Expected PostgreSQL extensions'
) ON CONFLICT DO NOTHING;

-- ============================================================================
-- ADVISOR: Additional custom checks
-- ============================================================================

-- Check for Supabase Auth anonymous access
INSERT INTO advisor.checks (
  id, category, severity, title, description, impact, remediation, enabled
) VALUES (
  'SEC-005',
  'security',
  'medium',
  'Supabase Storage Public Buckets',
  'Storage buckets with public access may expose sensitive files.',
  'Data leakage, unauthorized file access.',
  'Review bucket policies and ensure only intended files are publicly accessible.',
  TRUE
) ON CONFLICT (id) DO NOTHING;

-- Check for stale mirror data
INSERT INTO advisor.checks (
  id, category, severity, title, description, impact, remediation,
  check_query, enabled
) VALUES (
  'SYNC-001',
  'reliability',
  'high',
  'Stale Mirror Data',
  'Mirror tables have not been synced recently, data may be outdated.',
  'Inconsistent data between Odoo and applications, incorrect reporting.',
  'Check the sync worker and ensure it is running correctly.',
  $check$
    SELECT
      table_name AS resource_id,
      table_name AS resource_name,
      jsonb_build_object(
        'last_sync', last_sync_at,
        'status', last_status,
        'stale_count', stale_count
      ) AS evidence
    FROM mirror.get_sync_status()
    WHERE last_status = 'failed'
       OR (last_sync_at IS NOT NULL AND last_sync_at < now() - interval '2 hours')
  $check$,
  TRUE
) ON CONFLICT (id) DO NOTHING;

-- Check for failed commands in the command log
INSERT INTO advisor.checks (
  id, category, severity, title, description, impact, remediation,
  check_query, enabled
) VALUES (
  'OPS-003',
  'operational',
  'high',
  'Failed Odoo Commands',
  'Commands to Odoo have failed and may need manual intervention.',
  'Data inconsistency, incomplete operations.',
  'Review failed commands in ops.odoo_command_log and retry or resolve manually.',
  $check$
    SELECT
      id::text AS resource_id,
      command_type AS resource_name,
      jsonb_build_object(
        'created_at', created_at,
        'command_type', command_type,
        'attempts', attempts,
        'last_error', last_error
      ) AS evidence
    FROM ops.odoo_command_log
    WHERE status = 'error'
      AND created_at > now() - interval '24 hours'
  $check$,
  TRUE
) ON CONFLICT (id) DO NOTHING;

-- ============================================================================
-- MIRROR: Sample company (for testing RLS)
-- ============================================================================

-- This would normally come from Odoo sync, but we seed one for testing
INSERT INTO mirror.res_company (id, name, display_name, active, sync_status, last_synced_at)
VALUES (1, 'Main Company', 'Main Company', TRUE, 'synced', now())
ON CONFLICT (id) DO NOTHING;

-- ============================================================================
-- OPS: Initialize cron job next_run times
-- ============================================================================

UPDATE ops.cron_jobs
SET next_run_at = now() + (
  CASE job_name
    WHEN 'health-check-full' THEN interval '5 minutes'
    WHEN 'advisor-checks' THEN interval '1 hour'
    WHEN 'slack-alert-check' THEN interval '1 minute'
    WHEN 'drift-detection' THEN interval '1 hour'
    WHEN 'storage-metrics' THEN interval '6 hours'
    WHEN 'cleanup-old-events' THEN interval '1 day'
    WHEN 'cleanup-old-health' THEN interval '1 day'
    ELSE interval '1 hour'
  END
)
WHERE next_run_at IS NULL;

-- ============================================================================
-- VERIFY: Run initial checks
-- ============================================================================

-- Run all advisor checks to populate initial findings
-- Uncomment the following line to run checks on seed:
-- SELECT advisor.run_all_checks();

-- ============================================================================
-- DONE
-- ============================================================================

-- Output summary
DO $$
BEGIN
  RAISE NOTICE 'Seed complete. Summary:';
  RAISE NOTICE '  - Config snapshots: %', (SELECT COUNT(*) FROM ops.config_snapshots);
  RAISE NOTICE '  - Advisor checks: %', (SELECT COUNT(*) FROM advisor.checks);
  RAISE NOTICE '  - Cron jobs: %', (SELECT COUNT(*) FROM ops.cron_jobs);
END $$;
