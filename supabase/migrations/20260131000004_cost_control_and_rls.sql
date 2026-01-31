-- ============================================================================
-- COST CONTROL & RLS POLICIES
-- ============================================================================
-- Purpose: Azure Cost Advisor equivalent + Security policies
-- Pattern:
--   - Materialized views for cost tracking
--   - RLS policies for multi-tenant security
--   - Anomaly detection views
-- ============================================================================

-- ============================================================================
-- COST TRACKING TABLES
-- ============================================================================

-- Table to track Edge Function invocations
CREATE TABLE IF NOT EXISTS ops.cost_edge_invocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Function identification
  function_name TEXT NOT NULL,
  function_version TEXT,

  -- Metrics
  invocation_count BIGINT DEFAULT 0,
  execution_time_ms_total BIGINT DEFAULT 0,
  memory_mb_seconds DECIMAL(15, 4) DEFAULT 0,

  -- Cost estimation (based on Supabase pricing)
  estimated_cost_usd DECIMAL(15, 6) DEFAULT 0,

  -- Time window
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  granularity TEXT DEFAULT 'hourly',          -- 'hourly', 'daily', 'monthly'

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,

  -- Prevent duplicates
  UNIQUE (function_name, period_start, granularity)
);

CREATE INDEX idx_cost_edge_function ON ops.cost_edge_invocations(function_name);
CREATE INDEX idx_cost_edge_period ON ops.cost_edge_invocations(period_start DESC);
CREATE INDEX idx_cost_edge_cost ON ops.cost_edge_invocations(estimated_cost_usd DESC);

-- Table to track database query costs
CREATE TABLE IF NOT EXISTS ops.cost_db_queries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Query identification
  query_hash TEXT,                            -- Hash of normalized query
  query_pattern TEXT,                         -- Normalized query pattern

  -- Statistics
  call_count BIGINT DEFAULT 0,
  total_time_ms DECIMAL(15, 2) DEFAULT 0,
  mean_time_ms DECIMAL(15, 2) DEFAULT 0,
  rows_returned_total BIGINT DEFAULT 0,

  -- Cost factors
  shared_blks_read BIGINT DEFAULT 0,          -- Disk reads
  shared_blks_hit BIGINT DEFAULT 0,           -- Cache hits

  -- Time window
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,

  UNIQUE (query_hash, period_start)
);

CREATE INDEX idx_cost_db_hash ON ops.cost_db_queries(query_hash);
CREATE INDEX idx_cost_db_period ON ops.cost_db_queries(period_start DESC);
CREATE INDEX idx_cost_db_time ON ops.cost_db_queries(total_time_ms DESC);

