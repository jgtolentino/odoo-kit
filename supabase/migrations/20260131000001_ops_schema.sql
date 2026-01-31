-- ============================================================================
-- OPS SCHEMA: Central Telemetry & Observability Tables
-- ============================================================================
-- Purpose: Azure Portal / Databricks-style job + pipeline observability
-- Pattern: Every system writes here (Odoo jobs, MCP agents, Vercel cron, n8n, GitHub Actions)
--
-- This replaces Vercel Observability Plus with free Supabase primitives.
-- ============================================================================

-- Create ops schema for isolation
CREATE SCHEMA IF NOT EXISTS ops;

-- Grant usage to authenticated users
GRANT USAGE ON SCHEMA ops TO authenticated;
GRANT USAGE ON SCHEMA ops TO service_role;

-- ============================================================================
-- ENUMS: Standardized status and severity values
-- ============================================================================

-- Run status enum (job/pipeline execution states)
CREATE TYPE ops.run_status AS ENUM (
  'pending',      -- Queued, waiting to start
  'running',      -- Currently executing
  'success',      -- Completed successfully
  'failed',       -- Completed with failure
  'cancelled',    -- Manually cancelled
  'timeout',      -- Exceeded time limit
  'retrying'      -- Failed but retrying
);

-- Event level enum (log severity levels)
CREATE TYPE ops.event_level AS ENUM (
  'debug',        -- Detailed debugging info
  'info',         -- General information
  'warn',         -- Warning conditions
  'error',        -- Error conditions
  'fatal'         -- Critical failures
);

-- System identifier enum (source systems)
CREATE TYPE ops.system_type AS ENUM (
  'odoo',         -- Odoo ERP system
  'vercel',       -- Vercel deployments/functions
  'mcp',          -- MCP agents
  'n8n',          -- n8n workflows
  'github',       -- GitHub Actions
  'supabase',     -- Supabase internal (cron, functions)
  'slack',        -- Slack integrations
  'mailgun',      -- Email service
  'custom'        -- Custom integrations
);

-- Health signal type enum
CREATE TYPE ops.signal_type AS ENUM (
  'latency_p50',      -- 50th percentile latency
  'latency_p95',      -- 95th percentile latency
  'latency_p99',      -- 99th percentile latency
  'error_rate',       -- Errors per time window
  'success_rate',     -- Success percentage
  'throughput',       -- Requests/operations per second
  'queue_depth',      -- Items waiting in queue
  'memory_usage',     -- Memory consumption
  'cpu_usage',        -- CPU utilization
  'disk_usage',       -- Disk space usage
  'connection_count', -- Active connections
  'uptime',           -- Service uptime
  'custom'            -- Custom metric
);

-- ============================================================================
-- TABLE: ops.runs
-- ============================================================================
-- Purpose: Track all job/pipeline/workflow executions across systems
-- Pattern: One row per execution, updated as status changes
-- ============================================================================

