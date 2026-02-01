-- ============================================================================
-- DEEP_RESEARCH SCHEMA: Feature Extraction & Web Intelligence
-- ============================================================================
-- Purpose: Web scraping → parsing → feature extraction → entity resolution
-- Pattern: raw_fetches → parsed_docs → features → entities
-- ============================================================================

-- Create deep_research schema
CREATE SCHEMA IF NOT EXISTS deep_research;

-- Grant access
GRANT USAGE ON SCHEMA deep_research TO authenticated;
GRANT USAGE ON SCHEMA deep_research TO service_role;

-- ============================================================================
-- ENUMS
-- ============================================================================

CREATE TYPE deep_research.fetch_status AS ENUM (
  'pending',      -- Queued for fetching
  'fetching',     -- Currently being fetched
  'success',      -- Successfully fetched
  'failed',       -- Fetch failed
  'skipped'       -- Skipped (e.g., already cached)
);

CREATE TYPE deep_research.parse_status AS ENUM (
  'pending',      -- Awaiting parsing
  'parsing',      -- Currently being parsed
  'success',      -- Successfully parsed
  'failed',       -- Parse failed
  'partial'       -- Partially parsed (some content extracted)
);

CREATE TYPE deep_research.entity_type AS ENUM (
  'company',      -- Business entity
  'product',      -- Product or service
  'person',       -- Individual
  'technology',   -- Technology/framework
  'category',     -- Classification
  'location',     -- Geographic location
  'event',        -- Time-bounded event
  'custom'        -- Custom entity type
);

-- ============================================================================
-- TABLE: deep_research.raw_fetches
-- ============================================================================
-- Purpose: Store raw HTTP fetch results
-- Pattern: URL → fetch → store response + headers
-- ============================================================================

