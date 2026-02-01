-- ============================================================================
-- Platform Kit: PPM Sync Schema
-- Odoo CE (System of Record) ↔ Plane (Execution Engine) Sync Layer
-- ============================================================================

-- Create ppm schema
CREATE SCHEMA IF NOT EXISTS ppm;
COMMENT ON SCHEMA ppm IS 'PPM sync layer for Odoo ↔ Plane bidirectional sync';

-- ============================================================================
-- ENTITY MAPPINGS: Track bidirectional ID linkage
-- ============================================================================

CREATE TYPE ppm.odoo_model AS ENUM (
    'project.portfolio',
    'project.project',
    'project.milestone',
    'project.task',
    'okr.objective',
    'okr.key_result',
    'deployment.activity'
);

CREATE TYPE ppm.plane_entity AS ENUM (
    'workspace',
    'project',
    'cycle',
    'issue',
    'label',
    'state'
);

CREATE TABLE ppm.entity_mappings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Odoo side
    odoo_model ppm.odoo_model NOT NULL,
    odoo_id INTEGER NOT NULL,
    odoo_ref TEXT, -- e.g., "PRJ-001" or WBS code

    -- Plane side
    plane_entity ppm.plane_entity NOT NULL,
    plane_id UUID NOT NULL,
    plane_identifier TEXT, -- e.g., "PROJ-123"
    plane_workspace_id UUID,

    -- Sync metadata
    created_at TIMESTAMPTZ DEFAULT now(),
    last_synced_at TIMESTAMPTZ DEFAULT now(),
    sync_direction TEXT DEFAULT 'odoo_to_plane',
    sync_status TEXT DEFAULT 'synced',
    sync_error TEXT,

    -- Ensure unique mappings
    UNIQUE(odoo_model, odoo_id),
    UNIQUE(plane_entity, plane_id)
);

CREATE INDEX idx_ppm_mappings_odoo ON ppm.entity_mappings(odoo_model, odoo_id);
CREATE INDEX idx_ppm_mappings_plane ON ppm.entity_mappings(plane_entity, plane_id);

-- ============================================================================
-- SYNC EVENTS: Event log for bidirectional sync
-- ============================================================================

CREATE TYPE ppm.sync_source AS ENUM ('odoo', 'plane', 'ci', 'webhook', 'agent');

CREATE TYPE ppm.sync_event_type AS ENUM (
    'create',
    'update',
    'delete',
    'status_change',
    'assignment_change',
    'shipped',
    'deploy_success',
    'deploy_failed',
    'dependency_added',
    'dependency_removed'
);

CREATE TABLE ppm.sync_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Event metadata
    source ppm.sync_source NOT NULL,
    event_type ppm.sync_event_type NOT NULL,
    entity_type TEXT NOT NULL, -- 'project', 'task', 'milestone', etc.
    entity_id TEXT NOT NULL, -- Source system ID

    -- Event payload
    payload JSONB NOT NULL DEFAULT '{}',

    -- Correlation for related events
    correlation_id UUID,

    -- Processing state
    status TEXT DEFAULT 'pending',
    processed_at TIMESTAMPTZ,
    error TEXT,
    retry_count INTEGER DEFAULT 0,

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT now(),

    -- Idempotency
    dedupe_key TEXT GENERATED ALWAYS AS (
        source || ':' || event_type || ':' || entity_type || ':' || entity_id || ':' ||
        COALESCE(payload->>'version', created_at::text)
    ) STORED
);

CREATE UNIQUE INDEX idx_ppm_events_dedupe ON ppm.sync_events(dedupe_key);
CREATE INDEX idx_ppm_events_pending ON ppm.sync_events(status, created_at)
    WHERE status = 'pending';
CREATE INDEX idx_ppm_events_correlation ON ppm.sync_events(correlation_id);

-- ============================================================================
-- DEPLOYMENT TRACKING: CI/CD → Odoo/Plane
-- ============================================================================

CREATE TYPE ppm.deploy_env AS ENUM ('preview', 'staging', 'production');
CREATE TYPE ppm.deploy_status AS ENUM ('pending', 'running', 'success', 'failed', 'cancelled');

CREATE TABLE ppm.deployments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Commit info
    commit_sha TEXT NOT NULL,
    commit_message TEXT,
    branch TEXT,

    -- Environment
    environment ppm.deploy_env NOT NULL,

    -- Pipeline info
    pipeline_run_id TEXT,
    pipeline_url TEXT,

    -- Status
    status ppm.deploy_status DEFAULT 'pending',
    deployed_at TIMESTAMPTZ,
    deployed_by TEXT,

    -- CI verification
    ci_passed BOOLEAN DEFAULT false,
    ci_checks JSONB DEFAULT '[]',

    -- Linked entities (will be synced to Odoo)
    linked_odoo_task_ids INTEGER[] DEFAULT '{}',
    linked_plane_issue_ids UUID[] DEFAULT '{}',

    -- Sync state
    synced_to_odoo BOOLEAN DEFAULT false,
    odoo_activity_id INTEGER,

    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_ppm_deployments_commit ON ppm.deployments(commit_sha);