CREATE TABLE ops.runs (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identity
  system ops.system_type NOT NULL,
  job_name TEXT NOT NULL,                     -- e.g., "sync_partners", "daily_report"
  job_type TEXT,                              -- e.g., "cron", "webhook", "manual"

  -- Execution context
  run_number BIGINT,                          -- Sequential run number for this job
  parent_run_id UUID REFERENCES ops.runs(id), -- For nested/child runs
  correlation_id UUID,                        -- For tracing across systems

  -- Status tracking
  status ops.run_status NOT NULL DEFAULT 'pending',
  attempt_number INTEGER DEFAULT 1,           -- Retry attempt number
  max_attempts INTEGER DEFAULT 3,             -- Maximum retry attempts

  -- Timing
  scheduled_at TIMESTAMPTZ,                   -- When it was supposed to run
  started_at TIMESTAMPTZ,                     -- Actual start time
  ended_at TIMESTAMPTZ,                       -- Completion time
  timeout_seconds INTEGER,                    -- Configured timeout

  -- Results
  exit_code INTEGER,                          -- Process exit code if applicable
  error_message TEXT,                         -- Error message if failed
  error_stack TEXT,                           -- Stack trace if available

  -- Metrics
  records_processed BIGINT,                   -- Items processed
  records_failed BIGINT,                      -- Items that failed
  bytes_processed BIGINT,                     -- Data volume

  -- Context
  trigger_type TEXT,                          -- "schedule", "webhook", "manual", "api"
  trigger_source TEXT,                        -- Who/what triggered it
  environment TEXT DEFAULT 'production',      -- "production", "staging", "development"

  -- Metadata
  metadata JSONB DEFAULT '{}',                -- Flexible additional data
  tags TEXT[] DEFAULT '{}',                   -- Searchable tags

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,

  -- Constraints
  CONSTRAINT valid_timing CHECK (ended_at IS NULL OR ended_at >= started_at),
  CONSTRAINT valid_records CHECK (records_failed IS NULL OR records_processed IS NULL OR records_failed <= records_processed)
);

-- Indexes for common queries
CREATE INDEX idx_runs_system ON ops.runs(system);
CREATE INDEX idx_runs_job_name ON ops.runs(job_name);
CREATE INDEX idx_runs_status ON ops.runs(status);
CREATE INDEX idx_runs_started_at ON ops.runs(started_at DESC);
CREATE INDEX idx_runs_correlation ON ops.runs(correlation_id) WHERE correlation_id IS NOT NULL;
CREATE INDEX idx_runs_parent ON ops.runs(parent_run_id) WHERE parent_run_id IS NOT NULL;
CREATE INDEX idx_runs_active ON ops.runs(system, job_name) WHERE status IN ('pending', 'running', 'retrying');
CREATE INDEX idx_runs_failed ON ops.runs(system, ended_at DESC) WHERE status = 'failed';
CREATE INDEX idx_runs_tags ON ops.runs USING gin(tags);
CREATE INDEX idx_runs_metadata ON ops.runs USING gin(metadata);

-- ============================================================================
-- TABLE: ops.events
-- ============================================================================
-- Purpose: Append-only log of all events during runs
-- Pattern: Write once, never update. This is your audit trail.
-- ============================================================================

