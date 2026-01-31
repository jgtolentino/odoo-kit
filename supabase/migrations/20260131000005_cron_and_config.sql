-- ============================================================================
-- CRON JOBS & CONFIGURATION SNAPSHOTS
-- ============================================================================
-- Purpose: Scheduled control loops and configuration drift detection
-- Pattern:
--   Cron → check systems
--       → write ops_event
--       → if severity >= HIGH → Slack alert / GitHub issue
-- ============================================================================

-- Enable pg_cron extension
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ============================================================================
-- TABLE: ops.config_snapshots
-- ============================================================================
-- Purpose: Store expected configuration for drift detection
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.config_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- What this is a snapshot of
  system TEXT NOT NULL,                       -- 'github', 'mailgun', 'vercel', 'supabase', 'odoo'
  resource TEXT NOT NULL,                     -- Specific resource identifier

  -- The configuration
  config JSONB NOT NULL,
  checksum TEXT NOT NULL,                     -- For quick comparison

  -- Metadata
  description TEXT,
  is_baseline BOOLEAN DEFAULT FALSE,          -- True if this is the approved baseline
  approved_by TEXT,
  approved_at TIMESTAMPTZ,

  -- Audit
  captured_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,

  -- Index for quick lookups
  UNIQUE (system, resource, checksum)
);

CREATE INDEX idx_config_snapshots_system ON ops.config_snapshots(system);
CREATE INDEX idx_config_snapshots_resource ON ops.config_snapshots(resource);
CREATE INDEX idx_config_snapshots_captured ON ops.config_snapshots(captured_at DESC);
CREATE INDEX idx_config_snapshots_baseline ON ops.config_snapshots(system, resource)
  WHERE is_baseline = TRUE;

-- Enable RLS
ALTER TABLE ops.config_snapshots ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role has full access to config_snapshots"
  ON ops.config_snapshots FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Authenticated users can read config_snapshots"
  ON ops.config_snapshots FOR SELECT
  TO authenticated
  USING (true);

-- ============================================================================
-- TABLE: ops.cron_jobs
-- ============================================================================
-- Purpose: Track cron job definitions (metadata only, actual jobs in pg_cron)
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.cron_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Job identification
  job_name TEXT NOT NULL UNIQUE,
  description TEXT,

  -- Schedule
  schedule TEXT NOT NULL,                     -- Cron expression
  timezone TEXT DEFAULT 'UTC',

  -- Execution
  command_type TEXT NOT NULL,                 -- 'function', 'sql', 'http'
  command TEXT NOT NULL,                      -- SQL command, function name, or HTTP endpoint

  -- State
  enabled BOOLEAN DEFAULT TRUE,
  last_run_at TIMESTAMPTZ,
  next_run_at TIMESTAMPTZ,
  last_status TEXT,

  -- Alerting
  alert_on_failure BOOLEAN DEFAULT TRUE,
  alert_channel TEXT,                         -- Slack channel override

  -- Metadata
  tags TEXT[] DEFAULT '{}',
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_cron_jobs_name ON ops.cron_jobs(job_name);
CREATE INDEX idx_cron_jobs_enabled ON ops.cron_jobs(enabled) WHERE enabled = TRUE;

-- Enable RLS
ALTER TABLE ops.cron_jobs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role has full access to cron_jobs"
  ON ops.cron_jobs FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Authenticated users can read cron_jobs"
  ON ops.cron_jobs FOR SELECT
  TO authenticated
  USING (true);

-- ============================================================================
-- DRIFT CHECK (for advisor)
-- ============================================================================

INSERT INTO advisor.checks (
  id, category, severity, title, description, impact, remediation, target_resource_type, enabled
) VALUES (
  'DRIFT-001', 'operational', 'medium',
  'Configuration Drift Detected',
  'System configuration has changed from the approved baseline.',
  'Unexpected behavior, security vulnerabilities, compliance issues.',
  'Review the configuration changes and either approve them or revert to baseline.',
  'configuration',
  TRUE
) ON CONFLICT (id) DO UPDATE SET
  description = EXCLUDED.description,
  updated_at = now();

-- ============================================================================
-- SEED: Cron Job Definitions
-- ============================================================================

INSERT INTO ops.cron_jobs (job_name, description, schedule, command_type, command, tags) VALUES
-- Health checks every 5 minutes
('health-check-full', 'Full system health check', '*/5 * * * *', 'http',
  'POST /functions/v1/health-check?action=full', ARRAY['health', 'critical']),

-- Advisor checks every hour
('advisor-checks', 'Run all advisor checks', '0 * * * *', 'sql',
  'SELECT advisor.run_all_checks()', ARRAY['advisor', 'governance']),

-- Slack alerts every minute (check for new findings)
('slack-alert-check', 'Check for alertable events', '* * * * *', 'http',
  'POST /functions/v1/slack-alert?action=check_all', ARRAY['alerting']),

-- Drift detection every hour
('drift-detection', 'Check for configuration drift', '15 * * * *', 'http',
  'POST /functions/v1/drift-detection', ARRAY['drift', 'governance']),

-- Storage metrics every 6 hours
('storage-metrics', 'Collect storage metrics for cost tracking', '0 */6 * * *', 'sql',
  'SELECT ops.collect_storage_metrics()', ARRAY['cost', 'metrics']),

