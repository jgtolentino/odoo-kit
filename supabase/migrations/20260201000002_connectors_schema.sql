-- ============================================================================
-- CONNECTORS SCHEMA: External System Integration State
-- ============================================================================
-- Purpose: Track connections to Plane, Odoo, Mailgun, Slack, and other systems
-- Pattern: Store config (not secrets), health status, webhook inbox
-- ============================================================================

-- Create connectors schema
CREATE SCHEMA IF NOT EXISTS connectors;

-- Grant access
GRANT USAGE ON SCHEMA connectors TO authenticated;
GRANT USAGE ON SCHEMA connectors TO service_role;

-- ============================================================================
-- ENUMS
-- ============================================================================

CREATE TYPE connectors.connector_type AS ENUM (
  'plane',        -- Plane project management
  'odoo',         -- Odoo ERP
  'mailgun',      -- Email service
  'slack',        -- Slack messaging
  'github',       -- GitHub repositories
  'superset',     -- Superset dashboards
  'custom'        -- Custom integrations
);

CREATE TYPE connectors.connector_status AS ENUM (
  'active',       -- Working normally
  'degraded',     -- Partial functionality
  'error',        -- Connection failed
  'disabled',     -- Manually disabled
  'pending'       -- Awaiting setup
);

CREATE TYPE connectors.sync_direction AS ENUM (
  'inbound',      -- External → Supabase
  'outbound',     -- Supabase → External
  'bidirectional' -- Both directions
);

-- ============================================================================
-- TABLE: connectors.targets
-- ============================================================================
-- Purpose: Configuration for each external system connection
-- Note: Secrets are stored in Vault, only references here
-- ============================================================================

CREATE TABLE connectors.targets (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identity
  name TEXT NOT NULL UNIQUE,                   -- e.g., "production-odoo", "ipai-plane"
  connector_type connectors.connector_type NOT NULL,
  display_name TEXT,                           -- Human-readable name

  -- Connection config (no secrets!)
  base_url TEXT,                               -- e.g., "https://plane.ipai.dev"
  api_version TEXT,                            -- e.g., "v1", "19.0"

  -- Vault references for secrets
  secret_key_ref TEXT,                         -- Vault secret name for API key
  oauth_token_ref TEXT,                        -- Vault secret name for OAuth token

  -- Sync configuration
  sync_direction connectors.sync_direction DEFAULT 'bidirectional',
  sync_enabled BOOLEAN DEFAULT TRUE,
  sync_interval_minutes INTEGER DEFAULT 15,
  last_sync_at TIMESTAMPTZ,

  -- Status
  status connectors.connector_status DEFAULT 'pending',
  last_health_check TIMESTAMPTZ,
  health_message TEXT,

  -- Feature flags
  features JSONB DEFAULT '{}',                 -- e.g., {"webhooks": true, "bulk_sync": false}

  -- Metadata
  metadata JSONB DEFAULT '{}',
  tags TEXT[] DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  created_by TEXT
);

CREATE INDEX idx_targets_type ON connectors.targets(connector_type);
CREATE INDEX idx_targets_status ON connectors.targets(status);
CREATE INDEX idx_targets_sync ON connectors.targets(sync_enabled, last_sync_at)
  WHERE sync_enabled = TRUE;

-- ============================================================================
-- TABLE: connectors.health_checks
-- ============================================================================
-- Purpose: Time-series health check results for each target
-- ============================================================================

