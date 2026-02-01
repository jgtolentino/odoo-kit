/**
 * Ops Executor Edge Function
 *
 * Claims queued jobs, executes them, and manages the complete job lifecycle.
 * This is the worker process for the Platform Kit execution control plane.
 *
 * Execution Pattern:
 * 1. claim_next() - atomically claim a pending job
 * 2. start_queued_job() - create ops.run for telemetry
 * 3. Execute job handler based on job_type
 * 4. complete_queued_job() or fail_queued_job()
 * 5. Optionally upload artifacts to Storage
 *
 * Environment variables required:
 * - SUPABASE_URL: Supabase project URL
 * - SUPABASE_SERVICE_ROLE_KEY: Service role key
 *
 * Optional:
 * - WORKER_ID: Unique worker identifier (defaults to random UUID)
 * - CLAIM_DURATION_SECONDS: How long to hold a claim (default: 300)
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createServiceClient, logOpsEvent } from '../_shared/supabase-client.ts'

// Types
interface QueuedJob {
  id: string
  job_type: string
  job_name: string | null
  payload: Record<string, unknown>
  attempt: number
  max_attempts: number
  metadata: Record<string, unknown>
}

interface JobResult {
  success: boolean
  result?: Record<string, unknown>
  error?: string
  artifacts?: Array<{
    type: string
    name: string
    content: string | Uint8Array
    contentType: string
  }>
  metrics?: {
    records_processed?: number
    records_failed?: number
  }
}

type JobHandler = (job: QueuedJob, ctx: JobContext) => Promise<JobResult>

interface JobContext {
  supabase: ReturnType<typeof createServiceClient>
  runId: string | null
  workerId: string
  appendLog: (level: string, message: string, data?: Record<string, unknown>) => Promise<void>
  uploadArtifact: (name: string, content: string | Uint8Array, contentType: string) => Promise<string | null>
}

// Worker configuration
const WORKER_ID = Deno.env.get('WORKER_ID') || crypto.randomUUID()
const CLAIM_DURATION = parseInt(Deno.env.get('CLAIM_DURATION_SECONDS') || '300')

/**
 * Job Handlers Registry
 * Add new job types here
 */