-- Table to track storage growth
CREATE TABLE IF NOT EXISTS ops.cost_storage_growth (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Resource identification
  resource_type TEXT NOT NULL,                -- 'database', 'storage', 'backups'
  resource_name TEXT,                         -- Table name, bucket name, etc.

  -- Size metrics
  size_bytes BIGINT NOT NULL,
  size_bytes_delta BIGINT DEFAULT 0,          -- Change since last measurement

  -- Cost estimation
  estimated_cost_usd_monthly DECIMAL(15, 6) DEFAULT 0,

  -- Time
  measured_at TIMESTAMPTZ DEFAULT now() NOT NULL,

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_cost_storage_type ON ops.cost_storage_growth(resource_type);
CREATE INDEX idx_cost_storage_measured ON ops.cost_storage_growth(measured_at DESC);
CREATE INDEX idx_cost_storage_size ON ops.cost_storage_growth(size_bytes DESC);

-- ============================================================================
-- COST ANOMALY DETECTION VIEW
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_cost_anomalies AS
WITH recent_edge AS (
  SELECT
    function_name,
    SUM(invocation_count) AS recent_invocations,
    SUM(estimated_cost_usd) AS recent_cost
  FROM ops.cost_edge_invocations
  WHERE period_start > now() - interval '24 hours'
  GROUP BY function_name
),
baseline_edge AS (
  SELECT
    function_name,
    AVG(daily_invocations) AS avg_invocations,
    AVG(daily_cost) AS avg_cost,
    STDDEV(daily_invocations) AS stddev_invocations
  FROM (
    SELECT
      function_name,
      date_trunc('day', period_start) AS day,
      SUM(invocation_count) AS daily_invocations,
      SUM(estimated_cost_usd) AS daily_cost
    FROM ops.cost_edge_invocations
    WHERE period_start > now() - interval '30 days'
      AND period_start < now() - interval '24 hours'
    GROUP BY function_name, date_trunc('day', period_start)
  ) daily
  GROUP BY function_name
)
SELECT
  'edge_function' AS resource_type,
  r.function_name AS resource_name,
  r.recent_invocations AS current_value,
  b.avg_invocations AS baseline_value,
  CASE
    WHEN b.stddev_invocations > 0 THEN
      (r.recent_invocations - b.avg_invocations) / b.stddev_invocations
    ELSE 0
  END AS z_score,
  CASE
    WHEN r.recent_invocations > b.avg_invocations * 3 THEN 'critical'
    WHEN r.recent_invocations > b.avg_invocations * 2 THEN 'high'
    WHEN r.recent_invocations > b.avg_invocations * 1.5 THEN 'medium'
    ELSE 'normal'
  END AS severity,
  r.recent_cost AS estimated_cost_usd,
  now() AS detected_at
FROM recent_edge r
LEFT JOIN baseline_edge b ON b.function_name = r.function_name
WHERE r.recent_invocations > COALESCE(b.avg_invocations * 1.5, 1000);

-- ============================================================================
-- COST SUMMARY VIEW
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_cost_summary AS
SELECT
  'edge_functions' AS category,
  SUM(estimated_cost_usd) AS cost_usd_24h,
  SUM(invocation_count) AS volume_24h
FROM ops.cost_edge_invocations
WHERE period_start > now() - interval '24 hours'
UNION ALL
SELECT
  'database' AS category,
  NULL AS cost_usd_24h,
  SUM(call_count) AS volume_24h
FROM ops.cost_db_queries
WHERE period_start > now() - interval '24 hours'
UNION ALL
SELECT
  'storage' AS category,
  MAX(estimated_cost_usd_monthly) AS cost_usd_24h,
  MAX(size_bytes) AS volume_24h
FROM ops.cost_storage_growth
WHERE measured_at > now() - interval '24 hours';

-- ============================================================================
-- FUNCTION: Record Cost Metrics
-- ============================================================================

CREATE OR REPLACE FUNCTION ops.record_edge_cost(
  p_function_name TEXT,
  p_invocations BIGINT,
  p_execution_time_ms BIGINT,
  p_memory_mb_seconds DECIMAL DEFAULT 0
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_period_start TIMESTAMPTZ;
  v_period_end TIMESTAMPTZ;
  v_cost DECIMAL;
BEGIN
  -- Calculate hourly window
  v_period_start := date_trunc('hour', now());
  v_period_end := v_period_start + interval '1 hour';

  -- Estimate cost (Supabase pricing: ~$2 per million invocations)
  v_cost := p_invocations * 0.000002;

  -- Upsert the record
  INSERT INTO ops.cost_edge_invocations (
    function_name, invocation_count, execution_time_ms_total,
    memory_mb_seconds, estimated_cost_usd,
    period_start, period_end
  ) VALUES (
    p_function_name, p_invocations, p_execution_time_ms,
    p_memory_mb_seconds, v_cost,
    v_period_start, v_period_end
  )
  ON CONFLICT (function_name, period_start, granularity)
  DO UPDATE SET
    invocation_count = ops.cost_edge_invocations.invocation_count + EXCLUDED.invocation_count,
    execution_time_ms_total = ops.cost_edge_invocations.execution_time_ms_total + EXCLUDED.execution_time_ms_total,
    memory_mb_seconds = ops.cost_edge_invocations.memory_mb_seconds + EXCLUDED.memory_mb_seconds,
    estimated_cost_usd = ops.cost_edge_invocations.estimated_cost_usd + EXCLUDED.estimated_cost_usd;
END;
$$;

-- Function to collect storage metrics
CREATE OR REPLACE FUNCTION ops.collect_storage_metrics()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_table RECORD;
  v_prev_size BIGINT;
BEGIN
  -- Collect database table sizes
  FOR v_table IN
    SELECT
      schemaname,
      relname,
      pg_total_relation_size(relid) AS total_size
    FROM pg_stat_user_tables
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  LOOP
    -- Get previous size
    SELECT size_bytes INTO v_prev_size
    FROM ops.cost_storage_growth
    WHERE resource_type = 'database'
      AND resource_name = v_table.schemaname || '.' || v_table.relname
    ORDER BY measured_at DESC
    LIMIT 1;

    -- Insert new measurement
    INSERT INTO ops.cost_storage_growth (
      resource_type, resource_name,
      size_bytes, size_bytes_delta,
      estimated_cost_usd_monthly
    ) VALUES (
      'database',
      v_table.schemaname || '.' || v_table.relname,
      v_table.total_size,
      v_table.total_size - COALESCE(v_prev_size, v_table.total_size),
      -- Estimate: ~$0.125 per GB per month
      v_table.total_size::DECIMAL / 1073741824 * 0.125
    );
  END LOOP;
END;
$$;

-- ============================================================================
-- ROW LEVEL SECURITY POLICIES
-- ============================================================================

-- Enable RLS on all ops tables
ALTER TABLE ops.runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.health ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.cost_edge_invocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.cost_db_queries ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.cost_storage_growth ENABLE ROW LEVEL SECURITY;

-- Enable RLS on advisor tables
ALTER TABLE advisor.checks ENABLE ROW LEVEL SECURITY;
ALTER TABLE advisor.findings ENABLE ROW LEVEL SECURITY;
ALTER TABLE advisor.check_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE advisor.recommendations ENABLE ROW LEVEL SECURITY;

-- Enable RLS on mirror tables
ALTER TABLE mirror.res_company ENABLE ROW LEVEL SECURITY;
ALTER TABLE mirror.res_partner ENABLE ROW LEVEL SECURITY;
ALTER TABLE mirror.account_move ENABLE ROW LEVEL SECURITY;
ALTER TABLE mirror.sale_order ENABLE ROW LEVEL SECURITY;
ALTER TABLE mirror.product_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE mirror.res_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE mirror.sync_log ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- OPS SCHEMA POLICIES
-- ============================================================================

-- Service role has full access to ops tables
CREATE POLICY "Service role has full access to runs"
  ON ops.runs FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to events"
  ON ops.events FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to health"
  ON ops.health FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to cost_edge"
  ON ops.cost_edge_invocations FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to cost_db"
  ON ops.cost_db_queries FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to cost_storage"
  ON ops.cost_storage_growth FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Authenticated users can read ops data
CREATE POLICY "Authenticated users can read runs"
  ON ops.runs FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can read events"
  ON ops.events FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can read health"
  ON ops.health FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can read cost_edge"
  ON ops.cost_edge_invocations FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can read cost_db"
  ON ops.cost_db_queries FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can read cost_storage"
  ON ops.cost_storage_growth FOR SELECT
  TO authenticated
  USING (true);

-- ============================================================================
-- ADVISOR SCHEMA POLICIES
-- ============================================================================

-- Service role has full access
CREATE POLICY "Service role has full access to checks"
  ON advisor.checks FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to findings"
  ON advisor.findings FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to check_runs"
  ON advisor.check_runs FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to recommendations"
  ON advisor.recommendations FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Authenticated users can read advisor data
CREATE POLICY "Authenticated users can read checks"
  ON advisor.checks FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can read findings"
  ON advisor.findings FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can read check_runs"
  ON advisor.check_runs FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can read recommendations"
  ON advisor.recommendations FOR SELECT
  TO authenticated
  USING (true);

-- Authenticated users can update finding status
CREATE POLICY "Authenticated users can update findings"
  ON advisor.findings FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- ============================================================================
-- MIRROR SCHEMA POLICIES (Multi-tenant by company_id)
-- ============================================================================

-- Helper function to get user's company_id from JWT
CREATE OR REPLACE FUNCTION mirror.get_user_company_id()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN COALESCE(
    (auth.jwt() -> 'user_metadata' ->> 'company_id')::INTEGER,
    (auth.jwt() -> 'app_metadata' ->> 'company_id')::INTEGER,
    NULL
  );
END;
$$;

-- Service role has full access to mirror tables
CREATE POLICY "Service role has full access to res_company"
  ON mirror.res_company FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to res_partner"
  ON mirror.res_partner FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to account_move"
  ON mirror.account_move FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to sale_order"
  ON mirror.sale_order FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to product_template"
  ON mirror.product_template FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to res_users"
  ON mirror.res_users FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Service role has full access to sync_log"
  ON mirror.sync_log FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Authenticated users can read their company's data
CREATE POLICY "Users can read their company"
  ON mirror.res_company FOR SELECT
  TO authenticated
  USING (
    id = mirror.get_user_company_id()
    OR parent_id = mirror.get_user_company_id()
    OR mirror.get_user_company_id() IS NULL  -- Fallback for users without company
  );

CREATE POLICY "Users can read their company partners"
  ON mirror.res_partner FOR SELECT
  TO authenticated
  USING (
    company_id = mirror.get_user_company_id()
    OR company_id IS NULL
    OR mirror.get_user_company_id() IS NULL
  );

CREATE POLICY "Users can read their company invoices"
  ON mirror.account_move FOR SELECT
  TO authenticated
  USING (
    company_id = mirror.get_user_company_id()
    OR mirror.get_user_company_id() IS NULL
  );

CREATE POLICY "Users can read their company orders"
  ON mirror.sale_order FOR SELECT
  TO authenticated
  USING (
    company_id = mirror.get_user_company_id()
    OR mirror.get_user_company_id() IS NULL
  );

CREATE POLICY "Users can read their company products"
  ON mirror.product_template FOR SELECT
  TO authenticated
  USING (
    company_id = mirror.get_user_company_id()
    OR company_id IS NULL
    OR mirror.get_user_company_id() IS NULL
  );

CREATE POLICY "Users can read their company users"
  ON mirror.res_users FOR SELECT
  TO authenticated
  USING (
    company_id = mirror.get_user_company_id()
    OR mirror.get_user_company_id() IS NULL
  );

CREATE POLICY "Users can read sync_log"
  ON mirror.sync_log FOR SELECT
  TO authenticated
  USING (true);

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE ops.cost_edge_invocations IS 'Tracks Edge Function invocations and estimated costs';
COMMENT ON TABLE ops.cost_db_queries IS 'Tracks database query statistics for cost analysis';
COMMENT ON TABLE ops.cost_storage_growth IS 'Tracks storage growth and estimated monthly costs';

COMMENT ON VIEW ops.v_cost_anomalies IS 'Detects cost anomalies using statistical analysis (z-score)';
COMMENT ON VIEW ops.v_cost_summary IS 'Summary of costs across all categories for last 24 hours';

COMMENT ON FUNCTION ops.record_edge_cost IS 'Record Edge Function invocations for cost tracking';
COMMENT ON FUNCTION ops.collect_storage_metrics IS 'Collect and store current storage metrics';
COMMENT ON FUNCTION mirror.get_user_company_id IS 'Extract company_id from JWT for RLS policies';
