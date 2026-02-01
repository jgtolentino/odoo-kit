-- ============================================================================
-- EVAL SCHEMA: Quality & Drift Detection
-- ============================================================================
-- Purpose: Golden sets, regression testing, scoring, drift alerts
-- Pattern: Define golden → run evaluations → score → detect drift → alert
-- ============================================================================

-- Create eval schema
CREATE SCHEMA IF NOT EXISTS eval;

-- Grant access
GRANT USAGE ON SCHEMA eval TO authenticated;
GRANT USAGE ON SCHEMA eval TO service_role;

-- ============================================================================
-- ENUMS
-- ============================================================================

CREATE TYPE eval.golden_set_type AS ENUM (
  'extraction',   -- Feature extraction golden set
  'parsing',      -- Document parsing golden set
  'classification', -- Classification golden set
  'generation',   -- Content generation golden set
  'entity_resolution', -- Entity matching golden set
  'custom'        -- Custom evaluation type
);

CREATE TYPE eval.alert_severity AS ENUM (
  'info',         -- Informational
  'warning',      -- Needs attention
  'critical'      -- Immediate action required
);

CREATE TYPE eval.alert_status AS ENUM (
  'open',         -- New, needs attention
  'acknowledged', -- Someone is looking at it
  'resolved',     -- Fixed
  'dismissed'     -- False positive or won't fix
);

-- ============================================================================
-- TABLE: eval.golden_sets
-- ============================================================================
-- Purpose: Define test sets for regression testing
-- Pattern: Curated examples with expected outputs
-- ============================================================================

CREATE TABLE eval.golden_sets (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identity
  name TEXT NOT NULL UNIQUE,
  display_name TEXT,
  description TEXT,

  -- Type and scope
  set_type eval.golden_set_type NOT NULL,
  target_component TEXT,                       -- e.g., "deep_research.parser"
  target_version TEXT,                         -- Version being tested

  -- Configuration
  config JSONB DEFAULT '{}',                   -- Evaluation parameters
  scoring_rubric JSONB DEFAULT '{}',           -- How to score results

  -- Thresholds
  min_accuracy REAL DEFAULT 0.95,              -- Minimum acceptable accuracy
  min_precision REAL,
  min_recall REAL,
  min_f1 REAL,
  custom_thresholds JSONB DEFAULT '{}',

  -- Status
  is_active BOOLEAN DEFAULT TRUE,
  is_primary BOOLEAN DEFAULT FALSE,            -- Primary golden set for component

  -- Metrics
  example_count INTEGER DEFAULT 0,
  last_run_at TIMESTAMPTZ,
  last_score REAL,
  baseline_score REAL,                         -- Score when baseline was set

  -- Metadata
  metadata JSONB DEFAULT '{}',
  tags TEXT[] DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  created_by TEXT
);

CREATE INDEX idx_golden_sets_type ON eval.golden_sets(set_type);
CREATE INDEX idx_golden_sets_component ON eval.golden_sets(target_component);
CREATE INDEX idx_golden_sets_active ON eval.golden_sets(is_active) WHERE is_active = TRUE;
CREATE INDEX idx_golden_sets_primary ON eval.golden_sets(target_component, is_primary)
  WHERE is_primary = TRUE;
CREATE INDEX idx_golden_sets_tags ON eval.golden_sets USING gin(tags);

-- ============================================================================
-- TABLE: eval.golden_examples
-- ============================================================================
-- Purpose: Individual examples in a golden set
-- Pattern: Input + expected output pairs
-- ============================================================================