CREATE INDEX idx_ppm_deployments_status ON ppm.deployments(status, created_at);
CREATE INDEX idx_ppm_deployments_pending_sync ON ppm.deployments(synced_to_odoo)
    WHERE synced_to_odoo = false AND status = 'success';

-- ============================================================================
-- OKR SNAPSHOTS: Track OKR progress over time
-- ============================================================================

CREATE TABLE ppm.okr_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- OKR reference
    odoo_objective_id INTEGER NOT NULL,
    objective_title TEXT NOT NULL,
    time_period TEXT NOT NULL, -- "2026-Q1"

    -- Key results snapshot
    key_results JSONB NOT NULL DEFAULT '[]',
    -- Structure: [{ "id": 1, "metric": "Revenue", "target": 100, "current": 75, "progress": 75 }]

    -- Aggregates
    overall_progress NUMERIC(5,2),
    status TEXT, -- "on_track", "at_risk", "off_track"

    -- Linked milestones and their status
    linked_milestones JSONB DEFAULT '[]',
    -- Structure: [{ "id": 1, "name": "MVP", "progress": 80, "is_shipped": false }]

    snapshot_at TIMESTAMPTZ DEFAULT now(),
    snapshot_type TEXT DEFAULT 'weekly' -- 'weekly', 'monthly', 'quarterly', 'manual'
);

CREATE INDEX idx_ppm_okr_snapshots_objective ON ppm.okr_snapshots(odoo_objective_id, snapshot_at DESC);

-- ============================================================================
-- SYNC STATE: Track last sync cursors
-- ============================================================================