CREATE TABLE deep_research.raw_fetches (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Target URL
  url TEXT NOT NULL,
  url_hash TEXT GENERATED ALWAYS AS (encode(sha256(url::bytea), 'hex')) STORED,
  domain TEXT,                                 -- Extracted domain for grouping

  -- Request details
  method TEXT DEFAULT 'GET',
  request_headers JSONB DEFAULT '{}',

  -- Response details
  status_code INTEGER,
  response_headers JSONB DEFAULT '{}',
  content_type TEXT,
  content_length INTEGER,

  -- Content storage
  body_ref TEXT,                               -- Storage path for body (if large)
  body_text TEXT,                              -- Inline body (if small)
  body_hash TEXT,                              -- Content hash for deduplication

  -- Fetch metadata
  fetch_status deep_research.fetch_status DEFAULT 'pending',
  fetch_started_at TIMESTAMPTZ,
  fetch_completed_at TIMESTAMPTZ,
  fetch_duration_ms INTEGER,
  error_message TEXT,

  -- Request context
  queue_id UUID REFERENCES ops.queue(id),      -- Link to job that triggered fetch
  user_agent TEXT,
  proxy_used TEXT,

  -- Caching
  etag TEXT,
  last_modified TEXT,
  cache_control TEXT,
  expires_at TIMESTAMPTZ,

  -- Metadata
  metadata JSONB DEFAULT '{}',
  tags TEXT[] DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_fetches_url_hash ON deep_research.raw_fetches(url_hash);
CREATE INDEX idx_fetches_domain ON deep_research.raw_fetches(domain);
CREATE INDEX idx_fetches_status ON deep_research.raw_fetches(fetch_status);
CREATE INDEX idx_fetches_created ON deep_research.raw_fetches(created_at DESC);
CREATE INDEX idx_fetches_queue ON deep_research.raw_fetches(queue_id) WHERE queue_id IS NOT NULL;
CREATE INDEX idx_fetches_body_hash ON deep_research.raw_fetches(body_hash) WHERE body_hash IS NOT NULL;
CREATE INDEX idx_fetches_tags ON deep_research.raw_fetches USING gin(tags);

-- ============================================================================
-- TABLE: deep_research.parsed_docs
-- ============================================================================
-- Purpose: Cleaned, structured content extracted from raw fetches
-- Pattern: HTML/JSON → clean text + metadata + structure
-- ============================================================================

CREATE TABLE deep_research.parsed_docs (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Link to source
  fetch_id UUID REFERENCES deep_research.raw_fetches(id) ON DELETE CASCADE,

  -- Source URL (denormalized for convenience)
  url TEXT NOT NULL,
  domain TEXT,

  -- Content
  title TEXT,
  description TEXT,
  clean_text TEXT,                             -- Main content as clean text
  text_length INTEGER,                         -- Character count

  -- Structure
  headings TEXT[],                             -- h1, h2, h3 headings
  links JSONB DEFAULT '[]',                    -- Extracted links [{url, text, rel}]
  images JSONB DEFAULT '[]',                   -- Extracted images [{src, alt}]
  tables JSONB DEFAULT '[]',                   -- Extracted tables

  -- Metadata from page
  author TEXT,
  published_at TIMESTAMPTZ,
  modified_at TIMESTAMPTZ,
  language TEXT,
  og_metadata JSONB DEFAULT '{}',              -- Open Graph metadata
  schema_org JSONB DEFAULT '{}',               -- Schema.org data

  -- Parse status
  parse_status deep_research.parse_status DEFAULT 'pending',
  parsed_at TIMESTAMPTZ,
  parser_version TEXT,
  parse_errors TEXT[],

  -- Classification
  content_type TEXT,                           -- e.g., "article", "product_page", "landing"
  quality_score REAL,                          -- 0-1 content quality score

  -- Metadata
  metadata JSONB DEFAULT '{}',
  tags TEXT[] DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_parsed_fetch ON deep_research.parsed_docs(fetch_id);
CREATE INDEX idx_parsed_domain ON deep_research.parsed_docs(domain);
CREATE INDEX idx_parsed_status ON deep_research.parsed_docs(parse_status);
CREATE INDEX idx_parsed_type ON deep_research.parsed_docs(content_type) WHERE content_type IS NOT NULL;
CREATE INDEX idx_parsed_quality ON deep_research.parsed_docs(quality_score DESC) WHERE quality_score IS NOT NULL;
CREATE INDEX idx_parsed_tags ON deep_research.parsed_docs USING gin(tags);
CREATE INDEX idx_parsed_text_search ON deep_research.parsed_docs USING gin(to_tsvector('english', COALESCE(title, '') || ' ' || COALESCE(description, '') || ' ' || COALESCE(clean_text, '')));

-- ============================================================================
-- TABLE: deep_research.features
-- ============================================================================
-- Purpose: Normalized features extracted from parsed documents
-- Pattern: parsed_doc → feature extraction → structured features
-- ============================================================================

CREATE TABLE deep_research.features (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Link to source
  doc_id UUID REFERENCES deep_research.parsed_docs(id) ON DELETE CASCADE,
  entity_id UUID,                              -- Link to entity if resolved

  -- Feature identity
  feature_type TEXT NOT NULL,                  -- e.g., "pricing", "company_info", "product_spec"
  feature_name TEXT NOT NULL,                  -- e.g., "monthly_price", "headquarters"

  -- Feature value
  value_text TEXT,                             -- Text representation
  value_number DOUBLE PRECISION,               -- Numeric representation
  value_json JSONB,                            -- Structured representation
  value_array TEXT[],                          -- Array representation

  -- Confidence and provenance
  confidence REAL DEFAULT 1.0,                 -- 0-1 confidence score
  extraction_method TEXT,                      -- e.g., "regex", "llm", "xpath"
  source_snippet TEXT,                         -- Original text this was extracted from

  -- Normalization
  is_normalized BOOLEAN DEFAULT FALSE,
  normalized_value TEXT,                       -- Standardized value
  unit TEXT,                                   -- Unit of measurement if applicable

  -- Versioning
  version INTEGER DEFAULT 1,
  supersedes UUID REFERENCES deep_research.features(id),

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_features_doc ON deep_research.features(doc_id);
CREATE INDEX idx_features_entity ON deep_research.features(entity_id) WHERE entity_id IS NOT NULL;
CREATE INDEX idx_features_type ON deep_research.features(feature_type);
CREATE INDEX idx_features_name ON deep_research.features(feature_type, feature_name);
CREATE INDEX idx_features_confidence ON deep_research.features(feature_type, confidence DESC);
CREATE INDEX idx_features_value_json ON deep_research.features USING gin(value_json);

-- ============================================================================
-- TABLE: deep_research.entities
-- ============================================================================
-- Purpose: Resolved entities (companies, products, people, etc.)
-- Pattern: Features → entity resolution → canonical entities
-- ============================================================================

CREATE TABLE deep_research.entities (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Entity identity
  entity_type deep_research.entity_type NOT NULL,
  name TEXT NOT NULL,
  canonical_name TEXT,                         -- Standardized name
  slug TEXT,                                   -- URL-safe identifier

  -- Description
  description TEXT,
  summary TEXT,

  -- Identifiers
  external_ids JSONB DEFAULT '{}',             -- e.g., {"crunchbase": "...", "linkedin": "..."}
  website TEXT,
  domain TEXT,

  -- Classification
  category TEXT,                               -- Primary category
  subcategory TEXT,
  industry TEXT,
  tags TEXT[] DEFAULT '{}',

  -- Location (if applicable)
  country TEXT,
  region TEXT,
  city TEXT,

  -- Status
  is_verified BOOLEAN DEFAULT FALSE,
  is_active BOOLEAN DEFAULT TRUE,
  merged_into UUID REFERENCES deep_research.entities(id),

  -- Aggregated data
  feature_count INTEGER DEFAULT 0,
  source_count INTEGER DEFAULT 0,
  last_updated TIMESTAMPTZ DEFAULT now(),

  -- Embeddings (for similarity search)
  embedding vector(1536),                      -- OpenAI ada-002 embedding

  -- Metadata
  metadata JSONB DEFAULT '{}',

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_entities_type ON deep_research.entities(entity_type);
CREATE INDEX idx_entities_name ON deep_research.entities(name);
CREATE INDEX idx_entities_canonical ON deep_research.entities(canonical_name) WHERE canonical_name IS NOT NULL;
CREATE INDEX idx_entities_slug ON deep_research.entities(slug) WHERE slug IS NOT NULL;
CREATE INDEX idx_entities_domain ON deep_research.entities(domain) WHERE domain IS NOT NULL;
CREATE INDEX idx_entities_category ON deep_research.entities(entity_type, category);
CREATE INDEX idx_entities_tags ON deep_research.entities USING gin(tags);
CREATE INDEX idx_entities_external ON deep_research.entities USING gin(external_ids);
CREATE INDEX idx_entities_active ON deep_research.entities(entity_type, is_active) WHERE is_active = TRUE;

-- Vector similarity index (if pgvector is enabled)
-- CREATE INDEX idx_entities_embedding ON deep_research.entities USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- ============================================================================
-- TABLE: deep_research.entity_sources
-- ============================================================================
-- Purpose: Link entities to their source documents
-- Pattern: Track provenance of entity data
-- ============================================================================

CREATE TABLE deep_research.entity_sources (
  -- Composite primary key
  entity_id UUID NOT NULL REFERENCES deep_research.entities(id) ON DELETE CASCADE,
  doc_id UUID NOT NULL REFERENCES deep_research.parsed_docs(id) ON DELETE CASCADE,

  -- Relationship
  relationship TEXT DEFAULT 'mentioned',       -- e.g., "primary", "mentioned", "compared"
  confidence REAL DEFAULT 1.0,

  -- Provenance
  first_seen_at TIMESTAMPTZ DEFAULT now(),
  last_seen_at TIMESTAMPTZ DEFAULT now(),
  mention_count INTEGER DEFAULT 1,

  -- Metadata
  metadata JSONB DEFAULT '{}',

  PRIMARY KEY (entity_id, doc_id)
);

CREATE INDEX idx_entity_sources_doc ON deep_research.entity_sources(doc_id);

-- ============================================================================
-- FUNCTIONS
-- ============================================================================

-- Upsert features for an entity (batch operation)
CREATE OR REPLACE FUNCTION deep_research.upsert_features(
  p_entity_id UUID,
  p_features JSONB  -- Array of {feature_type, feature_name, value_text, value_number, value_json, confidence}
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_feature JSONB;
  v_count INTEGER := 0;
BEGIN
  FOR v_feature IN SELECT * FROM jsonb_array_elements(p_features)
  LOOP
    INSERT INTO deep_research.features (
      entity_id,
      feature_type,
      feature_name,
      value_text,
      value_number,
      value_json,
      confidence,
      extraction_method
    ) VALUES (
      p_entity_id,
      v_feature->>'feature_type',
      v_feature->>'feature_name',
      v_feature->>'value_text',
      (v_feature->>'value_number')::DOUBLE PRECISION,
      v_feature->'value_json',
      COALESCE((v_feature->>'confidence')::REAL, 1.0),
      v_feature->>'extraction_method'
    )
    ON CONFLICT (id) DO UPDATE SET
      value_text = EXCLUDED.value_text,
      value_number = EXCLUDED.value_number,
      value_json = EXCLUDED.value_json,
      confidence = EXCLUDED.confidence,
      version = deep_research.features.version + 1,
      updated_at = now();

    v_count := v_count + 1;
  END LOOP;

  -- Update entity feature count
  UPDATE deep_research.entities
  SET
    feature_count = (SELECT COUNT(*) FROM deep_research.features WHERE entity_id = p_entity_id),
    last_updated = now(),
    updated_at = now()
  WHERE id = p_entity_id;

  RETURN v_count;
END;
$$;

-- Record a fetch result
CREATE OR REPLACE FUNCTION deep_research.record_fetch(
  p_url TEXT,
  p_status_code INTEGER,
  p_response_headers JSONB DEFAULT '{}',
  p_body_text TEXT DEFAULT NULL,
  p_body_ref TEXT DEFAULT NULL,
  p_fetch_duration_ms INTEGER DEFAULT NULL,
  p_error_message TEXT DEFAULT NULL,
  p_queue_id UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_fetch_id UUID;
  v_domain TEXT;
  v_status deep_research.fetch_status;
BEGIN
  -- Extract domain
  v_domain := (regexp_match(p_url, '://([^/]+)'))[1];

  -- Determine status
  IF p_status_code IS NOT NULL AND p_status_code >= 200 AND p_status_code < 400 THEN
    v_status := 'success';
  ELSIF p_error_message IS NOT NULL THEN
    v_status := 'failed';
  ELSE
    v_status := 'success';
  END IF;

  INSERT INTO deep_research.raw_fetches (
    url, domain, status_code, response_headers,
    body_text, body_ref, content_type,
    fetch_status, fetch_completed_at, fetch_duration_ms,
    error_message, queue_id
  ) VALUES (
    p_url, v_domain, p_status_code, p_response_headers,
    p_body_text, p_body_ref, p_response_headers->>'content-type',
    v_status, now(), p_fetch_duration_ms,
    p_error_message, p_queue_id
  )
  RETURNING id INTO v_fetch_id;

  RETURN v_fetch_id;
END;
$$;

-- Create or update entity
CREATE OR REPLACE FUNCTION deep_research.upsert_entity(
  p_entity_type deep_research.entity_type,
  p_name TEXT,
  p_description TEXT DEFAULT NULL,
  p_website TEXT DEFAULT NULL,
  p_external_ids JSONB DEFAULT '{}',
  p_category TEXT DEFAULT NULL,
  p_tags TEXT[] DEFAULT '{}',
  p_metadata JSONB DEFAULT '{}'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_entity_id UUID;
  v_domain TEXT;
  v_slug TEXT;
BEGIN
  -- Extract domain from website
  IF p_website IS NOT NULL THEN
    v_domain := (regexp_match(p_website, '://([^/]+)'))[1];
  END IF;

  -- Generate slug
  v_slug := lower(regexp_replace(p_name, '[^a-zA-Z0-9]+', '-', 'g'));

  -- Try to find existing entity
  SELECT id INTO v_entity_id
  FROM deep_research.entities
  WHERE entity_type = p_entity_type
    AND (name = p_name OR canonical_name = p_name OR domain = v_domain)
  LIMIT 1;

  IF v_entity_id IS NOT NULL THEN
    -- Update existing
    UPDATE deep_research.entities
    SET
      description = COALESCE(p_description, description),
      website = COALESCE(p_website, website),
      domain = COALESCE(v_domain, domain),
      external_ids = external_ids || p_external_ids,
      category = COALESCE(p_category, category),
      tags = ARRAY(SELECT DISTINCT unnest(tags || p_tags)),
      metadata = metadata || p_metadata,
      last_updated = now(),
      updated_at = now()
    WHERE id = v_entity_id;
  ELSE
    -- Create new
    INSERT INTO deep_research.entities (
      entity_type, name, slug, description,
      website, domain, external_ids,
      category, tags, metadata
    ) VALUES (
      p_entity_type, p_name, v_slug, p_description,
      p_website, v_domain, p_external_ids,
      p_category, p_tags, p_metadata
    )
    RETURNING id INTO v_entity_id;
  END IF;

  RETURN v_entity_id;
END;
$$;

-- ============================================================================
-- VIEWS
-- ============================================================================

-- Recent fetches with status
CREATE OR REPLACE VIEW deep_research.v_recent_fetches AS
SELECT
  id,
  url,
  domain,
  fetch_status,
  status_code,
  content_type,
  fetch_duration_ms,
  error_message,
  created_at
FROM deep_research.raw_fetches
ORDER BY created_at DESC
LIMIT 1000;

-- Entity summary with feature counts
CREATE OR REPLACE VIEW deep_research.v_entity_summary AS
SELECT
  e.id,
  e.entity_type,
  e.name,
  e.canonical_name,
  e.category,
  e.website,
  e.feature_count,
  e.source_count,
  e.is_verified,
  e.last_updated,
  ARRAY_AGG(DISTINCT f.feature_type) FILTER (WHERE f.feature_type IS NOT NULL) as feature_types
FROM deep_research.entities e
LEFT JOIN deep_research.features f ON f.entity_id = e.id
WHERE e.is_active = TRUE
GROUP BY e.id
ORDER BY e.last_updated DESC;

-- Feature extraction pipeline status
CREATE OR REPLACE VIEW deep_research.v_pipeline_status AS
SELECT
  'fetches_pending' as stage,
  COUNT(*) as count
FROM deep_research.raw_fetches
WHERE fetch_status = 'pending'
UNION ALL
SELECT
  'parsing_pending',
  COUNT(*)
FROM deep_research.parsed_docs
WHERE parse_status = 'pending'
UNION ALL
SELECT
  'entities_unverified',
  COUNT(*)
FROM deep_research.entities
WHERE is_verified = FALSE;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

CREATE TRIGGER tr_raw_fetches_updated_at
  BEFORE UPDATE ON deep_research.raw_fetches
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_parsed_docs_updated_at
  BEFORE UPDATE ON deep_research.parsed_docs
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_features_updated_at
  BEFORE UPDATE ON deep_research.features
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_entities_updated_at
  BEFORE UPDATE ON deep_research.entities
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON SCHEMA deep_research IS 'Web intelligence pipeline: fetch → parse → extract features → resolve entities';

COMMENT ON TABLE deep_research.raw_fetches IS 'Raw HTTP fetch results. Body stored inline or in Storage.';
COMMENT ON TABLE deep_research.parsed_docs IS 'Cleaned, structured content from raw fetches.';
COMMENT ON TABLE deep_research.features IS 'Normalized features extracted from documents.';
COMMENT ON TABLE deep_research.entities IS 'Resolved entities (companies, products, etc.) with aggregated data.';
