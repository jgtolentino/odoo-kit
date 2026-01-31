-- ============================================================================
-- REPO AUDITOR: Ops Tables for GitHub Repository Auditing
-- ============================================================================
-- Purpose: Track repository audit runs and findings for security hardening
-- Pattern: Scheduled Edge Function crawls repos, detects drift, creates issues
-- ============================================================================

BEGIN;

-- Enable required extensions (pg_cron and pg_net should be available in Supabase)
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- ============================================================================
-- TABLE: ops.repo_audit_runs
-- ============================================================================
-- Purpose: Track each audit run execution
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.repo_audit_runs (
  run_id BIGSERIAL PRIMARY KEY,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'running',  -- running | ok | error
  notes TEXT,
  repos_scanned INTEGER DEFAULT 0,
  findings_count INTEGER DEFAULT 0,
  issues_created INTEGER DEFAULT 0,
  metadata JSONB DEFAULT '{}'::jsonb,

  -- Constraints
  CONSTRAINT repo_audit_runs_status_check CHECK (status IN ('running', 'ok', 'error'))
);

-- Indexes for repo_audit_runs
CREATE INDEX IF NOT EXISTS idx_repo_audit_runs_started_at ON ops.repo_audit_runs (started_at DESC);
CREATE INDEX IF NOT EXISTS idx_repo_audit_runs_status ON ops.repo_audit_runs (status);

-- ============================================================================
-- TABLE: ops.repo_audit_findings
-- ============================================================================
-- Purpose: Track individual findings, deduped by (repo, rule_id, fingerprint)
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.repo_audit_findings (
  finding_id BIGSERIAL PRIMARY KEY,
  repo_full_name TEXT NOT NULL,
  rule_id TEXT NOT NULL,
  severity TEXT NOT NULL,  -- low | med | high | critical
  title TEXT NOT NULL,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  fingerprint TEXT NOT NULL,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  status TEXT NOT NULL DEFAULT 'open',  -- open | ack | fixed | suppressed
  github_issue_number INTEGER,
  github_issue_url TEXT,

  -- Constraints
  CONSTRAINT repo_audit_findings_severity_check CHECK (severity IN ('low', 'med', 'high', 'critical')),
  CONSTRAINT repo_audit_findings_status_check CHECK (status IN ('open', 'ack', 'fixed', 'suppressed')),
  CONSTRAINT repo_audit_findings_unique UNIQUE (repo_full_name, rule_id, fingerprint)
);

