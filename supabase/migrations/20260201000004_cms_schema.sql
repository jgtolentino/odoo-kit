-- ============================================================================
-- CMS SCHEMA: Content Automation & Publishing Pipeline
-- ============================================================================
-- Purpose: Content creation, templating, and multi-channel publishing
-- Pattern: sources → items → templates → publications
-- ============================================================================

-- Create cms schema
CREATE SCHEMA IF NOT EXISTS cms;

-- Grant access
GRANT USAGE ON SCHEMA cms TO authenticated;
GRANT USAGE ON SCHEMA cms TO service_role;

-- ============================================================================
-- ENUMS
-- ============================================================================

CREATE TYPE cms.source_type AS ENUM (
  'feed',         -- RSS/Atom feed
  'scrape',       -- Web scraping
  'api',          -- External API
  'document',     -- Document upload
  'manual',       -- Manual entry
  'generated'     -- AI-generated
);

CREATE TYPE cms.item_status AS ENUM (
  'draft',        -- Work in progress
  'review',       -- Awaiting review
  'approved',     -- Ready to publish
  'published',    -- Published to at least one channel
  'archived',     -- No longer active
  'rejected'      -- Rejected during review
);

CREATE TYPE cms.publication_channel AS ENUM (
  'linkedin',     -- LinkedIn posts
  'slack',        -- Slack messages
  'email',        -- Email newsletter
  'blog',         -- Blog/website
  'twitter',      -- Twitter/X
  'discord',      -- Discord
  'custom'        -- Custom channel
);

CREATE TYPE cms.publication_status AS ENUM (
  'pending',      -- Scheduled but not sent
  'sending',      -- Currently being sent
  'sent',         -- Successfully published
  'failed',       -- Publication failed
  'cancelled'     -- Cancelled before sending
);

-- ============================================================================
-- TABLE: cms.sources
-- ============================================================================
-- Purpose: Define content sources (feeds, scrapers, APIs)
-- Pattern: Configure source → schedule fetch → create items
-- ============================================================================

CREATE TABLE cms.sources (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identity
  name TEXT NOT NULL UNIQUE,
  display_name TEXT,
  source_type cms.source_type NOT NULL,

  -- Configuration
  url TEXT,                                    -- Feed URL, API endpoint, etc.
  config JSONB DEFAULT '{}',                   -- Source-specific config

  -- Scheduling
  is_active BOOLEAN DEFAULT TRUE,
  fetch_interval_minutes INTEGER DEFAULT 60,
  last_fetched_at TIMESTAMPTZ,
  next_fetch_at TIMESTAMPTZ,

  -- Processing
  default_template_id UUID,                    -- Default template for items
  auto_approve BOOLEAN DEFAULT FALSE,          -- Skip review for trusted sources
  transform_config JSONB DEFAULT '{}',         -- Transformation rules

  -- Metrics
  total_items INTEGER DEFAULT 0,
  successful_fetches INTEGER DEFAULT 0,
  failed_fetches INTEGER DEFAULT 0,

  -- Metadata
  metadata JSONB DEFAULT '{}',
  tags TEXT[] DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  created_by TEXT
);

CREATE INDEX idx_sources_type ON cms.sources(source_type);
CREATE INDEX idx_sources_active ON cms.sources(is_active, next_fetch_at)
  WHERE is_active = TRUE;
CREATE INDEX idx_sources_tags ON cms.sources USING gin(tags);

-- ============================================================================
-- TABLE: cms.items
-- ============================================================================
-- Purpose: Content items (drafts, articles, posts)
-- Pattern: Source produces items → items go through workflow → publish
-- ============================================================================

