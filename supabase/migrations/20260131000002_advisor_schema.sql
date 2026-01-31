-- ============================================================================
-- ADVISOR SCHEMA: Azure Advisor-style Recommendations & Checks
-- ============================================================================
-- Purpose: Proactive recommendations for security, cost, reliability, and performance
-- Pattern: Automated checks populate findings, users can resolve/dismiss
--
-- This is your "Azure Advisor" equivalent - automated governance.
-- ============================================================================

-- Create advisor schema for isolation
CREATE SCHEMA IF NOT EXISTS advisor;

-- Grant usage to authenticated users
GRANT USAGE ON SCHEMA advisor TO authenticated;
GRANT USAGE ON SCHEMA advisor TO service_role;

-- ============================================================================
-- ENUMS: Standardized categories and severities
-- ============================================================================

-- Advisor check categories (Azure Advisor alignment)
CREATE TYPE advisor.category AS ENUM (
  'security',       -- Security vulnerabilities and risks
  'cost',           -- Cost optimization opportunities
  'reliability',    -- High availability and resilience
  'performance',    -- Speed and efficiency
  'operational',    -- Operational best practices
  'compliance'      -- Regulatory and policy compliance
);

-- Severity levels
CREATE TYPE advisor.severity AS ENUM (
  'critical',       -- Immediate action required
  'high',           -- Action required soon
  'medium',         -- Should be addressed
  'low',            -- Nice to have
  'info'            -- Informational only
);

-- Finding status
CREATE TYPE advisor.finding_status AS ENUM (
  'open',           -- Active finding
  'acknowledged',   -- Seen but not yet addressed
  'in_progress',    -- Being worked on
  'resolved',       -- Fixed
  'dismissed',      -- Accepted risk / false positive
  'auto_resolved'   -- System detected fix
);

-- ============================================================================
-- TABLE: advisor.checks
-- ============================================================================
-- Purpose: Define all automated checks that can be run
-- Pattern: Static definitions, populated at deploy time or via admin
-- ============================================================================