-- Indexes for repo_audit_findings
CREATE INDEX IF NOT EXISTS idx_repo_audit_findings_repo ON ops.repo_audit_findings (repo_full_name);
CREATE INDEX IF NOT EXISTS idx_repo_audit_findings_status ON ops.repo_audit_findings (status);
CREATE INDEX IF NOT EXISTS idx_repo_audit_findings_severity ON ops.repo_audit_findings (severity);
CREATE INDEX IF NOT EXISTS idx_repo_audit_findings_last_seen ON ops.repo_audit_findings (last_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_repo_audit_findings_rule ON ops.repo_audit_findings (rule_id);

-- ============================================================================
-- FUNCTIONS: Helpers for repo audit operations
-- ============================================================================

-- Function to upsert a finding
CREATE OR REPLACE FUNCTION ops.upsert_repo_audit_finding(
  p_repo_full_name TEXT,
  p_rule_id TEXT,
  p_severity TEXT,
  p_title TEXT,
  p_details JSONB,
  p_fingerprint TEXT
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_finding_id BIGINT;
BEGIN
  INSERT INTO ops.repo_audit_findings (
    repo_full_name, rule_id, severity, title, details, fingerprint,
    last_seen_at, status
  ) VALUES (
    p_repo_full_name, p_rule_id, p_severity, p_title, p_details, p_fingerprint,
    now(), 'open'
  )
  ON CONFLICT (repo_full_name, rule_id, fingerprint)
  DO UPDATE SET
    last_seen_at = now(),
    severity = EXCLUDED.severity,
    title = EXCLUDED.title,
    details = EXCLUDED.details
  RETURNING finding_id INTO v_finding_id;

  RETURN v_finding_id;
END;
$$;

-- Function to start an audit run
CREATE OR REPLACE FUNCTION ops.start_repo_audit_run(
  p_metadata JSONB DEFAULT '{}'
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_run_id BIGINT;
BEGIN
  INSERT INTO ops.repo_audit_runs (status, metadata)
  VALUES ('running', p_metadata)
  RETURNING run_id INTO v_run_id;

  RETURN v_run_id;
END;
$$;

-- Function to complete an audit run
CREATE OR REPLACE FUNCTION ops.complete_repo_audit_run(
  p_run_id BIGINT,
  p_status TEXT,
  p_notes TEXT DEFAULT NULL,
  p_repos_scanned INTEGER DEFAULT 0,
  p_findings_count INTEGER DEFAULT 0,
  p_issues_created INTEGER DEFAULT 0
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE ops.repo_audit_runs
  SET
    status = p_status,
    finished_at = now(),
    notes = p_notes,
    repos_scanned = p_repos_scanned,
    findings_count = p_findings_count,
    issues_created = p_issues_created
  WHERE run_id = p_run_id;
END;
$$;

-- ============================================================================
-- VIEWS: Convenient access patterns
-- ============================================================================

-- Recent audit runs
CREATE OR REPLACE VIEW ops.v_repo_audit_runs AS
SELECT
  run_id,
  started_at,
  finished_at,
  finished_at - started_at AS duration,
  status,
  repos_scanned,
  findings_count,
  issues_created,
  notes
FROM ops.repo_audit_runs
ORDER BY started_at DESC;

-- Open findings by severity
CREATE OR REPLACE VIEW ops.v_repo_audit_open_findings AS
SELECT
  repo_full_name,
  rule_id,
  severity,
  title,
  first_seen_at,
  last_seen_at,
  github_issue_url,
  details
FROM ops.repo_audit_findings
WHERE status = 'open'
ORDER BY
  CASE severity
    WHEN 'critical' THEN 1
    WHEN 'high' THEN 2
    WHEN 'med' THEN 3
    WHEN 'low' THEN 4
  END,
  last_seen_at DESC;

-- Findings summary by repo
CREATE OR REPLACE VIEW ops.v_repo_audit_summary AS
SELECT
  repo_full_name,
  COUNT(*) FILTER (WHERE status = 'open') AS open_count,
  COUNT(*) FILTER (WHERE status = 'open' AND severity = 'critical') AS critical_count,
  COUNT(*) FILTER (WHERE status = 'open' AND severity = 'high') AS high_count,
  COUNT(*) FILTER (WHERE status = 'open' AND severity = 'med') AS med_count,
  COUNT(*) FILTER (WHERE status = 'open' AND severity = 'low') AS low_count,
  COUNT(*) FILTER (WHERE status = 'fixed') AS fixed_count,
  MAX(last_seen_at) AS last_audited_at
FROM ops.repo_audit_findings
GROUP BY repo_full_name
ORDER BY critical_count DESC, high_count DESC, open_count DESC;

-- ============================================================================
-- RLS POLICIES
-- ============================================================================

-- Enable RLS
ALTER TABLE ops.repo_audit_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.repo_audit_findings ENABLE ROW LEVEL SECURITY;

-- Service role has full access
CREATE POLICY repo_audit_runs_service_policy ON ops.repo_audit_runs
  FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY repo_audit_findings_service_policy ON ops.repo_audit_findings
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Authenticated users have read-only access
CREATE POLICY repo_audit_runs_read_policy ON ops.repo_audit_runs
  FOR SELECT TO authenticated USING (true);

CREATE POLICY repo_audit_findings_read_policy ON ops.repo_audit_findings
  FOR SELECT TO authenticated USING (true);

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE ops.repo_audit_runs IS 'Tracks each repo auditor execution run with timing and results';
COMMENT ON TABLE ops.repo_audit_findings IS 'Individual security/hardening findings per repository, deduped by fingerprint';
COMMENT ON FUNCTION ops.upsert_repo_audit_finding IS 'Upsert a finding, updating last_seen_at if already exists';
COMMENT ON FUNCTION ops.start_repo_audit_run IS 'Start a new audit run and return its ID';
COMMENT ON FUNCTION ops.complete_repo_audit_run IS 'Complete an audit run with final status and metrics';

COMMIT;