CREATE TABLE cms.items (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identity
  title TEXT NOT NULL,
  slug TEXT,
  source_id UUID REFERENCES cms.sources(id) ON DELETE SET NULL,

  -- Content
  content TEXT,                                -- Main content (markdown/text)
  content_html TEXT,                           -- Rendered HTML
  summary TEXT,                                -- Short summary/excerpt
  content_type TEXT DEFAULT 'article',         -- article, digest, announcement, etc.

  -- Media
  featured_image TEXT,                         -- Image URL
  media JSONB DEFAULT '[]',                    -- Additional media [{type, url, alt}]

  -- Status and workflow
  status cms.item_status DEFAULT 'draft',
  reviewed_at TIMESTAMPTZ,
  reviewed_by TEXT,
  review_notes TEXT,

  -- Categorization
  category TEXT,
  subcategory TEXT,
  tags TEXT[] DEFAULT '{}',

  -- SEO and metadata
  meta_title TEXT,
  meta_description TEXT,
  keywords TEXT[],
  canonical_url TEXT,

  -- References
  source_url TEXT,                             -- Original source URL
  source_id_external TEXT,                     -- ID from source system
  references JSONB DEFAULT '[]',               -- [{title, url}]

  -- Scheduling
  publish_at TIMESTAMPTZ,                      -- Scheduled publish time
  expires_at TIMESTAMPTZ,                      -- When to auto-archive

  -- Engagement (post-publish)
  view_count INTEGER DEFAULT 0,
  engagement_data JSONB DEFAULT '{}',

  -- Versioning
  version INTEGER DEFAULT 1,
  previous_version_id UUID REFERENCES cms.items(id),

  -- AI/Generation context
  generation_prompt TEXT,
  generation_model TEXT,
  generation_metadata JSONB DEFAULT '{}',

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  created_by TEXT,
  updated_by TEXT
);

CREATE UNIQUE INDEX idx_items_slug ON cms.items(slug) WHERE slug IS NOT NULL;
CREATE INDEX idx_items_source ON cms.items(source_id);
CREATE INDEX idx_items_status ON cms.items(status);
CREATE INDEX idx_items_publish_at ON cms.items(publish_at)
  WHERE status = 'approved' AND publish_at IS NOT NULL;
CREATE INDEX idx_items_category ON cms.items(category, subcategory);
CREATE INDEX idx_items_tags ON cms.items USING gin(tags);
CREATE INDEX idx_items_search ON cms.items USING gin(to_tsvector('english', COALESCE(title, '') || ' ' || COALESCE(content, '') || ' ' || COALESCE(summary, '')));
CREATE INDEX idx_items_created ON cms.items(created_at DESC);

-- ============================================================================
-- TABLE: cms.templates
-- ============================================================================
-- Purpose: Templates for content generation and formatting
-- Pattern: Define template → apply to items → generate output
-- ============================================================================

CREATE TABLE cms.templates (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identity
  name TEXT NOT NULL UNIQUE,
  display_name TEXT,
  description TEXT,

  -- Template content
  template_type TEXT DEFAULT 'prompt',         -- prompt, layout, email, social
  content TEXT NOT NULL,                       -- Template content (with placeholders)
  format TEXT DEFAULT 'text',                  -- text, markdown, html, mjml

  -- Target channels
  channels cms.publication_channel[] DEFAULT '{}',

  -- Variables
  variables JSONB DEFAULT '[]',                -- [{name, type, required, default}]
  example_data JSONB DEFAULT '{}',             -- Example data for preview

  -- Versioning
  version INTEGER DEFAULT 1,
  is_active BOOLEAN DEFAULT TRUE,
  published_at TIMESTAMPTZ,

  -- Metrics
  usage_count INTEGER DEFAULT 0,
  last_used_at TIMESTAMPTZ,

  -- Metadata
  metadata JSONB DEFAULT '{}',
  tags TEXT[] DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  created_by TEXT
);

CREATE INDEX idx_templates_type ON cms.templates(template_type);
CREATE INDEX idx_templates_active ON cms.templates(is_active) WHERE is_active = TRUE;
CREATE INDEX idx_templates_channels ON cms.templates USING gin(channels);
CREATE INDEX idx_templates_tags ON cms.templates USING gin(tags);

-- ============================================================================
-- TABLE: cms.publications
-- ============================================================================
-- Purpose: Track content publication to different channels
-- Pattern: Item + Template + Channel → Publication → Track delivery
-- ============================================================================