const jobHandlers: Record<string, JobHandler> = {
  // Scraping job
  'scrape': async (job, ctx) => {
    const url = job.payload.url as string
    if (!url) {
      return { success: false, error: 'Missing required field: url' }
    }

    await ctx.appendLog('info', `Starting scrape of ${url}`)

    try {
      const startTime = Date.now()
      const response = await fetch(url, {
        headers: {
          'User-Agent': 'Mozilla/5.0 (compatible; PlatformKit/1.0; +https://platform.kit)',
        },
        signal: AbortSignal.timeout(30000),
      })

      const duration = Date.now() - startTime
      const body = await response.text()

      await ctx.appendLog('info', `Fetched ${url} in ${duration}ms`, {
        status: response.status,
        contentLength: body.length,
      })

      // Upload raw HTML as artifact
      const artifactPath = await ctx.uploadArtifact(
        `${job.id}.html`,
        body,
        'text/html'
      )

      // Store in deep_research.raw_fetches
      await ctx.supabase.rpc('deep_research.record_fetch', {
        p_url: url,
        p_status_code: response.status,
        p_response_headers: Object.fromEntries(response.headers.entries()),
        p_body_text: body.length < 100000 ? body : null,
        p_body_ref: artifactPath,
        p_fetch_duration_ms: duration,
        p_queue_id: job.id,
      })

      return {
        success: true,
        result: {
          status: response.status,
          contentLength: body.length,
          duration,
          artifactPath,
        },
        metrics: { records_processed: 1 },
      }
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error',
      }
    }
  },

  // ETL job
  'etl': async (job, ctx) => {
    const source = job.payload.source as string
    const target = job.payload.target as string

    if (!source || !target) {
      return { success: false, error: 'Missing required fields: source, target' }
    }

    await ctx.appendLog('info', `Starting ETL: ${source} → ${target}`)

    // TODO: Implement actual ETL logic based on source/target types
    // This is a placeholder that demonstrates the pattern

    return {
      success: true,
      result: { source, target, status: 'completed' },
      metrics: { records_processed: 0 },
    }
  },

  // Evaluation job
  'eval': async (job, ctx) => {
    const goldenSetId = job.payload.golden_set_id as string

    if (!goldenSetId) {
      return { success: false, error: 'Missing required field: golden_set_id' }
    }

    await ctx.appendLog('info', `Starting evaluation for golden set ${goldenSetId}`)

    // Create eval run
    const { data: evalRun, error: createError } = await ctx.supabase
      .from('eval.eval_runs')
      .insert({
        golden_set_id: goldenSetId,
        status: 'running',
        started_at: new Date().toISOString(),
        queue_id: job.id,
        ops_run_id: ctx.runId,
      })
      .select('id')
      .single()

    if (createError) {
      return { success: false, error: `Failed to create eval run: ${createError.message}` }
    }

    // Get examples
    const { data: examples } = await ctx.supabase
      .from('eval.golden_examples')
      .select('*')
      .eq('golden_set_id', goldenSetId)
      .eq('is_active', true)
      .order('example_order')

    if (!examples || examples.length === 0) {
      return { success: false, error: 'No active examples in golden set' }
    }

    let passed = 0
    let failed = 0

    // Process each example
    for (const example of examples) {
      try {
        // TODO: Run actual evaluation logic
        // For now, we'll simulate with a simple comparison
        const actualOutput = example.expected_output // Placeholder
        const score = 1.0 // Placeholder

        await ctx.supabase
          .from('eval.scores')
          .insert({
            eval_run_id: evalRun.id,
            example_id: example.id,
            passed: true,
            actual_output: actualOutput,
            score,
          })

        passed++
      } catch (error) {
        await ctx.supabase
          .from('eval.scores')
          .insert({
            eval_run_id: evalRun.id,
            example_id: example.id,
            passed: false,
            error_message: error instanceof Error ? error.message : 'Unknown error',
          })

        failed++
      }
    }

    // Score the run
    await ctx.supabase.rpc('eval.score_run', {
      p_run_id: evalRun.id,
    })

    return {
      success: true,
      result: {
        eval_run_id: evalRun.id,
        passed,
        failed,
        total: examples.length,
      },
      metrics: { records_processed: examples.length, records_failed: failed },
    }
  },

  // CMS publish job
  'cms_publish': async (job, ctx) => {
    const publicationId = job.payload.publication_id as string
    const channel = job.payload.channel as string

    if (!publicationId) {
      return { success: false, error: 'Missing required field: publication_id' }
    }

    await ctx.appendLog('info', `Publishing to ${channel}`, { publicationId })

    // Get publication details
    const { data: publication, error: pubError } = await ctx.supabase
      .from('cms.publications')
      .select(`
        *,
        item:item_id(*),
        template:template_id(*)
      `)
      .eq('id', publicationId)
      .single()

    if (pubError || !publication) {
      return { success: false, error: `Publication not found: ${publicationId}` }
    }

    // Render content
    let renderedContent = publication.item.content
    if (publication.template) {
      const { data: rendered } = await ctx.supabase.rpc('cms.render_template', {
        p_template_id: publication.template.id,
        p_data: {
          title: publication.item.title,
          content: publication.item.content,
          summary: publication.item.summary,
          ...publication.item.metadata,
        },
      })
      renderedContent = rendered || renderedContent
    }

    // Update publication with rendered content
    await ctx.supabase
      .from('cms.publications')
      .update({
        rendered_content: renderedContent,
        rendered_at: new Date().toISOString(),
        status: 'sending',
        started_at: new Date().toISOString(),
      })
      .eq('id', publicationId)

    // TODO: Actually publish to the channel
    // For now, we'll simulate success
    const externalId = `sim_${crypto.randomUUID().slice(0, 8)}`
    const externalUrl = `https://example.com/posts/${externalId}`

    await ctx.supabase.rpc('cms.complete_publication', {
      p_publication_id: publicationId,
      p_external_id: externalId,
      p_external_url: externalUrl,
      p_response_data: { simulated: true },
    })

    return {
      success: true,
      result: { externalId, externalUrl, channel },
      metrics: { records_processed: 1 },
    }
  },

  // Webhook processing job
  'process_webhook': async (job, ctx) => {
    const webhookId = job.payload.webhook_id as string

    if (!webhookId) {
      return { success: false, error: 'Missing required field: webhook_id' }
    }

    await ctx.appendLog('info', `Processing webhook ${webhookId}`)

    // Get webhook details
    const { data: webhook, error: webhookError } = await ctx.supabase
      .from('connectors.webhooks_inbox')
      .select('*')
      .eq('id', webhookId)
      .single()

    if (webhookError || !webhook) {
      return { success: false, error: `Webhook not found: ${webhookId}` }
    }

    // Process based on source type
    await ctx.appendLog('info', `Processing ${webhook.source_type} webhook: ${webhook.event_type}`)

    // TODO: Implement actual webhook processing logic
    // This would dispatch to type-specific handlers

    // Mark as processed
    await ctx.supabase
      .from('connectors.webhooks_inbox')
      .update({
        processed: true,
        processed_at: new Date().toISOString(),
        queue_id: job.id,
      })
      .eq('id', webhookId)

    return {
      success: true,
      result: {
        webhookId,
        sourceType: webhook.source_type,
        eventType: webhook.event_type,
      },
      metrics: { records_processed: 1 },
    }
  },

  // Health check job (for scheduled health checks)
  'health_check': async (_job, ctx) => {
    await ctx.appendLog('info', 'Running scheduled health check')

    // Call the health-check function
    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

    const response = await fetch(`${supabaseUrl}/functions/v1/health-check?action=full`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${serviceKey}`,
        'Content-Type': 'application/json',
      },
    })

    const result = await response.json()

    return {
      success: response.ok,
      result,
      error: response.ok ? undefined : result.error,
    }
  },

  // Connector sync job
  'connector_sync': async (job, ctx) => {
    const targetId = job.payload.target_id as string
    const entityType = job.payload.entity_type as string

    if (!targetId) {
      return { success: false, error: 'Missing required field: target_id' }
    }

    await ctx.appendLog('info', `Starting sync for target ${targetId}`, { entityType })

    // Get target details
    const { data: target, error: targetError } = await ctx.supabase
      .from('connectors.targets')
      .select('*')
      .eq('id', targetId)
      .single()

    if (targetError || !target) {
      return { success: false, error: `Target not found: ${targetId}` }
    }

    // TODO: Implement actual sync logic based on connector type
    // This would dispatch to connector-specific handlers

    // Update sync state
    await ctx.supabase
      .from('connectors.sync_state')
      .upsert({
        target_id: targetId,
        entity_type: entityType || 'all',
        last_sync_at: new Date().toISOString(),
        sync_in_progress: false,
      }, {
        onConflict: 'target_id,entity_type',
      })

    return {
      success: true,
      result: {
        targetId,
        targetName: target.name,
        connectorType: target.connector_type,
      },
      metrics: { records_processed: 0 },
    }
  },
}

/**
 * Create job execution context
 */
function createJobContext(
  supabase: ReturnType<typeof createServiceClient>,
  runId: string | null,
  workerId: string,
  jobId: string
): JobContext {
  return {
    supabase,
    runId,
    workerId,

    appendLog: async (level: string, message: string, data?: Record<string, unknown>) => {
      if (runId) {
        await supabase.rpc('ops.append_event', {
          p_run_id: runId,
          p_level: level,
          p_message: message,
          p_data: data || {},
        })
      }
      console.log(`[${level.toUpperCase()}] ${message}`, data || '')
    },

    uploadArtifact: async (name: string, content: string | Uint8Array, contentType: string) => {
      try {
        const path = `${jobId}/${name}`
        const bucket = 'artifacts'

        const { error } = await supabase.storage
          .from(bucket)
          .upload(path, content, { contentType })

        if (error) {
          console.error('Failed to upload artifact:', error)
          return null
        }

        // Record artifact metadata
        await supabase
          .from('ops.artifacts')
          .insert({
            run_id: runId,
            queue_id: jobId,
            bucket,
            path,
            content_type: contentType,
            size_bytes: typeof content === 'string' ? content.length : content.byteLength,
            artifact_type: name.split('.').pop() || 'unknown',
            artifact_name: name,
          })

        return path
      } catch (error) {
        console.error('Failed to upload artifact:', error)
        return null
      }
    },
  }
}

/**
 * Execute a single job
 */
async function executeJob(job: QueuedJob): Promise<JobResult> {
  const supabase = createServiceClient()

  // Start the job (creates ops.run)
  const { data: runId } = await supabase.rpc('ops.start_queued_job', {
    p_queue_id: job.id,
  })

  const ctx = createJobContext(supabase, runId, WORKER_ID, job.id)

  await ctx.appendLog('info', `Executing job ${job.job_type}`, {
    jobId: job.id,
    attempt: job.attempt,
    maxAttempts: job.max_attempts,
  })

  // Get handler
  const handler = jobHandlers[job.job_type]
  if (!handler) {
    const error = `Unknown job type: ${job.job_type}`
    await ctx.appendLog('error', error)
    return { success: false, error }
  }

  try {
    // Execute the job
    const result = await handler(job, ctx)

    if (result.success) {
      // Complete the job
      await supabase.rpc('ops.complete_queued_job', {
        p_queue_id: job.id,
        p_result: result.result || {},
        p_metrics: result.metrics || {},
      })

      await ctx.appendLog('info', 'Job completed successfully', result.result)
    } else {
      // Fail the job
      await supabase.rpc('ops.fail_queued_job', {
        p_queue_id: job.id,
        p_error_message: result.error || 'Unknown error',
        p_should_retry: job.attempt < job.max_attempts,
      })

      await ctx.appendLog('error', 'Job failed', { error: result.error })
    }

    return result
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error'

    await supabase.rpc('ops.fail_queued_job', {
      p_queue_id: job.id,
      p_error_message: errorMessage,
      p_error_stack: error instanceof Error ? error.stack : undefined,
      p_should_retry: job.attempt < job.max_attempts,
    })

    await ctx.appendLog('fatal', 'Job execution failed with exception', { error: errorMessage })

    return { success: false, error: errorMessage }
  }
}

/**
 * Main handler
 */
serve(async (req: Request): Promise<Response> => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      },
    })
  }

  const supabase = createServiceClient()
  const startTime = Date.now()

  // Parse action from query params
  const url = new URL(req.url)
  const action = url.searchParams.get('action') || 'process'
  const jobTypes = url.searchParams.get('types')?.split(',') || null
  const maxJobs = parseInt(url.searchParams.get('max') || '1')

  try {
    switch (action) {
      case 'process': {
        // Process jobs from queue
        const results: Array<{ jobId: string; success: boolean; error?: string }> = []

        for (let i = 0; i < maxJobs; i++) {
          // Claim next job
          const { data: jobs } = await supabase.rpc('ops.claim_next', {
            p_worker_id: WORKER_ID,
            p_job_types: jobTypes,
            p_claim_duration_seconds: CLAIM_DURATION,
          })

          if (!jobs || jobs.length === 0) {
            // No more jobs available
            break
          }

          const job = jobs[0] as QueuedJob
          const result = await executeJob(job)

          results.push({
            jobId: job.id,
            success: result.success,
            error: result.error,
          })
        }

        return new Response(
          JSON.stringify({
            success: true,
            workerId: WORKER_ID,
            processed: results.length,
            results,
            duration_ms: Date.now() - startTime,
          }),
          {
            status: 200,
            headers: {
              'Content-Type': 'application/json',
              'Access-Control-Allow-Origin': '*',
            },
          }
        )
      }

      case 'status': {
        // Get queue status
        const { data: depth } = await supabase
          .from('ops.v_queue_depth')
          .select('*')

        const { data: pending } = await supabase
          .from('ops.v_queue_pending')
          .select('*')
          .limit(10)

        const { data: claims } = await supabase
          .from('ops.v_active_claims')
          .select('*')

        return new Response(
          JSON.stringify({
            success: true,
            queue: {
              depth,
              pending: pending?.length || 0,
              activeClaims: claims,
            },
          }),
          {
            status: 200,
            headers: {
              'Content-Type': 'application/json',
              'Access-Control-Allow-Origin': '*',
            },
          }
        )
      }

      case 'cleanup': {
        // Cleanup expired claims
        const { data: cleaned } = await supabase.rpc('ops.cleanup_expired_claims')

        return new Response(
          JSON.stringify({
            success: true,
            cleaned: cleaned || 0,
          }),
          {
            status: 200,
            headers: {
              'Content-Type': 'application/json',
              'Access-Control-Allow-Origin': '*',
            },
          }
        )
      }

      case 'enqueue': {
        // Enqueue a new job from request body
        const body = await req.json()

        if (!body.job_type) {
          return new Response(
            JSON.stringify({ success: false, error: 'Missing required field: job_type' }),
            { status: 400, headers: { 'Content-Type': 'application/json' } }
          )
        }

        const { data: queueId } = await supabase.rpc('ops.enqueue', {
          p_job_type: body.job_type,
          p_payload: body.payload || {},
          p_dedupe_key: body.dedupe_key,
          p_schedule_at: body.schedule_at,
          p_priority: body.priority || 0,
          p_max_attempts: body.max_attempts || 3,
          p_job_name: body.job_name,
          p_tags: body.tags || [],
          p_metadata: body.metadata || {},
        })

        return new Response(
          JSON.stringify({
            success: true,
            queue_id: queueId,
          }),
          {
            status: 200,
            headers: {
              'Content-Type': 'application/json',
              'Access-Control-Allow-Origin': '*',
            },
          }
        )
      }

      default:
        return new Response(
          JSON.stringify({ success: false, error: `Unknown action: ${action}` }),
          { status: 400, headers: { 'Content-Type': 'application/json' } }
        )
    }
  } catch (error) {
    console.error('Executor error:', error)

    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error',
      }),
      {
        status: 500,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      }
    )
  }
})