CREATE TABLE advisor.checks (
  -- Primary key
  id TEXT PRIMARY KEY,                        -- e.g., "SEC-001", "COST-003"

  -- Classification
  category advisor.category NOT NULL,
  severity advisor.severity NOT NULL DEFAULT 'medium',

  -- Description
  title TEXT NOT NULL,                        -- Short title
  description TEXT NOT NULL,                  -- Full description of the issue
  impact TEXT,                                -- What happens if not addressed

  -- Remediation
  remediation TEXT,                           -- How to fix
  remediation_url TEXT,                       -- Link to documentation
  auto_remediation_available BOOLEAN DEFAULT FALSE,

  -- Execution
  check_query TEXT,                           -- SQL query to detect issues
  check_function TEXT,                        -- Edge Function to run
  check_interval_minutes INTEGER DEFAULT 60,  -- How often to run

  -- Targeting
  target_system ops.system_type,              -- Which system this checks
  target_resource_type TEXT,                  -- e.g., "table", "function", "policy"

  -- Metadata
  tags TEXT[] DEFAULT '{}',
  metadata JSONB DEFAULT '{}',

  -- Status
  enabled BOOLEAN DEFAULT TRUE,
  last_run_at TIMESTAMPTZ,
  next_run_at TIMESTAMPTZ,

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- Indexes
CREATE INDEX idx_checks_category ON advisor.checks(category);
CREATE INDEX idx_checks_severity ON advisor.checks(severity);
CREATE INDEX idx_checks_enabled ON advisor.checks(enabled) WHERE enabled = TRUE;
CREATE INDEX idx_checks_next_run ON advisor.checks(next_run_at) WHERE enabled = TRUE;

-- ============================================================================
-- TABLE: advisor.findings
-- ============================================================================
-- Purpose: Individual instances of detected issues
-- Pattern: Created by checks, managed by operators
-- ============================================================================

CREATE TABLE advisor.findings (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Link to check
  check_id TEXT NOT NULL REFERENCES advisor.checks(id),

  -- Classification (denormalized for performance)
  category advisor.category NOT NULL,
  severity advisor.severity NOT NULL,

  -- Content
  title TEXT NOT NULL,
  description TEXT,
  impact TEXT,
  remediation TEXT,

  -- Status
  status advisor.finding_status NOT NULL DEFAULT 'open',

  -- Resource identification
  resource_type TEXT,                         -- e.g., "table", "function", "user"
  resource_id TEXT,                           -- e.g., table name, function name
  resource_name TEXT,                         -- Human-readable name
  resource_metadata JSONB DEFAULT '{}',       -- Additional resource info

  -- Evidence
  evidence JSONB DEFAULT '{}',                -- What triggered the finding
  evidence_query TEXT,                        -- Query that found this
  evidence_timestamp TIMESTAMPTZ,             -- When evidence was gathered

  -- Scoring
  risk_score INTEGER CHECK (risk_score BETWEEN 0 AND 100),
  cost_impact DECIMAL(15, 2),                 -- Estimated cost if applicable
  affected_users INTEGER,                     -- Number of users affected

  -- Resolution tracking
  resolved_at TIMESTAMPTZ,
  resolved_by UUID,                           -- User who resolved
  resolution_notes TEXT,
  resolution_type TEXT,                       -- "manual", "auto", "dismissed"

  -- Dismissal tracking
  dismissed_at TIMESTAMPTZ,
  dismissed_by UUID,
  dismissal_reason TEXT,
  dismiss_until TIMESTAMPTZ,                  -- Temporary dismissal

  -- Detection
  first_seen_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  last_seen_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  occurrence_count INTEGER DEFAULT 1,

  -- Metadata
  metadata JSONB DEFAULT '{}',
  tags TEXT[] DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,

  -- Prevent duplicate open findings for same resource
  CONSTRAINT unique_open_finding UNIQUE (check_id, resource_type, resource_id, status)
    DEFERRABLE INITIALLY DEFERRED
);

-- Indexes for finding queries
CREATE INDEX idx_findings_check ON advisor.findings(check_id);
CREATE INDEX idx_findings_category ON advisor.findings(category);
CREATE INDEX idx_findings_severity ON advisor.findings(severity);
CREATE INDEX idx_findings_status ON advisor.findings(status);
CREATE INDEX idx_findings_open ON advisor.findings(severity, category) WHERE status = 'open';
CREATE INDEX idx_findings_resource ON advisor.findings(resource_type, resource_id);
CREATE INDEX idx_findings_first_seen ON advisor.findings(first_seen_at DESC);
CREATE INDEX idx_findings_last_seen ON advisor.findings(last_seen_at DESC);
CREATE INDEX idx_findings_metadata ON advisor.findings USING gin(metadata);
CREATE INDEX idx_findings_tags ON advisor.findings USING gin(tags);

-- ============================================================================
-- TABLE: advisor.check_runs
-- ============================================================================
-- Purpose: Track when checks were run and their results
-- Pattern: Audit trail for check execution
-- ============================================================================

CREATE TABLE advisor.check_runs (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Link to check
  check_id TEXT NOT NULL REFERENCES advisor.checks(id),

  -- Execution
  started_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  ended_at TIMESTAMPTZ,
  duration_ms INTEGER,

  -- Results
  status TEXT NOT NULL DEFAULT 'running',     -- running, success, failed
  findings_created INTEGER DEFAULT 0,
  findings_resolved INTEGER DEFAULT 0,
  findings_unchanged INTEGER DEFAULT 0,

  -- Error tracking
  error_message TEXT,
  error_stack TEXT,

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- Indexes
CREATE INDEX idx_check_runs_check ON advisor.check_runs(check_id);
CREATE INDEX idx_check_runs_started ON advisor.check_runs(started_at DESC);
CREATE INDEX idx_check_runs_status ON advisor.check_runs(status);

-- ============================================================================
-- TABLE: advisor.recommendations
-- ============================================================================
-- Purpose: Aggregated recommendations based on findings
-- Pattern: Higher-level insights that combine multiple findings
-- ============================================================================

CREATE TABLE advisor.recommendations (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Classification
  category advisor.category NOT NULL,
  priority INTEGER DEFAULT 50 CHECK (priority BETWEEN 1 AND 100),

  -- Content
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  details TEXT,

  -- Impact
  estimated_impact TEXT,                      -- "High", "Medium", "Low"
  estimated_savings DECIMAL(15, 2),           -- Cost savings if applicable
  estimated_effort TEXT,                      -- "Minutes", "Hours", "Days"

  -- Actions
  recommended_actions JSONB DEFAULT '[]',     -- Array of action steps
  documentation_url TEXT,

  -- Related findings
  finding_ids UUID[] DEFAULT '{}',            -- Findings that led to this
  finding_count INTEGER DEFAULT 0,

  -- Status
  status TEXT DEFAULT 'active',               -- active, completed, dismissed
  completed_at TIMESTAMPTZ,
  dismissed_at TIMESTAMPTZ,

  -- Metadata
  metadata JSONB DEFAULT '{}',
  tags TEXT[] DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- Indexes
CREATE INDEX idx_recommendations_category ON advisor.recommendations(category);
CREATE INDEX idx_recommendations_priority ON advisor.recommendations(priority DESC);
CREATE INDEX idx_recommendations_status ON advisor.recommendations(status);
CREATE INDEX idx_recommendations_active ON advisor.recommendations(category, priority DESC) WHERE status = 'active';

-- ============================================================================
-- SEED DATA: Built-in Checks
-- ============================================================================

-- Security Checks
INSERT INTO advisor.checks (id, category, severity, title, description, impact, remediation, check_query) VALUES
('SEC-001', 'security', 'critical', 'RLS Not Enabled on Public Tables',
  'Tables in the public schema without Row Level Security enabled are accessible to all authenticated users.',
  'Unauthorized data access, data breaches, compliance violations.',
  'Enable RLS on the table and create appropriate policies.',
  $check$
    SELECT schemaname || '.' || tablename AS resource_id,
           tablename AS resource_name,
           jsonb_build_object('schema', schemaname, 'table', tablename) AS evidence
    FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename NOT LIKE 'pg_%'
      AND tablename NOT LIKE '_%%'
      AND NOT EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = tablename
          AND n.nspname = schemaname
          AND c.relrowsecurity = true
      )
  $check$),

('SEC-002', 'security', 'high', 'Secrets in Environment Variables',
  'Sensitive values detected in environment variables or metadata that should be in Vault.',
  'Credential exposure, security breaches.',
  'Move secrets to Supabase Vault and reference them securely.',
  NULL),

('SEC-003', 'security', 'high', 'Overly Permissive RLS Policies',
  'RLS policies that use TRUE or allow access to all authenticated users without restrictions.',
  'Excessive data access, potential data leaks.',
  'Add specific conditions to RLS policies based on user roles or ownership.',
  $check$
    SELECT pol.polname AS resource_id,
           pol.polname AS resource_name,
           jsonb_build_object(
             'table', c.relname,
             'schema', n.nspname,
             'policy', pol.polname,
             'command', pol.polcmd
           ) AS evidence
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE pol.polqual::text LIKE '%true%'
       OR pol.polqual::text = ''
  $check$),

('SEC-004', 'security', 'medium', 'Anonymous Access Enabled',
  'Anonymous (unauthenticated) sign-ins are enabled, allowing access without user identity.',
  'Potential abuse, difficulty tracking users, compliance issues.',
  'Disable anonymous sign-ins unless specifically required for your use case.',
  NULL),

-- Cost Checks
('COST-001', 'cost', 'medium', 'Unused Database Tables',
  'Tables with no recent reads or writes may be candidates for archival or deletion.',
  'Unnecessary storage costs, cluttered schema.',
  'Archive or delete unused tables after confirming they are not needed.',
  $check$
    SELECT schemaname || '.' || relname AS resource_id,
           relname AS resource_name,
           jsonb_build_object(
             'schema', schemaname,
             'table', relname,
             'last_access', GREATEST(last_seq_scan, last_idx_scan),
             'size_bytes', pg_relation_size(relid)
           ) AS evidence
    FROM pg_stat_user_tables
    WHERE (last_seq_scan IS NULL OR last_seq_scan < now() - interval '30 days')
      AND (last_idx_scan IS NULL OR last_idx_scan < now() - interval '30 days')
      AND schemaname NOT IN ('ops', 'advisor', 'mirror')
  $check$),

('COST-002', 'cost', 'low', 'Large Unused Indexes',
  'Indexes that consume storage but are never used by queries.',
  'Wasted storage, slower writes due to index maintenance.',
  'Review and drop unused indexes after confirming query patterns.',
  $check$
    SELECT schemaname || '.' || indexrelname AS resource_id,
           indexrelname AS resource_name,
           jsonb_build_object(
             'schema', schemaname,
             'index', indexrelname,
             'table', relname,
             'size_bytes', pg_relation_size(indexrelid),
             'scans', idx_scan
           ) AS evidence
    FROM pg_stat_user_indexes
    WHERE idx_scan = 0
      AND pg_relation_size(indexrelid) > 1048576  -- > 1MB
  $check$),

('COST-003', 'cost', 'medium', 'High Edge Function Invocations',
  'Edge Functions with unusually high invocation counts may indicate inefficient usage.',
  'Increased compute costs, potential performance issues.',
  'Review function usage patterns and implement caching or batching where appropriate.',
  NULL),

-- Reliability Checks
('REL-001', 'reliability', 'high', 'Missing Primary Keys',
  'Tables without primary keys can cause replication issues and make debugging difficult.',
  'Replication failures, data integrity issues, poor query performance.',
  'Add a primary key to the table, typically an id column with UUID or SERIAL.',
  $check$
    SELECT schemaname || '.' || tablename AS resource_id,
           tablename AS resource_name,
           jsonb_build_object('schema', schemaname, 'table', tablename) AS evidence
    FROM pg_tables t
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'ops', 'advisor')
      AND NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_class cls ON cls.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = cls.relnamespace
        WHERE c.contype = 'p'
          AND cls.relname = t.tablename
          AND n.nspname = t.schemaname
      )
  $check$),

