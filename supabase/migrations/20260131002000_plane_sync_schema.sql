-- ============================================================================
-- Plane ↔ Odoo Sync Schema
-- ============================================================================
-- Tracks bidirectional sync state between Plane CE and Odoo.
-- Provides audit trail and conflict resolution capabilities.
-- ============================================================================

-- Create plane schema
CREATE SCHEMA IF NOT EXISTS plane;

-- Grant usage to authenticated users
GRANT USAGE ON SCHEMA plane TO authenticated;
GRANT USAGE ON SCHEMA plane TO service_role;

-- ============================================================================
-- Sync Mappings Table
-- ============================================================================
-- Maps entities between Plane and Odoo for bidirectional sync.
-- Each row represents a linked pair of records.

CREATE TABLE IF NOT EXISTS plane.sync_mappings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Source system (where the record originated)
    source_system TEXT NOT NULL CHECK (source_system IN ('plane', 'odoo')),
    source_id TEXT NOT NULL,
    source_type TEXT NOT NULL,  -- e.g., 'issue', 'project', 'project.task'

    -- Target system (where the record was synced to)
    target_id TEXT NOT NULL,
    target_type TEXT NOT NULL,  -- e.g., 'project.task', 'issue'

    -- Sync metadata
    last_synced_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    sync_version INTEGER NOT NULL DEFAULT 1,
    sync_direction TEXT NOT NULL DEFAULT 'bidirectional'
        CHECK (sync_direction IN ('plane_to_odoo', 'odoo_to_plane', 'bidirectional')),

    -- Status tracking
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'paused', 'error', 'archived')),
    last_error TEXT,
    error_count INTEGER NOT NULL DEFAULT 0,

    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Ensure unique mapping per source
    CONSTRAINT unique_source_mapping UNIQUE (source_system, source_id, source_type)
);

-- Indexes for efficient lookups
CREATE INDEX IF NOT EXISTS idx_sync_mappings_source
    ON plane.sync_mappings(source_system, source_id);
CREATE INDEX IF NOT EXISTS idx_sync_mappings_target
    ON plane.sync_mappings(target_id, target_type);
CREATE INDEX IF NOT EXISTS idx_sync_mappings_status
    ON plane.sync_mappings(status) WHERE status != 'archived';
CREATE INDEX IF NOT EXISTS idx_sync_mappings_last_synced
    ON plane.sync_mappings(last_synced_at);

-- ============================================================================
-- Sync Queue Table
-- ============================================================================
-- Queue for pending sync operations (for retry and batch processing).

CREATE TABLE IF NOT EXISTS plane.sync_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Operation details
    source_system TEXT NOT NULL CHECK (source_system IN ('plane', 'odoo')),
    source_id TEXT NOT NULL,
    source_type TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete', 'archive')),

    -- Payload (JSON data to sync)
    payload JSONB NOT NULL DEFAULT '{}',

    -- Processing status
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'cancelled')),
    priority INTEGER NOT NULL DEFAULT 0,  -- Higher = more urgent

    -- Retry tracking
    attempts INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 3,
    last_attempt_at TIMESTAMPTZ,
    next_attempt_at TIMESTAMPTZ DEFAULT now(),
    last_error TEXT,

    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,

    -- Processing metadata
    worker_id TEXT,  -- Which worker/function is processing
    lock_until TIMESTAMPTZ  -- Optimistic locking
);

-- Indexes for queue processing
CREATE INDEX IF NOT EXISTS idx_sync_queue_pending
    ON plane.sync_queue(next_attempt_at, priority DESC)
    WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_sync_queue_source
    ON plane.sync_queue(source_system, source_id);
CREATE INDEX IF NOT EXISTS idx_sync_queue_status
    ON plane.sync_queue(status, created_at);

-- ============================================================================
-- Sync Config Table
-- ============================================================================
-- Configuration for sync behavior per entity type.

