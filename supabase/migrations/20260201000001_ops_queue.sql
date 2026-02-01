-- ============================================================================
-- OPS QUEUE EXTENSION: Job Queuing for Platform Kit Executor
-- ============================================================================
-- Purpose: Adds queue/claim/execute pattern for deterministic job execution
-- Pattern: Enqueue intents → claim_next → execute → complete
-- ============================================================================

-- ============================================================================
-- ENUMS: Queue-specific status
-- ============================================================================

CREATE TYPE ops.queue_status AS ENUM (
  'pending',      -- Waiting in queue
  'claimed',      -- Worker has claimed it
  'running',      -- Actively executing
  'completed',    -- Successfully finished
  'failed',       -- Failed after all retries
  'cancelled',    -- Manually cancelled
  'dead_letter'   -- Moved to dead letter queue
);

-- ============================================================================
-- TABLE: ops.queue
-- ============================================================================
-- Purpose: Work items waiting to be processed by ops-executor
-- Pattern: Insert → claim → execute → complete/fail
-- ============================================================================

CREATE TABLE ops.queue (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Job identity
  job_type TEXT NOT NULL,                      -- e.g., "scrape", "etl", "eval", "cms_publish"
  job_name TEXT,                               -- Human-readable name
  dedupe_key TEXT,                             -- For idempotency (unique constraint)

  -- Payload
  payload JSONB NOT NULL DEFAULT '{}',         -- Job-specific data

  -- Scheduling
  scheduled_at TIMESTAMPTZ DEFAULT now(),      -- When to run (for delayed jobs)
  priority INTEGER DEFAULT 0,                  -- Higher = more urgent

  -- Queue status
  status ops.queue_status NOT NULL DEFAULT 'pending',

  -- Execution tracking
  claimed_at TIMESTAMPTZ,                      -- When a worker claimed it
  claimed_by TEXT,                             -- Worker ID that claimed it
  claim_expires_at TIMESTAMPTZ,                -- Claim lease expiration
  started_at TIMESTAMPTZ,                      -- When execution started
  completed_at TIMESTAMPTZ,                    -- When execution completed

  -- Retry configuration
  attempt INTEGER DEFAULT 0,                   -- Current attempt number
  max_attempts INTEGER DEFAULT 3,              -- Maximum retries
  retry_backoff_seconds INTEGER DEFAULT 60,    -- Base backoff for retries
  next_retry_at TIMESTAMPTZ,                   -- When to retry next

  -- Results
  result JSONB,                                -- Success result data
  error_message TEXT,                          -- Last error message
  error_stack TEXT,                            -- Last error stack trace

  -- Linking
  run_id UUID REFERENCES ops.runs(id),         -- Link to ops.runs for telemetry
  artifact_refs TEXT[] DEFAULT '{}',           -- Storage paths for artifacts

  -- Metadata
  tags TEXT[] DEFAULT '{}',                    -- Searchable tags
  metadata JSONB DEFAULT '{}',                 -- Additional context

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,

  -- Constraints
  CONSTRAINT valid_schedule CHECK (scheduled_at IS NOT NULL),
  CONSTRAINT valid_priority CHECK (priority >= -1000 AND priority <= 1000)
);

-- Unique constraint for deduplication
CREATE UNIQUE INDEX idx_queue_dedupe ON ops.queue(dedupe_key)
  WHERE dedupe_key IS NOT NULL AND status IN ('pending', 'claimed', 'running');

-- Indexes for claim_next query
CREATE INDEX idx_queue_claimable ON ops.queue(priority DESC, scheduled_at ASC)
  WHERE status = 'pending' AND scheduled_at <= now();

CREATE INDEX idx_queue_by_type ON ops.queue(job_type, status);
CREATE INDEX idx_queue_by_status ON ops.queue(status);
CREATE INDEX idx_queue_retry ON ops.queue(next_retry_at)
  WHERE status = 'failed' AND next_retry_at IS NOT NULL;
CREATE INDEX idx_queue_claimed ON ops.queue(claimed_by, claimed_at)
  WHERE status = 'claimed';
CREATE INDEX idx_queue_expired_claims ON ops.queue(claim_expires_at)
  WHERE status = 'claimed' AND claim_expires_at IS NOT NULL;
CREATE INDEX idx_queue_tags ON ops.queue USING gin(tags);
CREATE INDEX idx_queue_metadata ON ops.queue USING gin(metadata);

-- ============================================================================
-- TABLE: ops.artifacts
-- ============================================================================
-- Purpose: Metadata for artifacts stored in Supabase Storage
-- Pattern: Execution produces artifacts → store in Storage → record here
-- ============================================================================

