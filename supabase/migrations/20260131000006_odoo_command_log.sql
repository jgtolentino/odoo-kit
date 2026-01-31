-- ============================================================================
-- ODOO COMMAND LOG: Write Path from Apps to Odoo
-- ============================================================================
-- Purpose: Track all commands sent to Odoo (System of Record)
-- Pattern:
--   App → Supabase Auth → Edge Function → This Log → Odoo API
--
-- This ensures:
-- - Full audit trail of all Odoo writes
-- - Idempotent command execution
-- - Retry capability for failed commands
-- - Multi-company context tracking
-- ============================================================================

-- ============================================================================
-- TABLE: ops.user_odoo_map
-- ============================================================================
-- Purpose: Map Supabase users to Odoo user/company context
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.user_odoo_map (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Supabase user
  supabase_user_id UUID NOT NULL UNIQUE,

  -- Odoo context
  odoo_db TEXT NOT NULL,
  odoo_uid INTEGER NOT NULL,
  odoo_company_id INTEGER NOT NULL,
  odoo_partner_id INTEGER,

  -- Access control
  allowed_models TEXT[] DEFAULT '{}',         -- Models user can access
  allowed_methods TEXT[] DEFAULT '{}',        -- Methods user can call
  is_admin BOOLEAN DEFAULT FALSE,

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_user_odoo_map_user ON ops.user_odoo_map(supabase_user_id);
CREATE INDEX idx_user_odoo_map_odoo ON ops.user_odoo_map(odoo_db, odoo_uid);

-- Enable RLS
ALTER TABLE ops.user_odoo_map ENABLE ROW LEVEL SECURITY;

-- Service role manages mappings
CREATE POLICY "Service role has full access to user_odoo_map"
  ON ops.user_odoo_map FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Users can read their own mapping
CREATE POLICY "Users can read their own mapping"
  ON ops.user_odoo_map FOR SELECT
  TO authenticated
  USING (auth.uid() = supabase_user_id);

-- ============================================================================
-- TABLE: ops.odoo_command_log
-- ============================================================================
-- Purpose: Log all commands sent to Odoo for audit and retry
-- ============================================================================

CREATE TYPE ops.command_status AS ENUM (
  'queued',       -- Waiting to be processed
  'processing',   -- Currently being executed
  'done',         -- Successfully completed
  'error',        -- Failed after all retries
  'cancelled'     -- Manually cancelled
);

CREATE TABLE IF NOT EXISTS ops.odoo_command_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Who initiated
  supabase_user_id UUID,
  odoo_user_id INTEGER,
  odoo_company_id INTEGER,

  -- Idempotency
  idempotency_key TEXT NOT NULL UNIQUE,

  -- Command details
  command_type TEXT NOT NULL,                 -- e.g., "execute_kw", "create", "write"
  model TEXT,                                 -- e.g., "res.partner"
  method TEXT,                                -- e.g., "create", "write", "unlink"
  payload JSONB NOT NULL,                     -- Full command payload

  -- Execution status
  status ops.command_status NOT NULL DEFAULT 'queued',
  attempts INTEGER DEFAULT 0,
  max_attempts INTEGER DEFAULT 3,

  -- Results
  result JSONB,
  error_message TEXT,
  error_details JSONB,

  -- Timing
  queued_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,

  -- Metadata
  metadata JSONB DEFAULT '{}',
  tags TEXT[] DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- Indexes
CREATE INDEX idx_odoo_command_user ON ops.odoo_command_log(supabase_user_id);
CREATE INDEX idx_odoo_command_status ON ops.odoo_command_log(status);
CREATE INDEX idx_odoo_command_queued ON ops.odoo_command_log(queued_at DESC);
CREATE INDEX idx_odoo_command_pending ON ops.odoo_command_log(status, attempts)
  WHERE status IN ('queued', 'processing');
CREATE INDEX idx_odoo_command_model ON ops.odoo_command_log(model, method);
CREATE INDEX idx_odoo_command_tags ON ops.odoo_command_log USING gin(tags);

-- Enable RLS
ALTER TABLE ops.odoo_command_log ENABLE ROW LEVEL SECURITY;

-- Service role has full access
CREATE POLICY "Service role has full access to odoo_command_log"
  ON ops.odoo_command_log FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Users can insert their own commands
CREATE POLICY "Users can insert their own commands"
  ON ops.odoo_command_log FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = supabase_user_id);

-- Users can read their own commands
CREATE POLICY "Users can read their own commands"
  ON ops.odoo_command_log FOR SELECT
  TO authenticated
  USING (auth.uid() = supabase_user_id);

-- ============================================================================
-- FUNCTIONS: Command helpers
-- ============================================================================