CREATE TABLE ops.events (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Link to run (optional - some events are system-wide)
  run_id UUID REFERENCES ops.runs(id) ON DELETE CASCADE,

  -- Event classification
  level ops.event_level NOT NULL DEFAULT 'info',
  category TEXT,                              -- e.g., "database", "api", "auth"
  event_type TEXT,                            -- e.g., "query_executed", "request_failed"

  -- Content
  message TEXT NOT NULL,                      -- Human-readable message

  -- Context
  system ops.system_type,                     -- Source system
  component TEXT,                             -- e.g., "partner_sync", "invoice_api"
  function_name TEXT,                         -- Function/method name
  file_path TEXT,                             -- Source file if available
  line_number INTEGER,                        -- Line number if available

  -- Structured data
  metadata JSONB DEFAULT '{}',                -- Flexible event data
  context JSONB DEFAULT '{}',                 -- Execution context (user, request, etc.)

  -- Timing
  duration_ms DOUBLE PRECISION,               -- Duration if applicable
  timestamp TIMESTAMPTZ DEFAULT now() NOT NULL,

  -- Tracing
  trace_id TEXT,                              -- Distributed trace ID
  span_id TEXT,                               -- Span ID within trace
  parent_span_id TEXT,                        -- Parent span for nesting

  -- Never update events - they are immutable
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- Indexes for log queries
CREATE INDEX idx_events_run ON ops.events(run_id) WHERE run_id IS NOT NULL;
CREATE INDEX idx_events_level ON ops.events(level);
CREATE INDEX idx_events_timestamp ON ops.events(timestamp DESC);
CREATE INDEX idx_events_system ON ops.events(system) WHERE system IS NOT NULL;
CREATE INDEX idx_events_category ON ops.events(category) WHERE category IS NOT NULL;
CREATE INDEX idx_events_type ON ops.events(event_type) WHERE event_type IS NOT NULL;
CREATE INDEX idx_events_trace ON ops.events(trace_id) WHERE trace_id IS NOT NULL;
CREATE INDEX idx_events_errors ON ops.events(timestamp DESC) WHERE level IN ('error', 'fatal');
CREATE INDEX idx_events_metadata ON ops.events USING gin(metadata);

-- Partition by time for better performance on large datasets
-- (Uncomment if you expect high volume)
-- CREATE INDEX idx_events_partition ON ops.events(timestamp);

-- ============================================================================
-- TABLE: ops.health
-- ============================================================================
-- Purpose: Time-series health signals for all systems
-- Pattern: Continuous metrics for dashboards and alerting
-- ============================================================================

CREATE TABLE ops.health (
  -- Primary key (composite for time-series)
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- What we're measuring
  system ops.system_type NOT NULL,
  component TEXT,                             -- Specific component within system
  signal ops.signal_type NOT NULL,
  signal_name TEXT,                           -- Custom name if signal = 'custom'

  -- The measurement
  value DOUBLE PRECISION NOT NULL,
  unit TEXT,                                  -- e.g., "ms", "percent", "count"

  -- Context
  environment TEXT DEFAULT 'production',
  region TEXT,                                -- Geographic region if applicable

  -- Metadata
  metadata JSONB DEFAULT '{}',
  tags TEXT[] DEFAULT '{}',

  -- Timing
  measured_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  window_seconds INTEGER,                     -- Measurement window (e.g., 60 for 1-min average)

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- Indexes for time-series queries
CREATE INDEX idx_health_system_signal ON ops.health(system, signal, measured_at DESC);
CREATE INDEX idx_health_measured ON ops.health(measured_at DESC);
CREATE INDEX idx_health_component ON ops.health(system, component, measured_at DESC) WHERE component IS NOT NULL;
CREATE INDEX idx_health_recent ON ops.health(system, signal) WHERE measured_at > now() - interval '1 hour';
CREATE INDEX idx_health_tags ON ops.health USING gin(tags);

-- ============================================================================
-- FUNCTIONS: Helpers for ops operations
-- ============================================================================

-- Function to start a new run
CREATE OR REPLACE FUNCTION ops.start_run(
  p_system ops.system_type,
  p_job_name TEXT,
  p_job_type TEXT DEFAULT NULL,
  p_trigger_type TEXT DEFAULT 'manual',
  p_trigger_source TEXT DEFAULT NULL,
  p_correlation_id UUID DEFAULT NULL,
  p_parent_run_id UUID DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_run_id UUID;
  v_run_number BIGINT;
BEGIN
  -- Get next run number for this job
  SELECT COALESCE(MAX(run_number), 0) + 1
  INTO v_run_number
  FROM ops.runs
  WHERE system = p_system AND job_name = p_job_name;

  -- Insert new run
  INSERT INTO ops.runs (
    system, job_name, job_type, run_number,
    status, started_at,
    trigger_type, trigger_source,
    correlation_id, parent_run_id,
    metadata
  ) VALUES (
    p_system, p_job_name, p_job_type, v_run_number,
    'running', now(),
    p_trigger_type, p_trigger_source,
    COALESCE(p_correlation_id, gen_random_uuid()), p_parent_run_id,
    p_metadata
  )
  RETURNING id INTO v_run_id;

  -- Log start event
  INSERT INTO ops.events (run_id, level, message, system, metadata)
  VALUES (v_run_id, 'info', format('Started run #%s of %s', v_run_number, p_job_name), p_system, p_metadata);

  RETURN v_run_id;
END;
$$;

-- Function to complete a run successfully
CREATE OR REPLACE FUNCTION ops.complete_run(
  p_run_id UUID,
  p_records_processed BIGINT DEFAULT NULL,
  p_records_failed BIGINT DEFAULT NULL,
  p_metadata JSONB DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE ops.runs
  SET
    status = 'success',
    ended_at = now(),
    records_processed = COALESCE(p_records_processed, records_processed),
    records_failed = COALESCE(p_records_failed, records_failed),
    metadata = CASE WHEN p_metadata IS NOT NULL THEN metadata || p_metadata ELSE metadata END,
    updated_at = now()
  WHERE id = p_run_id;

  INSERT INTO ops.events (run_id, level, message, metadata)
  VALUES (p_run_id, 'info', 'Run completed successfully',
    jsonb_build_object('records_processed', p_records_processed, 'records_failed', p_records_failed));
END;
$$;

-- Function to fail a run
CREATE OR REPLACE FUNCTION ops.fail_run(
  p_run_id UUID,
  p_error_message TEXT,
  p_error_stack TEXT DEFAULT NULL,
  p_should_retry BOOLEAN DEFAULT FALSE
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_attempt INTEGER;
  v_max_attempts INTEGER;
BEGIN
  SELECT attempt_number, max_attempts INTO v_attempt, v_max_attempts
  FROM ops.runs WHERE id = p_run_id;

  IF p_should_retry AND v_attempt < v_max_attempts THEN
    UPDATE ops.runs
    SET
      status = 'retrying',
      attempt_number = attempt_number + 1,
      error_message = p_error_message,
      error_stack = p_error_stack,
      updated_at = now()
    WHERE id = p_run_id;

    INSERT INTO ops.events (run_id, level, message, metadata)
    VALUES (p_run_id, 'warn', format('Run failed, retrying (attempt %s/%s)', v_attempt + 1, v_max_attempts),
      jsonb_build_object('error', p_error_message));
  ELSE
    UPDATE ops.runs
    SET
      status = 'failed',
      ended_at = now(),
      error_message = p_error_message,
      error_stack = p_error_stack,
      updated_at = now()
    WHERE id = p_run_id;

    INSERT INTO ops.events (run_id, level, message, metadata)
    VALUES (p_run_id, 'error', format('Run failed: %s', p_error_message),
      jsonb_build_object('error', p_error_message, 'stack', p_error_stack));
  END IF;
END;
$$;

-- Function to log an event
CREATE OR REPLACE FUNCTION ops.log_event(
  p_level ops.event_level,
  p_message TEXT,
  p_run_id UUID DEFAULT NULL,
  p_system ops.system_type DEFAULT NULL,
  p_category TEXT DEFAULT NULL,
  p_event_type TEXT DEFAULT NULL,
  p_component TEXT DEFAULT NULL,
  p_duration_ms DOUBLE PRECISION DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_event_id UUID;
BEGIN
  INSERT INTO ops.events (
    run_id, level, message, system,
    category, event_type, component,
    duration_ms, metadata
  ) VALUES (
    p_run_id, p_level, p_message, p_system,
    p_category, p_event_type, p_component,
    p_duration_ms, p_metadata
  )
  RETURNING id INTO v_event_id;

  RETURN v_event_id;
END;
$$;

-- Function to record a health signal
CREATE OR REPLACE FUNCTION ops.record_health(
  p_system ops.system_type,
  p_signal ops.signal_type,
  p_value DOUBLE PRECISION,
  p_component TEXT DEFAULT NULL,
  p_unit TEXT DEFAULT NULL,
  p_window_seconds INTEGER DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_health_id UUID;
BEGIN
  INSERT INTO ops.health (
    system, signal, value,
    component, unit, window_seconds,
    metadata
  ) VALUES (
    p_system, p_signal, p_value,
    p_component, p_unit, p_window_seconds,
    p_metadata
  )
  RETURNING id INTO v_health_id;

  RETURN v_health_id;
END;
$$;

-- ============================================================================
-- VIEWS: Convenient access patterns
-- ============================================================================

-- Recent failed runs
CREATE OR REPLACE VIEW ops.v_recent_failures AS
SELECT
  r.id,
  r.system,
  r.job_name,
  r.status,
  r.error_message,
  r.started_at,
  r.ended_at,
  r.ended_at - r.started_at AS duration,
  r.attempt_number,
  r.metadata
FROM ops.runs r
WHERE r.status = 'failed'
  AND r.ended_at > now() - interval '24 hours'
ORDER BY r.ended_at DESC;

-- Active runs
CREATE OR REPLACE VIEW ops.v_active_runs AS
SELECT
  r.id,
  r.system,
  r.job_name,
  r.status,
  r.started_at,
  now() - r.started_at AS running_duration,
  r.timeout_seconds,
  r.metadata
FROM ops.runs r
WHERE r.status IN ('pending', 'running', 'retrying')
ORDER BY r.started_at ASC;

-- Run statistics by job (last 24h)
CREATE OR REPLACE VIEW ops.v_job_stats AS
SELECT
  system,
  job_name,
  COUNT(*) AS total_runs,
  COUNT(*) FILTER (WHERE status = 'success') AS successful_runs,
  COUNT(*) FILTER (WHERE status = 'failed') AS failed_runs,
  ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'success') / NULLIF(COUNT(*), 0), 2) AS success_rate,
  AVG(EXTRACT(EPOCH FROM (ended_at - started_at))) FILTER (WHERE ended_at IS NOT NULL) AS avg_duration_seconds,
  MAX(started_at) AS last_run_at
FROM ops.runs
WHERE started_at > now() - interval '24 hours'
GROUP BY system, job_name
ORDER BY system, job_name;

-- Latest health signals
CREATE OR REPLACE VIEW ops.v_current_health AS
SELECT DISTINCT ON (system, component, signal)
  system,
  component,
  signal,
  value,
  unit,
  measured_at,
  metadata
FROM ops.health
WHERE measured_at > now() - interval '1 hour'
ORDER BY system, component, signal, measured_at DESC;

-- Error log stream
CREATE OR REPLACE VIEW ops.v_error_stream AS
SELECT
  e.id,
  e.timestamp,
  e.level,
  e.message,
  e.system,
  e.component,
  e.category,
  r.job_name,
  e.metadata
FROM ops.events e
LEFT JOIN ops.runs r ON e.run_id = r.id
WHERE e.level IN ('error', 'fatal')
  AND e.timestamp > now() - interval '24 hours'
ORDER BY e.timestamp DESC
LIMIT 1000;

-- ============================================================================
-- TRIGGERS: Automatic updates
-- ============================================================================

-- Update updated_at on runs
CREATE OR REPLACE FUNCTION ops.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_runs_updated_at
  BEFORE UPDATE ON ops.runs
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

-- ============================================================================
-- COMMENTS: Documentation
-- ============================================================================

COMMENT ON SCHEMA ops IS 'Central telemetry and observability schema - tracks all job executions, events, and health signals across systems';

COMMENT ON TABLE ops.runs IS 'Tracks all job/pipeline/workflow executions. One row per execution, updated as status changes.';
COMMENT ON TABLE ops.events IS 'Append-only log of all events during runs. Never update - this is your audit trail.';
COMMENT ON TABLE ops.health IS 'Time-series health signals for dashboards and alerting.';

COMMENT ON FUNCTION ops.start_run IS 'Start a new run and return its ID. Automatically assigns run number and logs start event.';
COMMENT ON FUNCTION ops.complete_run IS 'Mark a run as successfully completed.';
COMMENT ON FUNCTION ops.fail_run IS 'Mark a run as failed, with optional retry logic.';
COMMENT ON FUNCTION ops.log_event IS 'Log an event, optionally associated with a run.';
COMMENT ON FUNCTION ops.record_health IS 'Record a health signal measurement.';