('REL-002', 'reliability', 'medium', 'Tables Without Timestamps',
  'Tables lacking created_at/updated_at columns make auditing and debugging difficult.',
  'Difficult troubleshooting, no audit trail, compliance gaps.',
  'Add created_at and updated_at timestamp columns with appropriate defaults and triggers.',
  $check$
    SELECT schemaname || '.' || tablename AS resource_id,
           tablename AS resource_name,
           jsonb_build_object('schema', schemaname, 'table', tablename) AS evidence
    FROM pg_tables t
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
      AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = t.schemaname
          AND c.table_name = t.tablename
          AND c.column_name IN ('created_at', 'createdat', 'created')
      )
  $check$),

('REL-003', 'reliability', 'high', 'Long-Running Queries',
  'Queries running for extended periods may indicate performance issues or deadlocks.',
  'Resource exhaustion, connection pool saturation, degraded performance.',
  'Identify and optimize slow queries, add appropriate indexes, or cancel stuck queries.',
  $check$
    SELECT pid::text AS resource_id,
           query AS resource_name,
           jsonb_build_object(
             'pid', pid,
             'duration', now() - query_start,
             'state', state,
             'wait_event', wait_event_type
           ) AS evidence
    FROM pg_stat_activity
    WHERE state != 'idle'
      AND query_start < now() - interval '5 minutes'
      AND query NOT LIKE '%pg_stat_activity%'
  $check$),