-- Function to queue a command
CREATE OR REPLACE FUNCTION ops.queue_odoo_command(
  p_command_type TEXT,
  p_model TEXT,
  p_method TEXT,
  p_payload JSONB,
  p_idempotency_key TEXT DEFAULT NULL,
  p_tags TEXT[] DEFAULT '{}'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_command_id UUID;
  v_user_id UUID;
  v_odoo_context RECORD;
BEGIN
  -- Get current user
  v_user_id := auth.uid();

  -- Get Odoo context for user
  SELECT odoo_uid, odoo_company_id
  INTO v_odoo_context
  FROM ops.user_odoo_map
  WHERE supabase_user_id = v_user_id;

  -- Insert command
  INSERT INTO ops.odoo_command_log (
    supabase_user_id,
    odoo_user_id,
    odoo_company_id,
    idempotency_key,
    command_type,
    model,
    method,
    payload,
    tags
  ) VALUES (
    v_user_id,
    v_odoo_context.odoo_uid,
    v_odoo_context.odoo_company_id,
    COALESCE(p_idempotency_key, gen_random_uuid()::TEXT),
    p_command_type,
    p_model,
    p_method,
    p_payload,
    p_tags
  )
  RETURNING id INTO v_command_id;

  RETURN v_command_id;
END;
$$;

-- Function to process next queued command (for workers)
CREATE OR REPLACE FUNCTION ops.claim_next_command()
RETURNS ops.odoo_command_log
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_command ops.odoo_command_log;
BEGIN
  UPDATE ops.odoo_command_log
  SET
    status = 'processing',
    started_at = now(),
    attempts = attempts + 1,
    updated_at = now()
  WHERE id = (
    SELECT id
    FROM ops.odoo_command_log
    WHERE status = 'queued'
      OR (status = 'processing' AND started_at < now() - interval '5 minutes')
    ORDER BY queued_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED
  )
  RETURNING * INTO v_command;

  RETURN v_command;
END;
$$;

-- Function to complete a command
CREATE OR REPLACE FUNCTION ops.complete_command(
  p_command_id UUID,
  p_result JSONB
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE ops.odoo_command_log
  SET
    status = 'done',
    result = p_result,
    completed_at = now(),
    updated_at = now()
  WHERE id = p_command_id;
END;
$$;

-- Function to fail a command
CREATE OR REPLACE FUNCTION ops.fail_command(
  p_command_id UUID,
  p_error_message TEXT,
  p_error_details JSONB DEFAULT NULL,
  p_retry BOOLEAN DEFAULT TRUE
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_command ops.odoo_command_log;
BEGIN
  SELECT * INTO v_command
  FROM ops.odoo_command_log
  WHERE id = p_command_id;

  IF p_retry AND v_command.attempts < v_command.max_attempts THEN
    UPDATE ops.odoo_command_log
    SET
      status = 'queued',
      error_message = p_error_message,
      error_details = p_error_details,
      started_at = NULL,
      updated_at = now()
    WHERE id = p_command_id;
  ELSE
    UPDATE ops.odoo_command_log
    SET
      status = 'error',
      error_message = p_error_message,
      error_details = p_error_details,
      completed_at = now(),
      updated_at = now()
    WHERE id = p_command_id;
  END IF;
END;
$$;

-- ============================================================================
-- VIEWS: Command monitoring
-- ============================================================================

-- Pending commands
CREATE OR REPLACE VIEW ops.v_pending_commands AS
SELECT
  id,
  command_type,
  model,
  method,
  status,
  attempts,
  max_attempts,
  queued_at,
  started_at,
  EXTRACT(EPOCH FROM (now() - queued_at)) AS seconds_waiting
FROM ops.odoo_command_log
WHERE status IN ('queued', 'processing')
ORDER BY queued_at ASC;

-- Recent command stats
CREATE OR REPLACE VIEW ops.v_command_stats AS
SELECT
  DATE_TRUNC('hour', queued_at) AS hour,
  command_type,
  model,
  COUNT(*) AS total,
  COUNT(*) FILTER (WHERE status = 'done') AS succeeded,
  COUNT(*) FILTER (WHERE status = 'error') AS failed,
  AVG(EXTRACT(EPOCH FROM (completed_at - queued_at))) FILTER (WHERE completed_at IS NOT NULL) AS avg_duration_seconds
FROM ops.odoo_command_log
WHERE queued_at > now() - interval '24 hours'
GROUP BY DATE_TRUNC('hour', queued_at), command_type, model
ORDER BY hour DESC;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

CREATE TRIGGER tr_user_odoo_map_updated_at
  BEFORE UPDATE ON ops.user_odoo_map
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_odoo_command_log_updated_at
  BEFORE UPDATE ON ops.odoo_command_log
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE ops.user_odoo_map IS 'Maps Supabase users to their Odoo user/company context';
COMMENT ON TABLE ops.odoo_command_log IS 'Audit log of all commands sent to Odoo. Supports idempotent execution and retries.';

COMMENT ON FUNCTION ops.queue_odoo_command IS 'Queue a command to be executed against Odoo';
COMMENT ON FUNCTION ops.claim_next_command IS 'Claim the next queued command for processing (used by workers)';
COMMENT ON FUNCTION ops.complete_command IS 'Mark a command as successfully completed';
COMMENT ON FUNCTION ops.fail_command IS 'Mark a command as failed, with optional retry';