CREATE TABLE ops.artifacts (
  -- Primary key
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Linking
  run_id UUID REFERENCES ops.runs(id) ON DELETE CASCADE,
  queue_id UUID REFERENCES ops.queue(id) ON DELETE SET NULL,

  -- Storage reference
  bucket TEXT NOT NULL DEFAULT 'artifacts',    -- Storage bucket name
  path TEXT NOT NULL,                          -- Path within bucket

  -- Content metadata
  content_type TEXT,                           -- MIME type
  size_bytes BIGINT,                           -- File size
  checksum TEXT,                               -- SHA-256 or content hash

  -- Classification
  artifact_type TEXT NOT NULL,                 -- e.g., "log", "html", "json", "screenshot"
  artifact_name TEXT,                          -- Human-readable name

  -- Metadata
  metadata JSONB DEFAULT '{}',                 -- Additional context

  -- Lifecycle
  expires_at TIMESTAMPTZ,                      -- When to auto-delete

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_artifacts_run ON ops.artifacts(run_id);
CREATE INDEX idx_artifacts_queue ON ops.artifacts(queue_id) WHERE queue_id IS NOT NULL;
CREATE INDEX idx_artifacts_type ON ops.artifacts(artifact_type);
CREATE INDEX idx_artifacts_expires ON ops.artifacts(expires_at) WHERE expires_at IS NOT NULL;
CREATE INDEX idx_artifacts_path ON ops.artifacts(bucket, path);

-- ============================================================================
-- FUNCTIONS: Queue Operations
-- ============================================================================

-- Enqueue a new job
CREATE OR REPLACE FUNCTION ops.enqueue(
  p_job_type TEXT,
  p_payload JSONB DEFAULT '{}',
  p_dedupe_key TEXT DEFAULT NULL,
  p_schedule_at TIMESTAMPTZ DEFAULT NULL,
  p_priority INTEGER DEFAULT 0,
  p_max_attempts INTEGER DEFAULT 3,
  p_job_name TEXT DEFAULT NULL,
  p_tags TEXT[] DEFAULT '{}',
  p_metadata JSONB DEFAULT '{}'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_queue_id UUID;
  v_existing_id UUID;
BEGIN
  -- Check for existing job with same dedupe_key
  IF p_dedupe_key IS NOT NULL THEN
    SELECT id INTO v_existing_id
    FROM ops.queue
    WHERE dedupe_key = p_dedupe_key
      AND status IN ('pending', 'claimed', 'running');

    IF v_existing_id IS NOT NULL THEN
      -- Return existing job ID (idempotent)
      RETURN v_existing_id;
    END IF;
  END IF;

  -- Insert new job
  INSERT INTO ops.queue (
    job_type, job_name, payload, dedupe_key,
    scheduled_at, priority, max_attempts,
    tags, metadata
  ) VALUES (
    p_job_type, p_job_name, p_payload, p_dedupe_key,
    COALESCE(p_schedule_at, now()), p_priority, p_max_attempts,
    p_tags, p_metadata
  )
  RETURNING id INTO v_queue_id;

  -- Log enqueue event
  INSERT INTO ops.events (level, message, system, category, metadata)
  VALUES ('info', format('Enqueued job %s: %s', p_job_type, COALESCE(p_job_name, 'unnamed')),
    'supabase', 'queue', jsonb_build_object(
      'queue_id', v_queue_id,
      'job_type', p_job_type,
      'dedupe_key', p_dedupe_key
    ));

  RETURN v_queue_id;
END;
$$;

-- Claim next available job (with visibility timeout)
CREATE OR REPLACE FUNCTION ops.claim_next(
  p_worker_id TEXT,
  p_job_types TEXT[] DEFAULT NULL,
  p_claim_duration_seconds INTEGER DEFAULT 300
) RETURNS TABLE(
  id UUID,
  job_type TEXT,
  job_name TEXT,
  payload JSONB,
  attempt INTEGER,
  max_attempts INTEGER,
  metadata JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_queue_id UUID;
  v_claim_expires TIMESTAMPTZ;
BEGIN
  v_claim_expires := now() + (p_claim_duration_seconds || ' seconds')::INTERVAL;

  -- Atomically claim the next job using FOR UPDATE SKIP LOCKED
  UPDATE ops.queue q
  SET
    status = 'claimed',
    claimed_at = now(),
    claimed_by = p_worker_id,
    claim_expires_at = v_claim_expires,
    attempt = q.attempt + 1,
    updated_at = now()
  WHERE q.id = (
    SELECT qq.id
    FROM ops.queue qq
    WHERE qq.status = 'pending'
      AND qq.scheduled_at <= now()
      AND (p_job_types IS NULL OR qq.job_type = ANY(p_job_types))
    ORDER BY qq.priority DESC, qq.scheduled_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED
  )
  RETURNING q.id INTO v_queue_id;

  IF v_queue_id IS NULL THEN
    -- No jobs available
    RETURN;
  END IF;

  -- Return the claimed job
  RETURN QUERY
  SELECT
    q.id,
    q.job_type,
    q.job_name,
    q.payload,
    q.attempt,
    q.max_attempts,
    q.metadata
  FROM ops.queue q
  WHERE q.id = v_queue_id;
END;
$$;

-- Mark job as started (creates ops.run)
CREATE OR REPLACE FUNCTION ops.start_queued_job(
  p_queue_id UUID
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_run_id UUID;
  v_job_type TEXT;
  v_job_name TEXT;
BEGIN
  -- Get job details
  SELECT job_type, job_name INTO v_job_type, v_job_name
  FROM ops.queue WHERE id = p_queue_id;

  -- Update queue status
  UPDATE ops.queue
  SET status = 'running', started_at = now(), updated_at = now()
  WHERE id = p_queue_id;

  -- Create ops.run
  v_run_id := ops.start_run(
    'supabase',
    COALESCE(v_job_name, v_job_type),
    v_job_type,
    'queue',
    'ops-executor',
    NULL,
    NULL,
    jsonb_build_object('queue_id', p_queue_id)
  );

  -- Link run to queue
  UPDATE ops.queue SET run_id = v_run_id, updated_at = now()
  WHERE id = p_queue_id;

  RETURN v_run_id;
END;
$$;

-- Append event to run (convenience wrapper)
CREATE OR REPLACE FUNCTION ops.append_event(
  p_run_id UUID,
  p_level ops.event_level,
  p_message TEXT,
  p_data JSONB DEFAULT '{}'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN ops.log_event(p_level, p_message, p_run_id, NULL, NULL, NULL, NULL, NULL, p_data);
END;
$$;

-- Complete queued job successfully
CREATE OR REPLACE FUNCTION ops.complete_queued_job(
  p_queue_id UUID,
  p_result JSONB DEFAULT '{}',
  p_metrics JSONB DEFAULT '{}'
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_run_id UUID;
BEGIN
  -- Get linked run
  SELECT run_id INTO v_run_id FROM ops.queue WHERE id = p_queue_id;

  -- Update queue
  UPDATE ops.queue
  SET
    status = 'completed',
    completed_at = now(),
    result = p_result,
    updated_at = now()
  WHERE id = p_queue_id;

  -- Complete the run
  IF v_run_id IS NOT NULL THEN
    PERFORM ops.complete_run(
      v_run_id,
      (p_metrics->>'records_processed')::BIGINT,
      (p_metrics->>'records_failed')::BIGINT,
      p_result
    );
  END IF;
END;
$$;

-- Fail queued job (with retry logic)
CREATE OR REPLACE FUNCTION ops.fail_queued_job(
  p_queue_id UUID,
  p_error_message TEXT,
  p_error_stack TEXT DEFAULT NULL,
  p_should_retry BOOLEAN DEFAULT TRUE
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_run_id UUID;
  v_attempt INTEGER;
  v_max_attempts INTEGER;
  v_backoff INTEGER;
BEGIN
  -- Get job details
  SELECT run_id, attempt, max_attempts, retry_backoff_seconds
  INTO v_run_id, v_attempt, v_max_attempts, v_backoff
  FROM ops.queue WHERE id = p_queue_id;

  IF p_should_retry AND v_attempt < v_max_attempts THEN
    -- Schedule retry with exponential backoff
    UPDATE ops.queue
    SET
      status = 'pending',
      error_message = p_error_message,
      error_stack = p_error_stack,
      claimed_at = NULL,
      claimed_by = NULL,
      claim_expires_at = NULL,
      next_retry_at = now() + (v_backoff * power(2, v_attempt - 1) || ' seconds')::INTERVAL,
      scheduled_at = now() + (v_backoff * power(2, v_attempt - 1) || ' seconds')::INTERVAL,
      updated_at = now()
    WHERE id = p_queue_id;

    -- Log retry
    PERFORM ops.append_event(v_run_id, 'warn',
      format('Job failed, scheduling retry %s/%s in %s seconds',
        v_attempt, v_max_attempts, v_backoff * power(2, v_attempt - 1)),
      jsonb_build_object('error', p_error_message));
  ELSE
    -- Move to failed state
    UPDATE ops.queue
    SET
      status = 'failed',
      completed_at = now(),
      error_message = p_error_message,
      error_stack = p_error_stack,
      updated_at = now()
    WHERE id = p_queue_id;

    -- Fail the run
    IF v_run_id IS NOT NULL THEN
      PERFORM ops.fail_run(v_run_id, p_error_message, p_error_stack, FALSE);
    END IF;
  END IF;
END;
$$;

-- Release claim (if worker can't complete)
CREATE OR REPLACE FUNCTION ops.release_claim(
  p_queue_id UUID,
  p_reason TEXT DEFAULT 'released'
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE ops.queue
  SET
    status = 'pending',
    claimed_at = NULL,
    claimed_by = NULL,
    claim_expires_at = NULL,
    updated_at = now()
  WHERE id = p_queue_id AND status = 'claimed';

  INSERT INTO ops.events (level, message, category, metadata)
  VALUES ('info', format('Claim released: %s', p_reason), 'queue',
    jsonb_build_object('queue_id', p_queue_id, 'reason', p_reason));
END;
$$;

-- Cleanup expired claims (run periodically)
CREATE OR REPLACE FUNCTION ops.cleanup_expired_claims()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  WITH expired AS (
    UPDATE ops.queue
    SET
      status = 'pending',
      claimed_at = NULL,
      claimed_by = NULL,
      claim_expires_at = NULL,
      updated_at = now()
    WHERE status = 'claimed'
      AND claim_expires_at < now()
    RETURNING id
  )
  SELECT COUNT(*) INTO v_count FROM expired;

  IF v_count > 0 THEN
    INSERT INTO ops.events (level, message, category, metadata)
    VALUES ('warn', format('Cleaned up %s expired claims', v_count), 'queue',
      jsonb_build_object('count', v_count));
  END IF;

  RETURN v_count;
END;
$$;

-- ============================================================================
-- VIEWS: Queue Monitoring
-- ============================================================================

-- Queue depth by type
CREATE OR REPLACE VIEW ops.v_queue_depth AS
SELECT
  job_type,
  status,
  COUNT(*) as count,
  MIN(scheduled_at) as oldest,
  MAX(scheduled_at) as newest,
  AVG(priority) as avg_priority
FROM ops.queue
GROUP BY job_type, status
ORDER BY job_type, status;

-- Pending jobs ready to run
CREATE OR REPLACE VIEW ops.v_queue_pending AS
SELECT
  id,
  job_type,
  job_name,
  priority,
  scheduled_at,
  attempt,
  max_attempts,
  created_at,
  metadata
FROM ops.queue
WHERE status = 'pending'
  AND scheduled_at <= now()
ORDER BY priority DESC, scheduled_at ASC;

-- Active workers and their claims
CREATE OR REPLACE VIEW ops.v_active_claims AS
SELECT
  claimed_by as worker_id,
  COUNT(*) as claimed_jobs,
  MIN(claimed_at) as oldest_claim,
  ARRAY_AGG(job_type) as job_types
FROM ops.queue
WHERE status = 'claimed'
GROUP BY claimed_by;

-- Failed jobs in last 24h
CREATE OR REPLACE VIEW ops.v_queue_failures AS
SELECT
  id,
  job_type,
  job_name,
  error_message,
  attempt,
  max_attempts,
  completed_at,
  payload,
  metadata
FROM ops.queue
WHERE status = 'failed'
  AND completed_at > now() - interval '24 hours'
ORDER BY completed_at DESC;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Update updated_at on queue changes
CREATE TRIGGER tr_queue_updated_at
  BEFORE UPDATE ON ops.queue
  FOR EACH ROW
  EXECUTE FUNCTION ops.update_updated_at();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE ops.queue IS 'Work items for async job processing. Use ops.enqueue() to add jobs, ops.claim_next() to process.';
COMMENT ON TABLE ops.artifacts IS 'Metadata for artifacts stored in Supabase Storage. Actual files in artifacts bucket.';

COMMENT ON FUNCTION ops.enqueue IS 'Add a job to the queue. Supports deduplication via dedupe_key.';
COMMENT ON FUNCTION ops.claim_next IS 'Atomically claim the next available job. Returns NULL if no jobs available.';
COMMENT ON FUNCTION ops.complete_queued_job IS 'Mark a queued job as successfully completed.';
COMMENT ON FUNCTION ops.fail_queued_job IS 'Mark a queued job as failed. Automatically schedules retry if within max_attempts.';