-- Performance Checks
('PERF-001', 'performance', 'medium', 'Missing Indexes on Foreign Keys',
  'Foreign key columns without indexes cause slow joins and constraint checks.',
  'Slow queries, degraded performance under load.',
  'Create indexes on foreign key columns.',
  $check$
    SELECT con.conname AS resource_id,
           con.conname AS resource_name,
           jsonb_build_object(
             'constraint', con.conname,
             'table', c.relname,
             'columns', array_agg(a.attname)
           ) AS evidence
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(con.conkey)
    WHERE con.contype = 'f'
      AND NOT EXISTS (
        SELECT 1 FROM pg_index i
        WHERE i.indrelid = c.oid
          AND i.indkey[0] = a.attnum
      )
    GROUP BY con.conname, c.relname
  $check$),

('PERF-002', 'performance', 'low', 'Bloated Tables',
  'Tables with high dead tuple counts need vacuuming to reclaim space.',
  'Wasted storage, slower sequential scans.',
  'Run VACUUM ANALYZE on affected tables or ensure autovacuum is properly configured.',
  $check$
    SELECT schemaname || '.' || relname AS resource_id,
           relname AS resource_name,
           jsonb_build_object(
             'dead_tuples', n_dead_tup,
             'live_tuples', n_live_tup,
             'bloat_ratio', ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2)
           ) AS evidence
    FROM pg_stat_user_tables
    WHERE n_dead_tup > 10000
      AND n_dead_tup > 0.1 * n_live_tup
  $check$),

