-- ============================================================================
-- STORAGE BUCKETS & RLS POLICIES
-- ============================================================================
-- Purpose: Configure Storage buckets and Row Level Security for all schemas
-- Pattern: service_role writes, authenticated reads (where appropriate)
-- ============================================================================

-- ============================================================================
-- STORAGE BUCKETS
-- ============================================================================

-- Create artifacts bucket for ops artifacts
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'artifacts',
  'artifacts',
  FALSE,
  52428800, -- 50MB
  ARRAY['application/json', 'text/plain', 'text/html', 'text/csv', 'image/png', 'image/jpeg', 'image/webp', 'application/pdf']
) ON CONFLICT (id) DO UPDATE SET
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Create raw bucket for raw fetches/downloads
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'raw',
  'raw',
  FALSE,
  104857600, -- 100MB
  NULL -- Allow all types
) ON CONFLICT (id) DO UPDATE SET
  file_size_limit = EXCLUDED.file_size_limit;

-- Create exports bucket for CMS/report exports
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'exports',
  'exports',
  FALSE,
  52428800, -- 50MB
  ARRAY['application/json', 'text/csv', 'text/markdown', 'text/html', 'application/pdf', 'application/zip']
) ON CONFLICT (id) DO UPDATE SET
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ============================================================================
-- STORAGE POLICIES
-- ============================================================================

-- artifacts bucket: service_role full access, authenticated read
CREATE POLICY "service_role full access to artifacts"
ON storage.objects FOR ALL
TO service_role
USING (bucket_id = 'artifacts')
WITH CHECK (bucket_id = 'artifacts');

CREATE POLICY "authenticated read artifacts"
ON storage.objects FOR SELECT
TO authenticated
USING (bucket_id = 'artifacts');

-- raw bucket: service_role only
CREATE POLICY "service_role full access to raw"
ON storage.objects FOR ALL
TO service_role
USING (bucket_id = 'raw')
WITH CHECK (bucket_id = 'raw');

-- exports bucket: service_role full access, authenticated read
CREATE POLICY "service_role full access to exports"
ON storage.objects FOR ALL
TO service_role
USING (bucket_id = 'exports')
WITH CHECK (bucket_id = 'exports');

CREATE POLICY "authenticated read exports"
ON storage.objects FOR SELECT
TO authenticated
USING (bucket_id = 'exports');

-- ============================================================================
-- RLS POLICIES: OPS SCHEMA
-- ============================================================================

-- Enable RLS on ops tables
ALTER TABLE ops.queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.artifacts ENABLE ROW LEVEL SECURITY;

-- ops.queue: service_role full access
CREATE POLICY "service_role full access to queue"
ON ops.queue FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- ops.queue: authenticated read
CREATE POLICY "authenticated read queue"
ON ops.queue FOR SELECT
TO authenticated
USING (TRUE);

-- ops.artifacts: service_role full access
CREATE POLICY "service_role full access to artifacts"
ON ops.artifacts FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- ops.artifacts: authenticated read
CREATE POLICY "authenticated read artifacts"
ON ops.artifacts FOR SELECT
TO authenticated
USING (TRUE);

-- ============================================================================
-- RLS POLICIES: CONNECTORS SCHEMA
-- ============================================================================

-- Enable RLS on connectors tables
ALTER TABLE connectors.targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE connectors.health_checks ENABLE ROW LEVEL SECURITY;
ALTER TABLE connectors.webhooks_inbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE connectors.sync_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE connectors.entity_mappings ENABLE ROW LEVEL SECURITY;

-- connectors.targets: service_role full access
CREATE POLICY "service_role full access to targets"
ON connectors.targets FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- connectors.targets: authenticated read
CREATE POLICY "authenticated read targets"
ON connectors.targets FOR SELECT
TO authenticated
USING (TRUE);

-- connectors.health_checks: service_role full access
CREATE POLICY "service_role full access to health_checks"
ON connectors.health_checks FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- connectors.health_checks: authenticated read
CREATE POLICY "authenticated read health_checks"
ON connectors.health_checks FOR SELECT
TO authenticated
USING (TRUE);

-- connectors.webhooks_inbox: service_role only (contains sensitive data)
CREATE POLICY "service_role full access to webhooks_inbox"
ON connectors.webhooks_inbox FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- connectors.sync_state: service_role full access
CREATE POLICY "service_role full access to sync_state"
ON connectors.sync_state FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- connectors.sync_state: authenticated read
CREATE POLICY "authenticated read sync_state"
ON connectors.sync_state FOR SELECT
TO authenticated
USING (TRUE);