CREATE TABLE IF NOT EXISTS plane.sync_config (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Entity mapping
    plane_type TEXT NOT NULL,  -- e.g., 'issue', 'project'
    odoo_model TEXT NOT NULL,  -- e.g., 'project.task', 'project.project'

    -- Sync settings
    enabled BOOLEAN NOT NULL DEFAULT true,
    direction TEXT NOT NULL DEFAULT 'bidirectional'
        CHECK (direction IN ('plane_to_odoo', 'odoo_to_plane', 'bidirectional')),

    -- Field mappings (JSON)
    field_mappings JSONB NOT NULL DEFAULT '{}',

    -- Conflict resolution
    conflict_resolution TEXT NOT NULL DEFAULT 'latest_wins'
        CHECK (conflict_resolution IN ('latest_wins', 'plane_wins', 'odoo_wins', 'manual')),

    -- Metadata
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT unique_entity_mapping UNIQUE (plane_type, odoo_model)
);

-- Insert default mappings
INSERT INTO plane.sync_config (plane_type, odoo_model, field_mappings) VALUES
    ('issue', 'project.task', '{
        "name": "name",
        "description": "description",
        "priority": "priority",
        "state": "stage_id"
    }'::jsonb),
    ('project', 'project.project', '{
        "name": "name",
        "description": "description"
    }'::jsonb)
ON CONFLICT (plane_type, odoo_model) DO NOTHING;

-- ============================================================================
-- Sync Log Table
-- ============================================================================
-- Detailed log of all sync operations (supplements ops.events).

CREATE TABLE IF NOT EXISTS plane.sync_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Reference to mapping
    mapping_id UUID REFERENCES plane.sync_mappings(id) ON DELETE SET NULL,

    -- Operation details
    source_system TEXT NOT NULL,
    source_id TEXT NOT NULL,
    target_id TEXT,
    operation TEXT NOT NULL,

    -- Status
    success BOOLEAN NOT NULL,
    error_message TEXT,

    -- Data snapshots (for debugging/rollback)
    source_data JSONB,
    target_data JSONB,

    -- Performance
    duration_ms INTEGER,

    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index for recent logs
CREATE INDEX IF NOT EXISTS idx_sync_log_created
    ON plane.sync_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sync_log_mapping
    ON plane.sync_log(mapping_id) WHERE mapping_id IS NOT NULL;

-- Partition by month for performance (optional - uncomment if needed)
-- ALTER TABLE plane.sync_log SET (autovacuum_vacuum_scale_factor = 0.05);

-- ============================================================================
-- Views
-- ============================================================================

-- Active sync pairs
CREATE OR REPLACE VIEW plane.v_active_syncs AS
SELECT
    m.id,
    m.source_system,
    m.source_id,
    m.source_type,
    m.target_id,
    m.target_type,
    m.last_synced_at,
    m.sync_version,
    m.status,
    m.error_count,
    c.enabled AS config_enabled,
    c.direction AS config_direction
FROM plane.sync_mappings m
LEFT JOIN plane.sync_config c
    ON (m.source_system = 'plane' AND m.source_type = c.plane_type)
    OR (m.source_system = 'odoo' AND m.source_type = c.odoo_model)
WHERE m.status = 'active';

-- Pending queue items
CREATE OR REPLACE VIEW plane.v_pending_queue AS
SELECT
    q.*,
    m.target_id,
    m.target_type
FROM plane.sync_queue q
LEFT JOIN plane.sync_mappings m
    ON q.source_system = m.source_system
    AND q.source_id = m.source_id
WHERE q.status = 'pending'
ORDER BY q.priority DESC, q.next_attempt_at ASC;

-- Sync statistics
CREATE OR REPLACE VIEW plane.v_sync_stats AS
SELECT
    source_system,
    source_type,
    COUNT(*) as total_mappings,
    COUNT(*) FILTER (WHERE status = 'active') as active_count,
    COUNT(*) FILTER (WHERE status = 'error') as error_count,
    MAX(last_synced_at) as last_sync,
    AVG(sync_version) as avg_version
FROM plane.sync_mappings
GROUP BY source_system, source_type;

-- ============================================================================
-- Functions
-- ============================================================================

-- Acquire queue item for processing (with locking)
CREATE OR REPLACE FUNCTION plane.acquire_queue_item(p_worker_id TEXT)
RETURNS TABLE (
    id UUID,
    source_system TEXT,
    source_id TEXT,
    source_type TEXT,
    operation TEXT,
    payload JSONB
) AS $$
DECLARE
    v_item plane.sync_queue%ROWTYPE;