-- Operational Checks
('OPS-001', 'operational', 'medium', 'Failed Jobs in Last 24 Hours',
  'Scheduled jobs or workflows that have failed recently need attention.',
  'Incomplete operations, data inconsistency, missed SLAs.',
  'Investigate failed jobs, fix underlying issues, and retry if necessary.',
  $check$
    SELECT r.id::text AS resource_id,
           r.job_name AS resource_name,
           jsonb_build_object(
             'system', r.system,
             'job_name', r.job_name,
             'error', r.error_message,
             'ended_at', r.ended_at
           ) AS evidence
    FROM ops.runs r
    WHERE r.status = 'failed'
      AND r.ended_at > now() - interval '24 hours'
  $check$),

('OPS-002', 'operational', 'high', 'Stuck or Long-Running Jobs',
  'Jobs that have been running for an unusually long time may be stuck.',
  'Resource consumption, blocking other operations, incomplete work.',
  'Investigate the job status, check for deadlocks, and consider terminating if stuck.',
  $check$
    SELECT r.id::text AS resource_id,
           r.job_name AS resource_name,
           jsonb_build_object(
             'system', r.system,
             'job_name', r.job_name,
             'started_at', r.started_at,
             'running_for', now() - r.started_at
           ) AS evidence
    FROM ops.runs r
    WHERE r.status IN ('running', 'pending')
      AND r.started_at < now() - interval '1 hour'
  $check$);

-- ============================================================================
-- FUNCTIONS: Advisor Operations
-- ============================================================================