CREATE TABLE cms.publications (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Links
  item_id UUID NOT NULL REFERENCES cms.items(id) ON DELETE CASCADE,
  template_id UUID REFERENCES cms.templates(id),

  -- Target
  channel cms.publication_channel NOT NULL,
  target_config JSONB DEFAULT '{}',            -- Channel-specific config

  -- Content
  rendered_content TEXT,                       -- Final rendered content
  rendered_at TIMESTAMPTZ,

  -- Scheduling and status
  scheduled_at TIMESTAMPTZ DEFAULT now(),
  status cms.publication_status DEFAULT 'pending',

  -- Execution
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  queue_id UUID REFERENCES ops.queue(id),      -- Link to processing job

  -- Results
  external_id TEXT,                            -- ID from target platform
  external_url TEXT,                           -- URL on target platform
  response_data JSONB DEFAULT '{}',            -- Full response from platform

  -- Errors
  error_message TEXT,
  retry_count INTEGER DEFAULT 0,
  max_retries INTEGER DEFAULT 3,

  -- Engagement (from platform)
  impressions INTEGER,
  clicks INTEGER,
  reactions INTEGER,
  comments INTEGER,
  shares INTEGER,
  engagement_updated_at TIMESTAMPTZ,

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_publications_item ON cms.publications(item_id);
CREATE INDEX idx_publications_channel ON cms.publications(channel);
CREATE INDEX idx_publications_status ON cms.publications(status);
CREATE INDEX idx_publications_scheduled ON cms.publications(scheduled_at)
  WHERE status = 'pending';
CREATE INDEX idx_publications_queue ON cms.publications(queue_id) WHERE queue_id IS NOT NULL;

-- ============================================================================
-- TABLE: cms.publication_runs
-- ============================================================================
-- Purpose: Track batch publication runs (e.g., daily digest)
-- ============================================================================

CREATE TABLE cms.publication_runs (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Run identity
  run_type TEXT NOT NULL,                      -- e.g., "daily_digest", "weekly_newsletter"
  run_date DATE NOT NULL,
  run_sequence INTEGER DEFAULT 1,              -- For multiple runs per day

  -- Status
  status ops.run_status DEFAULT 'pending',
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,

  -- Metrics
  items_included INTEGER DEFAULT 0,
  publications_created INTEGER DEFAULT 0,
  publications_sent INTEGER DEFAULT 0,
  publications_failed INTEGER DEFAULT 0,

  -- Configuration
  config JSONB DEFAULT '{}',

  -- Links
  ops_run_id UUID REFERENCES ops.runs(id),

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,

  -- Unique constraint
  UNIQUE (run_type, run_date, run_sequence)
);

CREATE INDEX idx_pub_runs_type ON cms.publication_runs(run_type, run_date DESC);
CREATE INDEX idx_pub_runs_status ON cms.publication_runs(status);

-- ============================================================================
-- FUNCTIONS
-- ============================================================================

-- Create item from source
CREATE OR REPLACE FUNCTION cms.create_item(
  p_title TEXT,
  p_content TEXT,
  p_source_id UUID DEFAULT NULL,
  p_source_url TEXT DEFAULT NULL,
  p_summary TEXT DEFAULT NULL,
  p_category TEXT DEFAULT NULL,
  p_tags TEXT[] DEFAULT '{}',
  p_auto_approve BOOLEAN DEFAULT FALSE,
  p_metadata JSONB DEFAULT '{}'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_item_id UUID;
  v_status cms.item_status;
  v_slug TEXT;
BEGIN
  -- Generate slug
  v_slug := lower(regexp_replace(p_title, '[^a-zA-Z0-9]+', '-', 'g'));
  v_slug := regexp_replace(v_slug, '-+', '-', 'g');
  v_slug := trim(both '-' from v_slug);

  -- Determine initial status
  IF p_auto_approve THEN
    v_status := 'approved';
  ELSE
    v_status := 'draft';
  END IF;

  INSERT INTO cms.items (
    title, slug, content, summary,
    source_id, source_url,
    status, category, tags, metadata
  ) VALUES (
    p_title, v_slug, p_content, p_summary,
    p_source_id, p_source_url,
    v_status, p_category, p_tags, p_metadata
  )
  RETURNING id INTO v_item_id;

  -- Update source metrics
  IF p_source_id IS NOT NULL THEN
    UPDATE cms.sources
    SET total_items = total_items + 1, updated_at = now()
    WHERE id = p_source_id;
  END IF;

  RETURN v_item_id;
END;
$$;

-- Schedule publication
CREATE OR REPLACE FUNCTION cms.schedule_publication(
  p_item_id UUID,
  p_channel cms.publication_channel,
  p_template_id UUID DEFAULT NULL,
  p_scheduled_at TIMESTAMPTZ DEFAULT NULL,
  p_target_config JSONB DEFAULT '{}'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_pub_id UUID;
  v_item_status cms.item_status;
BEGIN
  -- Verify item is approved
  SELECT status INTO v_item_status FROM cms.items WHERE id = p_item_id;

  IF v_item_status IS NULL THEN
    RAISE EXCEPTION 'Item not found: %', p_item_id;
  END IF;

  IF v_item_status NOT IN ('approved', 'published') THEN
    RAISE EXCEPTION 'Item must be approved before publishing. Current status: %', v_item_status;
  END IF;

  INSERT INTO cms.publications (
    item_id, template_id, channel,
    scheduled_at, target_config
  ) VALUES (
    p_item_id, p_template_id, p_channel,
    COALESCE(p_scheduled_at, now()), p_target_config
  )
  RETURNING id INTO v_pub_id;

  -- Enqueue for processing
  PERFORM ops.enqueue(
    'cms_publish',
    jsonb_build_object('publication_id', v_pub_id, 'channel', p_channel),
    'cms_pub_' || v_pub_id::TEXT,
    COALESCE(p_scheduled_at, now())
  );

  RETURN v_pub_id;
END;
$$;

-- Complete publication
CREATE OR REPLACE FUNCTION cms.complete_publication(
  p_publication_id UUID,
  p_external_id TEXT DEFAULT NULL,
  p_external_url TEXT DEFAULT NULL,
  p_response_data JSONB DEFAULT '{}'
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_item_id UUID;
BEGIN
  UPDATE cms.publications
  SET
    status = 'sent',
    completed_at = now(),
    external_id = p_external_id,
    external_url = p_external_url,
    response_data = p_response_data,
    updated_at = now()
  WHERE id = p_publication_id
  RETURNING item_id INTO v_item_id;

  -- Update item status
  UPDATE cms.items
  SET
    status = 'published',
    updated_at = now()
  WHERE id = v_item_id;

  -- Update template usage
  UPDATE cms.templates
  SET
    usage_count = usage_count + 1,
    last_used_at = now(),
    updated_at = now()
  WHERE id = (SELECT template_id FROM cms.publications WHERE id = p_publication_id);
END;
$$;

-- Fail publication
CREATE OR REPLACE FUNCTION cms.fail_publication(
  p_publication_id UUID,
  p_error_message TEXT,
  p_should_retry BOOLEAN DEFAULT TRUE
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_retry_count INTEGER;
  v_max_retries INTEGER;
BEGIN
  SELECT retry_count, max_retries INTO v_retry_count, v_max_retries
  FROM cms.publications WHERE id = p_publication_id;

  IF p_should_retry AND v_retry_count < v_max_retries THEN
    UPDATE cms.publications
    SET
      status = 'pending',
      retry_count = retry_count + 1,
      error_message = p_error_message,
      scheduled_at = now() + (interval '1 minute' * power(2, v_retry_count)),
      updated_at = now()
    WHERE id = p_publication_id;
  ELSE
    UPDATE cms.publications
    SET
      status = 'failed',
      completed_at = now(),
      error_message = p_error_message,
      updated_at = now()
    WHERE id = p_publication_id;
  END IF;
END;
$$;

-- Render template with data
CREATE OR REPLACE FUNCTION cms.render_template(
  p_template_id UUID,
  p_data JSONB
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_content TEXT;
  v_key TEXT;
  v_value TEXT;
BEGIN
  SELECT content INTO v_content FROM cms.templates WHERE id = p_template_id;

  IF v_content IS NULL THEN
    RAISE EXCEPTION 'Template not found: %', p_template_id;
  END IF;

  -- Simple placeholder replacement
  FOR v_key, v_value IN SELECT * FROM jsonb_each_text(p_data)
  LOOP
    v_content := replace(v_content, '{{' || v_key || '}}', COALESCE(v_value, ''));
  END LOOP;

  RETURN v_content;
END;
$$;

-- ============================================================================
-- VIEWS
-- ============================================================================

-- Items ready for review
CREATE OR REPLACE VIEW cms.v_review_queue AS
SELECT
  i.id,
  i.title,
  i.summary,
  i.content_type,
  i.category,
  s.name as source_name,
  i.created_at,
  i.tags
FROM cms.items i
LEFT JOIN cms.sources s ON i.source_id = s.id
WHERE i.status = 'draft'
ORDER BY i.created_at DESC;

-- Items ready to publish
CREATE OR REPLACE VIEW cms.v_publish_queue AS
SELECT
  i.id,
  i.title,
  i.publish_at,
  i.category,
  ARRAY_AGG(DISTINCT p.channel) FILTER (WHERE p.channel IS NOT NULL) as scheduled_channels
FROM cms.items i
LEFT JOIN cms.publications p ON i.id = p.item_id AND p.status = 'pending'
WHERE i.status = 'approved'
GROUP BY i.id
ORDER BY COALESCE(i.publish_at, i.created_at);

-- Publication status summary
CREATE OR REPLACE VIEW cms.v_publication_summary AS
SELECT
  channel,
  status,
  COUNT(*) as count,
  MIN(scheduled_at) as earliest,
  MAX(scheduled_at) as latest
FROM cms.publications
WHERE scheduled_at > now() - interval '7 days'
GROUP BY channel, status
ORDER BY channel, status;

-- Recent publications with engagement
CREATE OR REPLACE VIEW cms.v_recent_publications AS
SELECT
  p.id,
  i.title,
  p.channel,
  p.status,
  p.completed_at,
  p.external_url,
  p.impressions,
  p.clicks,
  p.reactions,
  p.comments,
  p.shares
FROM cms.publications p
JOIN cms.items i ON p.item_id = i.id
WHERE p.status = 'sent'
ORDER BY p.completed_at DESC
LIMIT 100;

-- Source health
CREATE OR REPLACE VIEW cms.v_source_health AS
SELECT
  s.id,
  s.name,
  s.source_type,
  s.is_active,
  s.last_fetched_at,
  s.next_fetch_at,
  s.total_items,
  s.successful_fetches,
  s.failed_fetches,
  CASE
    WHEN s.successful_fetches + s.failed_fetches = 0 THEN NULL
    ELSE ROUND(100.0 * s.successful_fetches / (s.successful_fetches + s.failed_fetches), 2)
  END as success_rate
FROM cms.sources s
ORDER BY s.name;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

CREATE TRIGGER tr_sources_updated_at
  BEFORE UPDATE ON cms.sources
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_items_updated_at
  BEFORE UPDATE ON cms.items
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_templates_updated_at
  BEFORE UPDATE ON cms.templates
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_publications_updated_at
  BEFORE UPDATE ON cms.publications
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_publication_runs_updated_at
  BEFORE UPDATE ON cms.publication_runs
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON SCHEMA cms IS 'Content management and multi-channel publishing pipeline';

COMMENT ON TABLE cms.sources IS 'Content sources (feeds, scrapers, APIs) that produce items';
COMMENT ON TABLE cms.items IS 'Content items with workflow status (draft → review → published)';
COMMENT ON TABLE cms.templates IS 'Templates for rendering content to different formats/channels';
COMMENT ON TABLE cms.publications IS 'Track individual publications to channels with engagement data';
COMMENT ON TABLE cms.publication_runs IS 'Batch publication runs (daily digests, newsletters)';