CREATE TABLE ppm.sync_state (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    connector TEXT NOT NULL UNIQUE, -- 'odoo', 'plane', 'github'

    -- Cursor for incremental sync
    last_sync_at TIMESTAMPTZ,
    cursor_value TEXT, -- Could be timestamp, ID, or other cursor

    -- Health
    status TEXT DEFAULT 'healthy',
    last_error TEXT,
    consecutive_failures INTEGER DEFAULT 0,

    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Initialize sync state for our connectors
INSERT INTO ppm.sync_state (connector, status) VALUES
    ('odoo', 'pending'),
    ('plane', 'pending'),
    ('github', 'pending')
ON CONFLICT (connector) DO NOTHING;

-- ============================================================================
-- GOVERNANCE RULES: Configurable enforcement rules
-- ============================================================================

CREATE TABLE ppm.governance_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    rule_code TEXT NOT NULL UNIQUE,
    rule_name TEXT NOT NULL,
    description TEXT,

    -- Rule configuration
    entity_type TEXT NOT NULL, -- 'task', 'milestone', 'deployment', 'okr'
    trigger_event TEXT NOT NULL, -- 'ship', 'close', 'deploy'
    condition JSONB NOT NULL, -- Rule condition as JSON
    action TEXT NOT NULL, -- 'block', 'warn', 'notify'

    -- Error message template
    error_message TEXT,

    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Insert default governance rules
INSERT INTO ppm.governance_rules (rule_code, rule_name, description, entity_type, trigger_event, condition, action, error_message) VALUES
(
    'TASK_BLOCKED_BY_DEPS',
    'Task Cannot Ship if Blocked',
    'Task cannot be marked as shipped if it has unshipped dependencies',
    'task',
    'ship',
    '{"check": "dependencies_shipped", "threshold": 100}',
    'block',
    'Cannot ship: blocked by unshipped dependencies'
),
(
    'MILESTONE_NEEDS_TASKS',
    'Milestone Needs All Tasks Shipped',
    'Milestone cannot be marked as shipped unless all child tasks are shipped',
    'milestone',
    'ship',
    '{"check": "child_tasks_shipped", "threshold": 100}',
    'block',
    'Cannot ship milestone: {count} tasks not shipped'
),
(
    'DEPLOY_NEEDS_CI',
    'Deployment Needs CI Pass',
    'Deployment cannot be marked as success unless CI passed',
    'deployment',
    'deploy',
    '{"check": "ci_passed", "value": true}',
    'block',
    'Cannot mark deployment success: CI not passed'
),
(
    'OKR_NEEDS_MILESTONES',
    'OKR Needs Milestones Shipped',
    'OKR cannot be marked as achieved unless all linked milestones are shipped',
    'okr',
    'close',
    '{"check": "milestones_shipped", "threshold": 100}',
    'block',
    'Cannot close OKR: {count} milestones not shipped'
),
(
    'PARENT_PROGRESS_CHECK',
    'Parent Progress Threshold',
    'Child task cannot close unless parent task is at least 80% complete',
    'task',
    'ship',
    '{"check": "parent_progress", "threshold": 80}',
    'warn',
    'Warning: parent task is only {progress}% complete'
);

-- ============================================================================
-- FUNCTIONS: Sync helpers
-- ============================================================================

-- Get or create entity mapping
CREATE OR REPLACE FUNCTION ppm.get_or_create_mapping(
    p_odoo_model ppm.odoo_model,
    p_odoo_id INTEGER,
    p_plane_entity ppm.plane_entity,
    p_plane_id UUID,
    p_plane_workspace_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    v_mapping_id UUID;
BEGIN
    -- Try to find existing mapping
    SELECT id INTO v_mapping_id
    FROM ppm.entity_mappings
    WHERE odoo_model = p_odoo_model AND odoo_id = p_odoo_id;

    IF v_mapping_id IS NOT NULL THEN
        -- Update plane side if needed
        UPDATE ppm.entity_mappings
        SET plane_entity = p_plane_entity,
            plane_id = p_plane_id,
            plane_workspace_id = COALESCE(p_plane_workspace_id, plane_workspace_id),
            last_synced_at = now()
        WHERE id = v_mapping_id;

        RETURN v_mapping_id;
    END IF;

    -- Create new mapping
    INSERT INTO ppm.entity_mappings (
        odoo_model, odoo_id,
        plane_entity, plane_id, plane_workspace_id
    ) VALUES (
        p_odoo_model, p_odoo_id,
        p_plane_entity, p_plane_id, p_plane_workspace_id
    )
    RETURNING id INTO v_mapping_id;

    RETURN v_mapping_id;
END;
$$ LANGUAGE plpgsql;

-- Record sync event
CREATE OR REPLACE FUNCTION ppm.record_sync_event(
    p_source ppm.sync_source,
    p_event_type ppm.sync_event_type,
    p_entity_type TEXT,
    p_entity_id TEXT,
    p_payload JSONB DEFAULT '{}',
    p_correlation_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    v_event_id UUID;
BEGIN
    INSERT INTO ppm.sync_events (
        source, event_type, entity_type, entity_id,
        payload, correlation_id
    ) VALUES (
        p_source, p_event_type, p_entity_type, p_entity_id,
        p_payload, p_correlation_id
    )
    ON CONFLICT (dedupe_key) DO UPDATE
        SET retry_count = ppm.sync_events.retry_count + 1
    RETURNING id INTO v_event_id;

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

-- Check governance rule
CREATE OR REPLACE FUNCTION ppm.check_governance(
    p_entity_type TEXT,
    p_trigger_event TEXT,
    p_context JSONB
) RETURNS TABLE (
    rule_code TEXT,
    passed BOOLEAN,
    action TEXT,
    message TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        gr.rule_code,
        CASE
            WHEN gr.condition->>'check' = 'dependencies_shipped' THEN
                (p_context->>'dependencies_shipped_pct')::numeric >= (gr.condition->>'threshold')::numeric
            WHEN gr.condition->>'check' = 'child_tasks_shipped' THEN
                (p_context->>'child_tasks_shipped_pct')::numeric >= (gr.condition->>'threshold')::numeric
            WHEN gr.condition->>'check' = 'ci_passed' THEN
                (p_context->>'ci_passed')::boolean = (gr.condition->>'value')::boolean
            WHEN gr.condition->>'check' = 'milestones_shipped' THEN
                (p_context->>'milestones_shipped_pct')::numeric >= (gr.condition->>'threshold')::numeric
            WHEN gr.condition->>'check' = 'parent_progress' THEN
                (p_context->>'parent_progress')::numeric >= (gr.condition->>'threshold')::numeric
            ELSE true
        END AS passed,
        gr.action,
        gr.error_message
    FROM ppm.governance_rules gr
    WHERE gr.entity_type = p_entity_type
      AND gr.trigger_event = p_trigger_event
      AND gr.is_active = true;
END;
$$ LANGUAGE plpgsql;

-- Record deployment from CI/CD webhook
CREATE OR REPLACE FUNCTION ppm.record_deployment(
    p_commit_sha TEXT,
    p_environment ppm.deploy_env,
    p_status ppm.deploy_status,
    p_pipeline_run_id TEXT DEFAULT NULL,
    p_pipeline_url TEXT DEFAULT NULL,
    p_branch TEXT DEFAULT NULL,
    p_commit_message TEXT DEFAULT NULL,
    p_deployed_by TEXT DEFAULT NULL,
    p_ci_passed BOOLEAN DEFAULT NULL,
    p_ci_checks JSONB DEFAULT '[]',
    p_linked_task_ids INTEGER[] DEFAULT '{}'
) RETURNS UUID AS $$
DECLARE
    v_deployment_id UUID;
BEGIN
    INSERT INTO ppm.deployments (
        commit_sha, environment, status,
        pipeline_run_id, pipeline_url, branch, commit_message,
        deployed_by, ci_passed, ci_checks, linked_odoo_task_ids,
        deployed_at
    ) VALUES (
        p_commit_sha, p_environment, p_status,
        p_pipeline_run_id, p_pipeline_url, p_branch, p_commit_message,
        p_deployed_by, COALESCE(p_ci_passed, p_status = 'success'), p_ci_checks, p_linked_task_ids,
        CASE WHEN p_status IN ('success', 'failed') THEN now() ELSE NULL END
    )
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_deployment_id;

    -- Record sync event
    IF v_deployment_id IS NOT NULL AND p_status = 'success' THEN
        PERFORM ppm.record_sync_event(
            'ci'::ppm.sync_source,
            'deploy_success'::ppm.sync_event_type,
            'deployment',
            v_deployment_id::text,
            jsonb_build_object(
                'commit_sha', p_commit_sha,
                'environment', p_environment,
                'linked_task_ids', p_linked_task_ids
            )
        );
    END IF;

    RETURN v_deployment_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- VIEWS: Sync status dashboards
-- ============================================================================

CREATE OR REPLACE VIEW ppm.sync_status AS
SELECT
    ss.connector,
    ss.status,
    ss.last_sync_at,
    ss.consecutive_failures,
    ss.last_error,
    (SELECT COUNT(*) FROM ppm.sync_events se
     WHERE se.source::text = ss.connector AND se.status = 'pending') AS pending_events,
    (SELECT COUNT(*) FROM ppm.sync_events se
     WHERE se.source::text = ss.connector AND se.status = 'failed') AS failed_events
FROM ppm.sync_state ss;

CREATE OR REPLACE VIEW ppm.recent_deployments AS
SELECT
    d.id,
    d.commit_sha,
    d.branch,
    d.environment,
    d.status,
    d.ci_passed,
    d.deployed_at,
    d.deployed_by,
    array_length(d.linked_odoo_task_ids, 1) AS task_count,
    d.synced_to_odoo,
    d.created_at
FROM ppm.deployments d
ORDER BY d.created_at DESC
LIMIT 50;

CREATE OR REPLACE VIEW ppm.pending_syncs AS
SELECT
    se.id,
    se.source,
    se.event_type,
    se.entity_type,
    se.entity_id,
    se.retry_count,
    se.error,
    se.created_at,
    EXTRACT(EPOCH FROM (now() - se.created_at)) / 60 AS age_minutes
FROM ppm.sync_events se
WHERE se.status = 'pending'
ORDER BY se.created_at ASC;

-- ============================================================================
-- RLS POLICIES
-- ============================================================================

ALTER TABLE ppm.entity_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE ppm.sync_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE ppm.deployments ENABLE ROW LEVEL SECURITY;
ALTER TABLE ppm.okr_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE ppm.sync_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE ppm.governance_rules ENABLE ROW LEVEL SECURITY;

-- Service role has full access
CREATE POLICY "Service role full access to entity_mappings"
    ON ppm.entity_mappings FOR ALL TO service_role USING (true);
CREATE POLICY "Service role full access to sync_events"
    ON ppm.sync_events FOR ALL TO service_role USING (true);
CREATE POLICY "Service role full access to deployments"
    ON ppm.deployments FOR ALL TO service_role USING (true);
CREATE POLICY "Service role full access to okr_snapshots"
    ON ppm.okr_snapshots FOR ALL TO service_role USING (true);
CREATE POLICY "Service role full access to sync_state"
    ON ppm.sync_state FOR ALL TO service_role USING (true);
CREATE POLICY "Service role full access to governance_rules"
    ON ppm.governance_rules FOR ALL TO service_role USING (true);

-- Authenticated users can read
CREATE POLICY "Authenticated read entity_mappings"
    ON ppm.entity_mappings FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read sync_events"
    ON ppm.sync_events FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read deployments"
    ON ppm.deployments FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read okr_snapshots"
    ON ppm.okr_snapshots FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read governance_rules"
    ON ppm.governance_rules FOR SELECT TO authenticated USING (true);

COMMENT ON SCHEMA ppm IS 'PPM sync layer for enterprise Odoo ↔ Plane bidirectional synchronization';