-- Function to run a specific check
CREATE OR REPLACE FUNCTION advisor.run_check(p_check_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check RECORD;
  v_run_id UUID;
  v_start_time TIMESTAMPTZ := now();
  v_findings_created INTEGER := 0;
  v_findings_resolved INTEGER := 0;
  v_result RECORD;
BEGIN
  -- Get check definition
  SELECT * INTO v_check FROM advisor.checks WHERE id = p_check_id AND enabled = TRUE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Check not found or disabled');
  END IF;

  -- Create run record
  INSERT INTO advisor.check_runs (check_id) VALUES (p_check_id) RETURNING id INTO v_run_id;

  -- Execute check query if defined
  IF v_check.check_query IS NOT NULL THEN
    FOR v_result IN EXECUTE v_check.check_query LOOP
      -- Check if finding already exists
      IF NOT EXISTS (
        SELECT 1 FROM advisor.findings
        WHERE check_id = p_check_id
          AND resource_id = v_result.resource_id
          AND status = 'open'
      ) THEN
        -- Create new finding
        INSERT INTO advisor.findings (
          check_id, category, severity,
          title, description, impact, remediation,
          resource_type, resource_id, resource_name,
          evidence
        ) VALUES (
          p_check_id, v_check.category, v_check.severity,
          v_check.title, v_check.description, v_check.impact, v_check.remediation,
          v_check.target_resource_type, v_result.resource_id, v_result.resource_name,
          v_result.evidence
        );
        v_findings_created := v_findings_created + 1;
      ELSE
        -- Update last seen
        UPDATE advisor.findings
        SET last_seen_at = now(),
            occurrence_count = occurrence_count + 1,
            evidence = v_result.evidence,
            updated_at = now()
        WHERE check_id = p_check_id
          AND resource_id = v_result.resource_id
          AND status = 'open';
      END IF;
    END LOOP;

    -- Auto-resolve findings that no longer appear
    UPDATE advisor.findings
    SET status = 'auto_resolved',
        resolved_at = now(),
        resolution_type = 'auto',
        resolution_notes = 'Issue no longer detected by automated check',
        updated_at = now()
    WHERE check_id = p_check_id
      AND status = 'open'
      AND last_seen_at < v_start_time;

    GET DIAGNOSTICS v_findings_resolved = ROW_COUNT;
  END IF;

  -- Update check run
  UPDATE advisor.check_runs
  SET ended_at = now(),
      duration_ms = EXTRACT(MILLISECONDS FROM now() - v_start_time)::INTEGER,
      status = 'success',
      findings_created = v_findings_created,
      findings_resolved = v_findings_resolved
  WHERE id = v_run_id;

  -- Update check last run time
  UPDATE advisor.checks
  SET last_run_at = now(),
      next_run_at = now() + (check_interval_minutes || ' minutes')::INTERVAL,
      updated_at = now()
  WHERE id = p_check_id;

  RETURN jsonb_build_object(
    'check_id', p_check_id,
    'run_id', v_run_id,
    'findings_created', v_findings_created,
    'findings_resolved', v_findings_resolved,
    'duration_ms', EXTRACT(MILLISECONDS FROM now() - v_start_time)::INTEGER
  );
END;
$$;

-- Function to run all enabled checks
CREATE OR REPLACE FUNCTION advisor.run_all_checks()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check RECORD;
  v_results JSONB := '[]'::JSONB;
  v_result JSONB;
BEGIN
  FOR v_check IN SELECT id FROM advisor.checks WHERE enabled = TRUE LOOP
    v_result := advisor.run_check(v_check.id);
    v_results := v_results || jsonb_build_array(v_result);
  END LOOP;

  RETURN v_results;
END;
$$;

-- Function to dismiss a finding
CREATE OR REPLACE FUNCTION advisor.dismiss_finding(
  p_finding_id UUID,
  p_reason TEXT,
  p_dismiss_until TIMESTAMPTZ DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE advisor.findings
  SET status = 'dismissed',
      dismissed_at = now(),
      dismissal_reason = p_reason,
      dismiss_until = p_dismiss_until,
      updated_at = now()
  WHERE id = p_finding_id;
END;
$$;

-- Function to resolve a finding
CREATE OR REPLACE FUNCTION advisor.resolve_finding(
  p_finding_id UUID,
  p_notes TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE advisor.findings
  SET status = 'resolved',
      resolved_at = now(),
      resolution_type = 'manual',
      resolution_notes = p_notes,
      updated_at = now()
  WHERE id = p_finding_id;
END;
$$;

-- Function to get advisor summary
CREATE OR REPLACE FUNCTION advisor.get_summary()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'total_findings', COUNT(*),
    'by_status', jsonb_object_agg(status, cnt),
    'by_severity', (
      SELECT jsonb_object_agg(severity, cnt)
      FROM (SELECT severity, COUNT(*) as cnt FROM advisor.findings WHERE status = 'open' GROUP BY severity) s
    ),
    'by_category', (
      SELECT jsonb_object_agg(category, cnt)
      FROM (SELECT category, COUNT(*) as cnt FROM advisor.findings WHERE status = 'open' GROUP BY category) c
    ),
    'critical_count', COUNT(*) FILTER (WHERE status = 'open' AND severity = 'critical'),
    'last_check_run', (SELECT MAX(ended_at) FROM advisor.check_runs WHERE status = 'success')
  ) INTO v_result
  FROM (SELECT status, COUNT(*) as cnt FROM advisor.findings GROUP BY status) t;

  RETURN v_result;
END;
$$;

-- ============================================================================
-- VIEWS: Convenient access patterns
-- ============================================================================

-- Open findings summary
CREATE OR REPLACE VIEW advisor.v_open_findings AS
SELECT
  f.id,
  f.check_id,
  f.category,
  f.severity,
  f.title,
  f.resource_type,
  f.resource_id,
  f.resource_name,
  f.first_seen_at,
  f.last_seen_at,
  f.occurrence_count,
  f.risk_score,
  f.evidence
FROM advisor.findings f
WHERE f.status = 'open'
ORDER BY
  CASE f.severity
    WHEN 'critical' THEN 1
    WHEN 'high' THEN 2
    WHEN 'medium' THEN 3
    WHEN 'low' THEN 4
    WHEN 'info' THEN 5
  END,
  f.first_seen_at DESC;

-- Findings by category
CREATE OR REPLACE VIEW advisor.v_findings_by_category AS
SELECT
  category,
  COUNT(*) AS total,
  COUNT(*) FILTER (WHERE severity = 'critical') AS critical,
  COUNT(*) FILTER (WHERE severity = 'high') AS high,
  COUNT(*) FILTER (WHERE severity = 'medium') AS medium,
  COUNT(*) FILTER (WHERE severity = 'low') AS low
FROM advisor.findings
WHERE status = 'open'
GROUP BY category
ORDER BY
  COUNT(*) FILTER (WHERE severity IN ('critical', 'high')) DESC,
  COUNT(*) DESC;

-- Recent check runs
CREATE OR REPLACE VIEW advisor.v_recent_check_runs AS
SELECT
  cr.id,
  cr.check_id,
  c.title AS check_title,
  c.category,
  cr.started_at,
  cr.ended_at,
  cr.duration_ms,
  cr.status,
  cr.findings_created,
  cr.findings_resolved
FROM advisor.check_runs cr
JOIN advisor.checks c ON c.id = cr.check_id
WHERE cr.started_at > now() - interval '24 hours'
ORDER BY cr.started_at DESC;

-- Advisor score (0-100)
CREATE OR REPLACE VIEW advisor.v_score AS
SELECT
  ROUND(100 - (
    COALESCE(SUM(CASE severity
      WHEN 'critical' THEN 25
      WHEN 'high' THEN 10
      WHEN 'medium' THEN 3
      WHEN 'low' THEN 1
      ELSE 0
    END), 0)
  )::NUMERIC, 0)::INTEGER AS score,
  COUNT(*) AS total_findings,
  COUNT(*) FILTER (WHERE severity = 'critical') AS critical,
  COUNT(*) FILTER (WHERE severity = 'high') AS high,
  COUNT(*) FILTER (WHERE severity = 'medium') AS medium,
  COUNT(*) FILTER (WHERE severity = 'low') AS low
FROM advisor.findings
WHERE status = 'open';

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Update updated_at on checks
CREATE TRIGGER tr_checks_updated_at
  BEFORE UPDATE ON advisor.checks
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

-- Update updated_at on findings
CREATE TRIGGER tr_findings_updated_at
  BEFORE UPDATE ON advisor.findings
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

-- Update updated_at on recommendations
CREATE TRIGGER tr_recommendations_updated_at
  BEFORE UPDATE ON advisor.recommendations
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON SCHEMA advisor IS 'Azure Advisor-style recommendations and automated checks for security, cost, reliability, and performance';

COMMENT ON TABLE advisor.checks IS 'Definitions of automated checks that can be run against the system';
COMMENT ON TABLE advisor.findings IS 'Individual instances of detected issues from running checks';
COMMENT ON TABLE advisor.check_runs IS 'Audit trail of check executions';
COMMENT ON TABLE advisor.recommendations IS 'High-level recommendations based on aggregated findings';

COMMENT ON FUNCTION advisor.run_check IS 'Execute a specific check and create/update findings';
COMMENT ON FUNCTION advisor.run_all_checks IS 'Execute all enabled checks';
COMMENT ON FUNCTION advisor.dismiss_finding IS 'Dismiss a finding as accepted risk or false positive';
COMMENT ON FUNCTION advisor.resolve_finding IS 'Mark a finding as manually resolved';
COMMENT ON FUNCTION advisor.get_summary IS 'Get summary statistics of advisor findings';