CREATE TABLE eval.golden_examples (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Link to golden set
  golden_set_id UUID NOT NULL REFERENCES eval.golden_sets(id) ON DELETE CASCADE,

  -- Example identity
  example_name TEXT,
  example_order INTEGER,                       -- Order in set (for reproducibility)

  -- Input
  input_data JSONB NOT NULL,                   -- Input to the component
  input_ref TEXT,                              -- Reference to input artifact

  -- Expected output
  expected_output JSONB NOT NULL,              -- Expected result
  expected_ref TEXT,                           -- Reference to expected artifact

  -- Scoring configuration
  weight REAL DEFAULT 1.0,                     -- Weight in overall score
  scoring_config JSONB DEFAULT '{}',           -- Example-specific scoring

  -- Categories
  difficulty TEXT,                             -- easy, medium, hard
  categories TEXT[] DEFAULT '{}',              -- Classification categories

  -- Status
  is_active BOOLEAN DEFAULT TRUE,

  -- Metadata
  notes TEXT,
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_examples_set ON eval.golden_examples(golden_set_id, example_order);
CREATE INDEX idx_examples_active ON eval.golden_examples(golden_set_id, is_active)
  WHERE is_active = TRUE;
CREATE INDEX idx_examples_categories ON eval.golden_examples USING gin(categories);

-- ============================================================================
-- TABLE: eval.eval_runs
-- ============================================================================
-- Purpose: Track evaluation runs
-- ============================================================================

CREATE TABLE eval.eval_runs (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Link to golden set
  golden_set_id UUID NOT NULL REFERENCES eval.golden_sets(id) ON DELETE CASCADE,

  -- Run identity
  run_name TEXT,
  component_version TEXT,                      -- Version of component being tested

  -- Status
  status ops.run_status DEFAULT 'pending',
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,

  -- Metrics
  total_examples INTEGER DEFAULT 0,
  passed_examples INTEGER DEFAULT 0,
  failed_examples INTEGER DEFAULT 0,
  skipped_examples INTEGER DEFAULT 0,

  -- Scores
  accuracy REAL,
  precision_score REAL,
  recall REAL,
  f1_score REAL,
  custom_scores JSONB DEFAULT '{}',

  -- Comparison
  baseline_run_id UUID REFERENCES eval.eval_runs(id),
  score_delta REAL,                            -- Change from baseline
  regression_detected BOOLEAN DEFAULT FALSE,

  -- Links
  ops_run_id UUID REFERENCES ops.runs(id),
  queue_id UUID REFERENCES ops.queue(id),

  -- Configuration
  config JSONB DEFAULT '{}',

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_eval_runs_set ON eval.eval_runs(golden_set_id, created_at DESC);
CREATE INDEX idx_eval_runs_status ON eval.eval_runs(status);
CREATE INDEX idx_eval_runs_regression ON eval.eval_runs(golden_set_id, regression_detected)
  WHERE regression_detected = TRUE;

-- ============================================================================
-- TABLE: eval.scores
-- ============================================================================
-- Purpose: Detailed scores for each example in a run
-- ============================================================================

CREATE TABLE eval.scores (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Links
  eval_run_id UUID NOT NULL REFERENCES eval.eval_runs(id) ON DELETE CASCADE,
  example_id UUID NOT NULL REFERENCES eval.golden_examples(id) ON DELETE CASCADE,

  -- Results
  passed BOOLEAN NOT NULL,
  actual_output JSONB,                         -- What the component produced
  actual_ref TEXT,                             -- Reference to actual artifact

  -- Scoring
  score REAL,                                  -- 0-1 score
  score_breakdown JSONB DEFAULT '{}',          -- Detailed scoring

  -- Comparison
  diff JSONB,                                  -- Difference from expected
  diff_summary TEXT,                           -- Human-readable diff

  -- Errors
  error_message TEXT,
  error_type TEXT,

  -- Timing
  execution_time_ms INTEGER,

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,

  -- Unique constraint
  UNIQUE (eval_run_id, example_id)
);

CREATE INDEX idx_scores_run ON eval.scores(eval_run_id);
CREATE INDEX idx_scores_failed ON eval.scores(eval_run_id, passed) WHERE passed = FALSE;
CREATE INDEX idx_scores_example ON eval.scores(example_id);

-- ============================================================================
-- TABLE: eval.drift_alerts
-- ============================================================================
-- Purpose: Track detected drift and quality regressions
-- ============================================================================

CREATE TABLE eval.drift_alerts (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Alert identity
  alert_type TEXT NOT NULL,                    -- e.g., "regression", "threshold_breach", "anomaly"
  severity eval.alert_severity NOT NULL,
  status eval.alert_status DEFAULT 'open',

  -- Source
  golden_set_id UUID REFERENCES eval.golden_sets(id),
  eval_run_id UUID REFERENCES eval.eval_runs(id),
  component TEXT,

  -- Details
  title TEXT NOT NULL,
  description TEXT,
  metric_name TEXT,                            -- e.g., "accuracy", "f1_score"
  metric_value REAL,
  threshold_value REAL,
  baseline_value REAL,
  delta REAL,

  -- Affected examples
  affected_examples UUID[],
  affected_count INTEGER,

  -- Resolution
  acknowledged_at TIMESTAMPTZ,
  acknowledged_by TEXT,
  resolved_at TIMESTAMPTZ,
  resolved_by TEXT,
  resolution_notes TEXT,

  -- Links
  related_issue_url TEXT,                      -- GitHub/Plane issue
  slack_thread_ts TEXT,                        -- Slack thread

  -- Metadata
  metadata JSONB DEFAULT '{}',
  tags TEXT[] DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_drift_status ON eval.drift_alerts(status);
CREATE INDEX idx_drift_severity ON eval.drift_alerts(severity, status);
CREATE INDEX idx_drift_set ON eval.drift_alerts(golden_set_id);
CREATE INDEX idx_drift_component ON eval.drift_alerts(component);
CREATE INDEX idx_drift_open ON eval.drift_alerts(created_at DESC)
  WHERE status IN ('open', 'acknowledged');
CREATE INDEX idx_drift_tags ON eval.drift_alerts USING gin(tags);

-- ============================================================================
-- TABLE: eval.baselines
-- ============================================================================
-- Purpose: Store baseline scores for comparison
-- ============================================================================

CREATE TABLE eval.baselines (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Link to golden set
  golden_set_id UUID NOT NULL REFERENCES eval.golden_sets(id) ON DELETE CASCADE,

  -- Baseline identity
  name TEXT NOT NULL,
  description TEXT,
  is_current BOOLEAN DEFAULT FALSE,            -- Is this the current baseline?

  -- Source run
  eval_run_id UUID NOT NULL REFERENCES eval.eval_runs(id),

  -- Scores
  accuracy REAL,
  precision_score REAL,
  recall REAL,
  f1_score REAL,
  custom_scores JSONB DEFAULT '{}',

  -- Example-level scores
  example_scores JSONB DEFAULT '{}',           -- {example_id: score}

  -- Configuration
  component_version TEXT,
  config_snapshot JSONB DEFAULT '{}',

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  created_by TEXT,

  -- Unique current baseline per set
  UNIQUE (golden_set_id, name)
);

CREATE INDEX idx_baselines_set ON eval.baselines(golden_set_id);
CREATE INDEX idx_baselines_current ON eval.baselines(golden_set_id, is_current)
  WHERE is_current = TRUE;

-- ============================================================================
-- FUNCTIONS
-- ============================================================================

-- Score an evaluation run
CREATE OR REPLACE FUNCTION eval.score_run(
  p_run_id UUID,
  p_golden_set_id UUID DEFAULT NULL
) RETURNS TABLE(
  accuracy REAL,
  precision_score REAL,
  recall REAL,
  f1_score REAL,
  passed INTEGER,
  failed INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_passed INTEGER;
  v_failed INTEGER;
  v_total INTEGER;
  v_accuracy REAL;
  v_precision REAL;
  v_recall REAL;
  v_f1 REAL;
BEGIN
  -- Count results
  SELECT
    COUNT(*) FILTER (WHERE s.passed = TRUE),
    COUNT(*) FILTER (WHERE s.passed = FALSE),
    COUNT(*)
  INTO v_passed, v_failed, v_total
  FROM eval.scores s
  WHERE s.eval_run_id = p_run_id;

  -- Calculate basic accuracy
  IF v_total > 0 THEN
    v_accuracy := v_passed::REAL / v_total;
  ELSE
    v_accuracy := 0;
  END IF;

  -- For now, precision/recall/f1 are same as accuracy (can be extended)
  v_precision := v_accuracy;
  v_recall := v_accuracy;
  IF v_precision + v_recall > 0 THEN
    v_f1 := 2 * (v_precision * v_recall) / (v_precision + v_recall);
  ELSE
    v_f1 := 0;
  END IF;

  -- Update the run
  UPDATE eval.eval_runs
  SET
    accuracy = v_accuracy,
    precision_score = v_precision,
    recall = v_recall,
    f1_score = v_f1,
    passed_examples = v_passed,
    failed_examples = v_failed,
    total_examples = v_total,
    status = 'success',
    completed_at = now(),
    updated_at = now()
  WHERE id = p_run_id;

  -- Check for regression
  PERFORM eval.check_regression(p_run_id);

  RETURN QUERY SELECT v_accuracy, v_precision, v_recall, v_f1, v_passed, v_failed;
END;
$$;

-- Check for regression against baseline
CREATE OR REPLACE FUNCTION eval.check_regression(
  p_run_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_golden_set_id UUID;
  v_run_accuracy REAL;
  v_baseline_accuracy REAL;
  v_min_accuracy REAL;
  v_delta REAL;
  v_is_regression BOOLEAN := FALSE;
BEGIN
  -- Get run details
  SELECT golden_set_id, accuracy INTO v_golden_set_id, v_run_accuracy
  FROM eval.eval_runs WHERE id = p_run_id;

  -- Get baseline
  SELECT b.accuracy INTO v_baseline_accuracy
  FROM eval.baselines b
  WHERE b.golden_set_id = v_golden_set_id AND b.is_current = TRUE
  LIMIT 1;

  -- Get threshold
  SELECT min_accuracy INTO v_min_accuracy
  FROM eval.golden_sets WHERE id = v_golden_set_id;

  -- Check regression conditions
  IF v_run_accuracy < COALESCE(v_min_accuracy, 0.95) THEN
    v_is_regression := TRUE;
    v_delta := v_run_accuracy - COALESCE(v_min_accuracy, 0.95);
  ELSIF v_baseline_accuracy IS NOT NULL AND v_run_accuracy < v_baseline_accuracy - 0.05 THEN
    -- 5% drop from baseline
    v_is_regression := TRUE;
    v_delta := v_run_accuracy - v_baseline_accuracy;
  END IF;

  -- Update run
  UPDATE eval.eval_runs
  SET
    regression_detected = v_is_regression,
    score_delta = COALESCE(v_delta, v_run_accuracy - v_baseline_accuracy),
    updated_at = now()
  WHERE id = p_run_id;

  -- Create alert if regression
  IF v_is_regression THEN
    INSERT INTO eval.drift_alerts (
      alert_type, severity, title, description,
      golden_set_id, eval_run_id,
      metric_name, metric_value, threshold_value, baseline_value, delta
    ) VALUES (
      'regression',
      CASE WHEN v_delta < -0.10 THEN 'critical'::eval.alert_severity ELSE 'warning'::eval.alert_severity END,
      format('Regression detected in %s', (SELECT name FROM eval.golden_sets WHERE id = v_golden_set_id)),
      format('Accuracy dropped to %.2f%% (baseline: %.2f%%, threshold: %.2f%%)',
        v_run_accuracy * 100,
        COALESCE(v_baseline_accuracy, 0) * 100,
        COALESCE(v_min_accuracy, 0.95) * 100),
      v_golden_set_id, p_run_id,
      'accuracy', v_run_accuracy, v_min_accuracy, v_baseline_accuracy, v_delta
    );
  END IF;

  RETURN v_is_regression;
END;
$$;

-- Set baseline from run
CREATE OR REPLACE FUNCTION eval.set_baseline(
  p_run_id UUID,
  p_name TEXT DEFAULT 'current',
  p_description TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_baseline_id UUID;
  v_golden_set_id UUID;
BEGIN
  -- Get golden set
  SELECT golden_set_id INTO v_golden_set_id
  FROM eval.eval_runs WHERE id = p_run_id;

  -- Clear current baseline
  UPDATE eval.baselines
  SET is_current = FALSE
  WHERE golden_set_id = v_golden_set_id AND is_current = TRUE;

  -- Create new baseline
  INSERT INTO eval.baselines (
    golden_set_id, name, description, is_current,
    eval_run_id, accuracy, precision_score, recall, f1_score, custom_scores
  )
  SELECT
    golden_set_id, p_name, p_description, TRUE,
    p_run_id, accuracy, precision_score, recall, f1_score, custom_scores
  FROM eval.eval_runs
  WHERE id = p_run_id
  ON CONFLICT (golden_set_id, name) DO UPDATE SET
    is_current = TRUE,
    eval_run_id = EXCLUDED.eval_run_id,
    accuracy = EXCLUDED.accuracy,
    precision_score = EXCLUDED.precision_score,
    recall = EXCLUDED.recall,
    f1_score = EXCLUDED.f1_score
  RETURNING id INTO v_baseline_id;

  -- Update golden set
  UPDATE eval.golden_sets
  SET
    baseline_score = (SELECT accuracy FROM eval.eval_runs WHERE id = p_run_id),
    updated_at = now()
  WHERE id = v_golden_set_id;

  RETURN v_baseline_id;
END;
$$;

-- Acknowledge alert
CREATE OR REPLACE FUNCTION eval.acknowledge_alert(
  p_alert_id UUID,
  p_user TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE eval.drift_alerts
  SET
    status = 'acknowledged',
    acknowledged_at = now(),
    acknowledged_by = p_user,
    updated_at = now()
  WHERE id = p_alert_id AND status = 'open';
END;
$$;

-- Resolve alert
CREATE OR REPLACE FUNCTION eval.resolve_alert(
  p_alert_id UUID,
  p_user TEXT,
  p_notes TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE eval.drift_alerts
  SET
    status = 'resolved',
    resolved_at = now(),
    resolved_by = p_user,
    resolution_notes = p_notes,
    updated_at = now()
  WHERE id = p_alert_id AND status IN ('open', 'acknowledged');
END;
$$;

-- ============================================================================
-- VIEWS
-- ============================================================================

-- Current status of all golden sets
CREATE OR REPLACE VIEW eval.v_golden_set_status AS
SELECT
  g.id,
  g.name,
  g.set_type,
  g.target_component,
  g.is_active,
  g.example_count,
  g.min_accuracy,
  g.baseline_score,
  g.last_score,
  g.last_run_at,
  CASE
    WHEN g.last_score IS NULL THEN 'never_run'
    WHEN g.last_score >= g.min_accuracy THEN 'passing'
    ELSE 'failing'
  END as status,
  (SELECT COUNT(*) FROM eval.drift_alerts a
   WHERE a.golden_set_id = g.id AND a.status = 'open') as open_alerts
FROM eval.golden_sets g
WHERE g.is_active = TRUE
ORDER BY g.name;

-- Recent eval runs with results
CREATE OR REPLACE VIEW eval.v_recent_runs AS
SELECT
  r.id,
  g.name as golden_set,
  r.status,
  r.accuracy,
  r.passed_examples,
  r.failed_examples,
  r.regression_detected,
  r.score_delta,
  r.started_at,
  r.completed_at,
  r.completed_at - r.started_at as duration
FROM eval.eval_runs r
JOIN eval.golden_sets g ON r.golden_set_id = g.id
ORDER BY r.started_at DESC
LIMIT 100;

-- Open alerts by severity
CREATE OR REPLACE VIEW eval.v_open_alerts AS
SELECT
  a.id,
  a.severity,
  a.alert_type,
  a.title,
  g.name as golden_set,
  a.metric_name,
  a.metric_value,
  a.threshold_value,
  a.delta,
  a.created_at,
  a.acknowledged_by
FROM eval.drift_alerts a
LEFT JOIN eval.golden_sets g ON a.golden_set_id = g.id
WHERE a.status IN ('open', 'acknowledged')
ORDER BY
  CASE a.severity
    WHEN 'critical' THEN 1
    WHEN 'warning' THEN 2
    ELSE 3
  END,
  a.created_at DESC;

-- Failed examples in recent runs
CREATE OR REPLACE VIEW eval.v_recent_failures AS
SELECT
  s.id,
  g.name as golden_set,
  e.example_name,
  s.error_message,
  s.diff_summary,
  s.score,
  r.started_at as run_time
FROM eval.scores s
JOIN eval.eval_runs r ON s.eval_run_id = r.id
JOIN eval.golden_sets g ON r.golden_set_id = g.id
JOIN eval.golden_examples e ON s.example_id = e.id
WHERE s.passed = FALSE
  AND r.started_at > now() - interval '7 days'
ORDER BY r.started_at DESC, s.score ASC
LIMIT 100;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

CREATE TRIGGER tr_golden_sets_updated_at
  BEFORE UPDATE ON eval.golden_sets
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_golden_examples_updated_at
  BEFORE UPDATE ON eval.golden_examples
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_eval_runs_updated_at
  BEFORE UPDATE ON eval.eval_runs
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_drift_alerts_updated_at
  BEFORE UPDATE ON eval.drift_alerts
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

-- Update example count when examples change
CREATE OR REPLACE FUNCTION eval.update_example_count()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    UPDATE eval.golden_sets
    SET example_count = (
      SELECT COUNT(*) FROM eval.golden_examples
      WHERE golden_set_id = NEW.golden_set_id AND is_active = TRUE
    )
    WHERE id = NEW.golden_set_id;
  END IF;

  IF TG_OP = 'DELETE' THEN
    UPDATE eval.golden_sets
    SET example_count = (
      SELECT COUNT(*) FROM eval.golden_examples
      WHERE golden_set_id = OLD.golden_set_id AND is_active = TRUE
    )
    WHERE id = OLD.golden_set_id;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_update_example_count
  AFTER INSERT OR UPDATE OR DELETE ON eval.golden_examples
  FOR EACH ROW
  EXECUTE FUNCTION eval.update_example_count();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON SCHEMA eval IS 'Quality evaluation, regression testing, and drift detection';

COMMENT ON TABLE eval.golden_sets IS 'Define test sets with expected inputs/outputs for regression testing';
COMMENT ON TABLE eval.golden_examples IS 'Individual test cases within golden sets';
COMMENT ON TABLE eval.eval_runs IS 'Track evaluation runs and their aggregate scores';
COMMENT ON TABLE eval.scores IS 'Per-example scores within evaluation runs';
COMMENT ON TABLE eval.drift_alerts IS 'Alerts for quality regression and drift detection';
COMMENT ON TABLE eval.baselines IS 'Store baseline scores for comparison';