-- Clean old events daily (keep 30 days)
('cleanup-old-events', 'Remove events older than 30 days', '0 2 * * *', 'sql',
  'DELETE FROM ops.events WHERE timestamp < now() - interval ''30 days''', ARRAY['maintenance']),

-- Clean old health signals daily (keep 7 days)
('cleanup-old-health', 'Remove health signals older than 7 days', '0 3 * * *', 'sql',
  'DELETE FROM ops.health WHERE measured_at < now() - interval ''7 days''', ARRAY['maintenance'])

ON CONFLICT (job_name) DO UPDATE SET
  schedule = EXCLUDED.schedule,
  command = EXCLUDED.command,
  updated_at = now();

-- ============================================================================
-- FUNCTION: Schedule Cron Jobs
-- ============================================================================

-- Function to create actual pg_cron jobs from our definitions
CREATE OR REPLACE FUNCTION ops.schedule_cron_jobs()
RETURNS TABLE (job_name TEXT, scheduled BOOLEAN, message TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_job RECORD;
  v_cron_jobid BIGINT;
BEGIN
  FOR v_job IN
    SELECT * FROM ops.cron_jobs WHERE enabled = TRUE
  LOOP
    BEGIN
      -- For SQL commands, schedule directly
      IF v_job.command_type = 'sql' THEN
        SELECT cron.schedule(v_job.job_name, v_job.schedule, v_job.command)
        INTO v_cron_jobid;

        job_name := v_job.job_name;
        scheduled := TRUE;
        message := format('Scheduled SQL job with ID %s', v_cron_jobid);
        RETURN NEXT;

      -- For HTTP commands, use net.http_post (requires pg_net extension)
      ELSIF v_job.command_type = 'http' THEN
        -- Parse the HTTP command
        -- Format: METHOD /path
        SELECT cron.schedule(
          v_job.job_name,
          v_job.schedule,
          format(
            $sql$
            SELECT net.http_post(
              url := %L || %L,
              headers := '{"Authorization": "Bearer " || current_setting(''app.settings.service_role_key'')}'::jsonb,
              body := '{}'::jsonb
            )
            $sql$,
            current_setting('app.settings.supabase_url', true),
            substring(v_job.command from '\s+(.+)$')
          )
        ) INTO v_cron_jobid;

        job_name := v_job.job_name;
        scheduled := TRUE;
        message := format('Scheduled HTTP job with ID %s', v_cron_jobid);
        RETURN NEXT;

      ELSE
        job_name := v_job.job_name;
        scheduled := FALSE;
        message := 'Unknown command type: ' || v_job.command_type;
        RETURN NEXT;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      job_name := v_job.job_name;
      scheduled := FALSE;
      message := SQLERRM;
      RETURN NEXT;
    END;
  END LOOP;
END;
$$;

-- Function to unschedule all cron jobs
CREATE OR REPLACE FUNCTION ops.unschedule_all_cron_jobs()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_count INTEGER := 0;
  v_job RECORD;
BEGIN
  FOR v_job IN SELECT jobname FROM cron.job LOOP
    PERFORM cron.unschedule(v_job.jobname);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- ============================================================================
-- VIEW: Cron Job Status
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_cron_status AS
SELECT
  j.job_name,
  j.description,
  j.schedule,
  j.command_type,
  j.enabled,
  j.last_run_at,
  j.last_status,
  c.jobid AS pg_cron_id,
  c.schedule AS pg_cron_schedule,
  c.active AS pg_cron_active,
  jr.status AS last_run_status,
  jr.return_message AS last_run_message,
  jr.start_time AS last_run_start,
  jr.end_time AS last_run_end
FROM ops.cron_jobs j
LEFT JOIN cron.job c ON c.jobname = j.job_name
LEFT JOIN LATERAL (
  SELECT * FROM cron.job_run_details
  WHERE jobid = c.jobid
  ORDER BY start_time DESC
  LIMIT 1
) jr ON TRUE
ORDER BY j.job_name;

-- ============================================================================
-- FUNCTION: Update Cron Job Status
-- ============================================================================

-- This function should be called after cron job completion to update status
CREATE OR REPLACE FUNCTION ops.update_cron_job_status(
  p_job_name TEXT,
  p_status TEXT,
  p_next_run_at TIMESTAMPTZ DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE ops.cron_jobs
  SET
    last_run_at = now(),
    last_status = p_status,
    next_run_at = p_next_run_at,
    updated_at = now()
  WHERE job_name = p_job_name;
END;
$$;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE ops.config_snapshots IS 'Stores configuration snapshots for drift detection';
COMMENT ON TABLE ops.cron_jobs IS 'Metadata for scheduled cron jobs (actual jobs managed by pg_cron)';

COMMENT ON FUNCTION ops.schedule_cron_jobs IS 'Create pg_cron jobs from ops.cron_jobs definitions';
COMMENT ON FUNCTION ops.unschedule_all_cron_jobs IS 'Remove all scheduled pg_cron jobs';
COMMENT ON FUNCTION ops.update_cron_job_status IS 'Update cron job status after execution';

COMMENT ON VIEW ops.v_cron_status IS 'Combined view of cron job definitions and their pg_cron status';