CREATE TABLE connectors.health_checks (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Link to target
  target_id UUID NOT NULL REFERENCES connectors.targets(id) ON DELETE CASCADE,

  -- Check results
  is_healthy BOOLEAN NOT NULL,
  response_time_ms INTEGER,                    -- API response time
  status_code INTEGER,                         -- HTTP status code
  error_message TEXT,

  -- Details
  check_type TEXT DEFAULT 'ping',              -- e.g., "ping", "auth", "sync_test"
  details JSONB DEFAULT '{}',

  -- Audit
  checked_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_health_target ON connectors.health_checks(target_id, checked_at DESC);
CREATE INDEX idx_health_recent ON connectors.health_checks(checked_at DESC)
  WHERE checked_at > now() - interval '24 hours';
CREATE INDEX idx_health_failures ON connectors.health_checks(target_id, checked_at DESC)
  WHERE is_healthy = FALSE;

-- ============================================================================
-- TABLE: connectors.webhooks_inbox
-- ============================================================================
-- Purpose: Capture inbound webhook events from external systems
-- Pattern: Receive → store raw → enqueue processing job
-- ============================================================================

CREATE TABLE connectors.webhooks_inbox (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Source identification
  target_id UUID REFERENCES connectors.targets(id),
  source_type connectors.connector_type NOT NULL,
  source_identifier TEXT,                      -- e.g., repo name, workspace ID

  -- Request details
  event_type TEXT NOT NULL,                    -- e.g., "issue.created", "invoice.paid"
  event_id TEXT,                               -- External event ID for deduplication

  -- Payload
  headers JSONB DEFAULT '{}',                  -- Request headers (sanitized)
  payload JSONB NOT NULL,                      -- Raw webhook payload

  -- Processing status
  processed BOOLEAN DEFAULT FALSE,
  processed_at TIMESTAMPTZ,
  queue_id UUID REFERENCES ops.queue(id),      -- Link to processing job
  processing_error TEXT,

  -- Verification
  signature_valid BOOLEAN,                     -- Webhook signature verified
  signature_header TEXT,                       -- Which header contained signature

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  received_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  ip_address INET,
  user_agent TEXT
);

CREATE UNIQUE INDEX idx_webhooks_dedupe ON connectors.webhooks_inbox(source_type, event_id)
  WHERE event_id IS NOT NULL;
CREATE INDEX idx_webhooks_unprocessed ON connectors.webhooks_inbox(source_type, received_at)
  WHERE processed = FALSE;
CREATE INDEX idx_webhooks_target ON connectors.webhooks_inbox(target_id, received_at DESC)
  WHERE target_id IS NOT NULL;
CREATE INDEX idx_webhooks_type ON connectors.webhooks_inbox(source_type, event_type);
CREATE INDEX idx_webhooks_recent ON connectors.webhooks_inbox(received_at DESC);

-- ============================================================================
-- TABLE: connectors.sync_state
-- ============================================================================
-- Purpose: Track sync cursors and state for each entity type
-- Pattern: Store high-water marks, last IDs, checksums
-- ============================================================================

CREATE TABLE connectors.sync_state (
  -- Composite primary key
  target_id UUID NOT NULL REFERENCES connectors.targets(id) ON DELETE CASCADE,
  entity_type TEXT NOT NULL,                   -- e.g., "issues", "invoices", "contacts"

  -- Sync cursors
  last_sync_at TIMESTAMPTZ,
  last_id TEXT,                                -- Last synced record ID
  last_updated TEXT,                           -- Last updated timestamp (string for flexibility)
  cursor TEXT,                                 -- Pagination cursor if API supports

  -- Metrics
  total_synced BIGINT DEFAULT 0,
  last_batch_size INTEGER,
  errors_since_success INTEGER DEFAULT 0,

  -- State
  sync_in_progress BOOLEAN DEFAULT FALSE,
  locked_by TEXT,                              -- Worker ID holding lock
  locked_at TIMESTAMPTZ,

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,

  PRIMARY KEY (target_id, entity_type)
);

CREATE INDEX idx_sync_state_progress ON connectors.sync_state(target_id)
  WHERE sync_in_progress = TRUE;

-- ============================================================================
-- TABLE: connectors.entity_mappings
-- ============================================================================
-- Purpose: Map IDs between systems (e.g., Plane issue ID ↔ Supabase ID)
-- Pattern: Maintain bidirectional lookups for linked records
-- ============================================================================

CREATE TABLE connectors.entity_mappings (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Target system
  target_id UUID NOT NULL REFERENCES connectors.targets(id) ON DELETE CASCADE,

  -- Entity identification
  entity_type TEXT NOT NULL,                   -- e.g., "issue", "invoice", "contact"

  -- IDs on each side
  local_id TEXT NOT NULL,                      -- Our ID (usually UUID)
  remote_id TEXT NOT NULL,                     -- Their ID

  -- Sync metadata
  last_synced_at TIMESTAMPTZ DEFAULT now(),
  local_version TEXT,                          -- Version/etag on our side
  remote_version TEXT,                         -- Version/etag on their side
  in_sync BOOLEAN DEFAULT TRUE,                -- Are versions aligned?

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,

  -- Unique constraints for lookups
  UNIQUE (target_id, entity_type, local_id),
  UNIQUE (target_id, entity_type, remote_id)
);

CREATE INDEX idx_mappings_local ON connectors.entity_mappings(target_id, entity_type, local_id);
CREATE INDEX idx_mappings_remote ON connectors.entity_mappings(target_id, entity_type, remote_id);
CREATE INDEX idx_mappings_out_of_sync ON connectors.entity_mappings(target_id)
  WHERE in_sync = FALSE;

-- ============================================================================
-- FUNCTIONS: Connector Operations
-- ============================================================================

-- Record a health check result
CREATE OR REPLACE FUNCTION connectors.record_health(
  p_target_id UUID,
  p_is_healthy BOOLEAN,
  p_response_time_ms INTEGER DEFAULT NULL,
  p_status_code INTEGER DEFAULT NULL,
  p_error_message TEXT DEFAULT NULL,
  p_check_type TEXT DEFAULT 'ping',
  p_details JSONB DEFAULT '{}'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_health_id UUID;
BEGIN
  -- Insert health check record
  INSERT INTO connectors.health_checks (
    target_id, is_healthy, response_time_ms,
    status_code, error_message, check_type, details
  ) VALUES (
    p_target_id, p_is_healthy, p_response_time_ms,
    p_status_code, p_error_message, p_check_type, p_details
  )
  RETURNING id INTO v_health_id;

  -- Update target status
  UPDATE connectors.targets
  SET
    status = CASE
      WHEN p_is_healthy THEN 'active'::connectors.connector_status
      ELSE 'error'::connectors.connector_status
    END,
    last_health_check = now(),
    health_message = p_error_message,
    updated_at = now()
  WHERE id = p_target_id;

  RETURN v_health_id;
END;
$$;

-- Ingest a webhook event
CREATE OR REPLACE FUNCTION connectors.ingest_webhook(
  p_source_type connectors.connector_type,
  p_event_type TEXT,
  p_payload JSONB,
  p_event_id TEXT DEFAULT NULL,
  p_headers JSONB DEFAULT '{}',
  p_source_identifier TEXT DEFAULT NULL,
  p_signature_valid BOOLEAN DEFAULT NULL,
  p_ip_address INET DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_webhook_id UUID;
  v_target_id UUID;
BEGIN
  -- Try to find matching target
  SELECT id INTO v_target_id
  FROM connectors.targets
  WHERE connector_type = p_source_type
    AND status = 'active'
  LIMIT 1;

  -- Insert webhook record
  INSERT INTO connectors.webhooks_inbox (
    target_id, source_type, source_identifier,
    event_type, event_id, headers, payload,
    signature_valid, ip_address, user_agent
  ) VALUES (
    v_target_id, p_source_type, p_source_identifier,
    p_event_type, p_event_id, p_headers, p_payload,
    p_signature_valid, p_ip_address, p_user_agent
  )
  ON CONFLICT (source_type, event_id) WHERE event_id IS NOT NULL
  DO UPDATE SET
    payload = EXCLUDED.payload,
    headers = EXCLUDED.headers,
    received_at = now()
  RETURNING id INTO v_webhook_id;

  RETURN v_webhook_id;
END;
$$;

-- Get or create entity mapping
CREATE OR REPLACE FUNCTION connectors.get_or_create_mapping(
  p_target_id UUID,
  p_entity_type TEXT,
  p_local_id TEXT,
  p_remote_id TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_mapping_id UUID;
BEGIN
  -- Try to find existing mapping
  SELECT id INTO v_mapping_id
  FROM connectors.entity_mappings
  WHERE target_id = p_target_id
    AND entity_type = p_entity_type
    AND (local_id = p_local_id OR remote_id = p_remote_id);

  IF v_mapping_id IS NOT NULL THEN
    -- Update if needed
    UPDATE connectors.entity_mappings
    SET
      local_id = p_local_id,
      remote_id = p_remote_id,
      updated_at = now()
    WHERE id = v_mapping_id;
    RETURN v_mapping_id;
  END IF;

  -- Create new mapping
  INSERT INTO connectors.entity_mappings (
    target_id, entity_type, local_id, remote_id
  ) VALUES (
    p_target_id, p_entity_type, p_local_id, p_remote_id
  )
  RETURNING id INTO v_mapping_id;

  RETURN v_mapping_id;
END;
$$;

-- ============================================================================
-- VIEWS
-- ============================================================================

-- Current status of all connectors
CREATE OR REPLACE VIEW connectors.v_status AS
SELECT
  t.id,
  t.name,
  t.connector_type,
  t.display_name,
  t.status,
  t.sync_enabled,
  t.last_sync_at,
  t.last_health_check,
  t.health_message,
  h.response_time_ms as last_response_time,
  (SELECT COUNT(*) FROM connectors.webhooks_inbox w
   WHERE w.target_id = t.id AND w.processed = FALSE) as pending_webhooks
FROM connectors.targets t
LEFT JOIN LATERAL (
  SELECT response_time_ms
  FROM connectors.health_checks hc
  WHERE hc.target_id = t.id
  ORDER BY checked_at DESC
  LIMIT 1
) h ON TRUE;

-- Unprocessed webhooks
CREATE OR REPLACE VIEW connectors.v_pending_webhooks AS
SELECT
  w.id,
  w.source_type,
  w.event_type,
  w.event_id,
  w.received_at,
  t.name as target_name,
  w.payload
FROM connectors.webhooks_inbox w
LEFT JOIN connectors.targets t ON w.target_id = t.id
WHERE w.processed = FALSE
ORDER BY w.received_at ASC;

-- Sync health by target/entity
CREATE OR REPLACE VIEW connectors.v_sync_health AS
SELECT
  t.name as target_name,
  t.connector_type,
  s.entity_type,
  s.last_sync_at,
  s.total_synced,
  s.last_batch_size,
  s.errors_since_success,
  s.sync_in_progress,
  now() - s.last_sync_at as time_since_sync
FROM connectors.sync_state s
JOIN connectors.targets t ON s.target_id = t.id
ORDER BY t.name, s.entity_type;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Update updated_at on targets
CREATE TRIGGER tr_targets_updated_at
  BEFORE UPDATE ON connectors.targets
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

-- Update updated_at on sync_state
CREATE TRIGGER tr_sync_state_updated_at
  BEFORE UPDATE ON connectors.sync_state
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

-- Update updated_at on entity_mappings
CREATE TRIGGER tr_entity_mappings_updated_at
  BEFORE UPDATE ON connectors.entity_mappings
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON SCHEMA connectors IS 'External system integration state - Plane, Odoo, Mailgun, Slack connectors';

COMMENT ON TABLE connectors.targets IS 'Configuration for each external system connection. Secrets in Vault, not here.';
COMMENT ON TABLE connectors.health_checks IS 'Time-series health check results for each connector.';
COMMENT ON TABLE connectors.webhooks_inbox IS 'Inbound webhook events from external systems awaiting processing.';
COMMENT ON TABLE connectors.sync_state IS 'Sync cursors and state for incremental syncs.';
COMMENT ON TABLE connectors.entity_mappings IS 'ID mappings between systems for linked records.';