-- connectors.entity_mappings: service_role full access
CREATE POLICY "service_role full access to entity_mappings"
ON connectors.entity_mappings FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- connectors.entity_mappings: authenticated read
CREATE POLICY "authenticated read entity_mappings"
ON connectors.entity_mappings FOR SELECT
TO authenticated
USING (TRUE);

-- ============================================================================
-- RLS POLICIES: DEEP_RESEARCH SCHEMA
-- ============================================================================

-- Enable RLS on deep_research tables
ALTER TABLE deep_research.raw_fetches ENABLE ROW LEVEL SECURITY;
ALTER TABLE deep_research.parsed_docs ENABLE ROW LEVEL SECURITY;
ALTER TABLE deep_research.features ENABLE ROW LEVEL SECURITY;
ALTER TABLE deep_research.entities ENABLE ROW LEVEL SECURITY;
ALTER TABLE deep_research.entity_sources ENABLE ROW LEVEL SECURITY;

-- deep_research: service_role full access to all tables
CREATE POLICY "service_role full access to raw_fetches"
ON deep_research.raw_fetches FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to parsed_docs"
ON deep_research.parsed_docs FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to features"
ON deep_research.features FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to entities"
ON deep_research.entities FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to entity_sources"
ON deep_research.entity_sources FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- deep_research: authenticated read for all tables
CREATE POLICY "authenticated read raw_fetches"
ON deep_research.raw_fetches FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read parsed_docs"
ON deep_research.parsed_docs FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read features"
ON deep_research.features FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read entities"
ON deep_research.entities FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read entity_sources"
ON deep_research.entity_sources FOR SELECT
TO authenticated
USING (TRUE);

-- ============================================================================
-- RLS POLICIES: CMS SCHEMA
-- ============================================================================

-- Enable RLS on cms tables
ALTER TABLE cms.sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE cms.items ENABLE ROW LEVEL SECURITY;
ALTER TABLE cms.templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE cms.publications ENABLE ROW LEVEL SECURITY;
ALTER TABLE cms.publication_runs ENABLE ROW LEVEL SECURITY;

-- cms: service_role full access to all tables
CREATE POLICY "service_role full access to cms_sources"
ON cms.sources FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to cms_items"
ON cms.items FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to cms_templates"
ON cms.templates FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to cms_publications"
ON cms.publications FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to cms_publication_runs"
ON cms.publication_runs FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- cms: authenticated read for all tables
CREATE POLICY "authenticated read cms_sources"
ON cms.sources FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read cms_items"
ON cms.items FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read cms_templates"
ON cms.templates FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read cms_publications"
ON cms.publications FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read cms_publication_runs"
ON cms.publication_runs FOR SELECT
TO authenticated
USING (TRUE);

-- ============================================================================
-- RLS POLICIES: EVAL SCHEMA
-- ============================================================================

-- Enable RLS on eval tables
ALTER TABLE eval.golden_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE eval.golden_examples ENABLE ROW LEVEL SECURITY;
ALTER TABLE eval.eval_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE eval.scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE eval.drift_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE eval.baselines ENABLE ROW LEVEL SECURITY;

-- eval: service_role full access to all tables
CREATE POLICY "service_role full access to golden_sets"
ON eval.golden_sets FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to golden_examples"
ON eval.golden_examples FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to eval_runs"
ON eval.eval_runs FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to scores"
ON eval.scores FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to drift_alerts"
ON eval.drift_alerts FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

CREATE POLICY "service_role full access to baselines"
ON eval.baselines FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- eval: authenticated read for all tables
CREATE POLICY "authenticated read golden_sets"
ON eval.golden_sets FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read golden_examples"
ON eval.golden_examples FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read eval_runs"
ON eval.eval_runs FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read scores"
ON eval.scores FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read drift_alerts"
ON eval.drift_alerts FOR SELECT
TO authenticated
USING (TRUE);

CREATE POLICY "authenticated read baselines"
ON eval.baselines FOR SELECT
TO authenticated
USING (TRUE);

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON POLICY "service_role full access to queue" ON ops.queue IS 'Only service_role (Edge Functions, cron) can write to queue';
COMMENT ON POLICY "authenticated read queue" ON ops.queue IS 'All authenticated users can read queue status';