BEGIN
    -- Find and lock a pending item
    SELECT * INTO v_item
    FROM plane.sync_queue q
    WHERE q.status = 'pending'
      AND q.next_attempt_at <= now()
      AND (q.lock_until IS NULL OR q.lock_until < now())
    ORDER BY q.priority DESC, q.next_attempt_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- Lock the item
    UPDATE plane.sync_queue
    SET status = 'processing',
        worker_id = p_worker_id,
        lock_until = now() + INTERVAL '5 minutes',
        attempts = attempts + 1,
        last_attempt_at = now()
    WHERE plane.sync_queue.id = v_item.id;

    RETURN QUERY
    SELECT v_item.id, v_item.source_system, v_item.source_id,
           v_item.source_type, v_item.operation, v_item.payload;
END;
$$ LANGUAGE plpgsql;

-- Complete queue item
CREATE OR REPLACE FUNCTION plane.complete_queue_item(
    p_item_id UUID,
    p_success BOOLEAN,
    p_error TEXT DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    IF p_success THEN
        UPDATE plane.sync_queue
        SET status = 'completed',
            completed_at = now(),
            lock_until = NULL
        WHERE id = p_item_id;
    ELSE
        UPDATE plane.sync_queue
        SET status = CASE
                WHEN attempts >= max_attempts THEN 'failed'
                ELSE 'pending'
            END,
            last_error = p_error,
            next_attempt_at = now() + (INTERVAL '1 minute' * power(2, attempts)),
            lock_until = NULL
        WHERE id = p_item_id;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Add item to sync queue
CREATE OR REPLACE FUNCTION plane.enqueue_sync(
    p_source_system TEXT,
    p_source_id TEXT,
    p_source_type TEXT,
    p_operation TEXT,
    p_payload JSONB DEFAULT '{}'::jsonb,
    p_priority INTEGER DEFAULT 0
)
RETURNS UUID AS $$
DECLARE
    v_id UUID;
BEGIN
    INSERT INTO plane.sync_queue (
        source_system, source_id, source_type,
        operation, payload, priority
    ) VALUES (
        p_source_system, p_source_id, p_source_type,
        p_operation, p_payload, p_priority
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- RLS Policies
-- ============================================================================

ALTER TABLE plane.sync_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE plane.sync_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE plane.sync_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE plane.sync_log ENABLE ROW LEVEL SECURITY;

-- Service role has full access
CREATE POLICY "Service role full access on sync_mappings"
    ON plane.sync_mappings FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

CREATE POLICY "Service role full access on sync_queue"
    ON plane.sync_queue FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

CREATE POLICY "Service role full access on sync_config"
    ON plane.sync_config FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

CREATE POLICY "Service role full access on sync_log"
    ON plane.sync_log FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- Authenticated users can read
CREATE POLICY "Authenticated read sync_mappings"
    ON plane.sync_mappings FOR SELECT
    TO authenticated
    USING (true);

CREATE POLICY "Authenticated read sync_config"
    ON plane.sync_config FOR SELECT
    TO authenticated
    USING (true);

CREATE POLICY "Authenticated read sync_log"
    ON plane.sync_log FOR SELECT
    TO authenticated
    USING (true);

-- ============================================================================
-- Triggers
-- ============================================================================

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION plane.update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_sync_mappings_timestamp
    BEFORE UPDATE ON plane.sync_mappings
    FOR EACH ROW EXECUTE FUNCTION plane.update_timestamp();

CREATE TRIGGER update_sync_config_timestamp
    BEFORE UPDATE ON plane.sync_config
    FOR EACH ROW EXECUTE FUNCTION plane.update_timestamp();

-- ============================================================================
-- Comments
-- ============================================================================

COMMENT ON SCHEMA plane IS 'Plane CE integration schema for Odoo sync';
COMMENT ON TABLE plane.sync_mappings IS 'Maps entities between Plane and Odoo';
COMMENT ON TABLE plane.sync_queue IS 'Queue for pending sync operations with retry';
COMMENT ON TABLE plane.sync_config IS 'Configuration for entity type sync behavior';
COMMENT ON TABLE plane.sync_log IS 'Detailed log of sync operations';
