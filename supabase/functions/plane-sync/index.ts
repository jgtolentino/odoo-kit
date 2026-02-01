/**
 * Plane Sync Edge Function
 *
 * Creates and updates Plane issues from Platform Kit events.
 * Maintains bidirectional linkage via connectors.entity_mappings.
 *
 * Use Cases:
 * - Create issue when eval regression detected
 * - Create issue when scrape fails repeatedly
 * - Create issue when drift alert fires
 * - Update issue status when resolved
 *
 * Environment variables required:
 * - SUPABASE_URL
 * - SUPABASE_SERVICE_ROLE_KEY
 * - PLANE_BASE_URL (e.g., https://api.plane.so/api/v1)
 * - PLANE_API_TOKEN
 *
 * Optional:
 * - PLANE_WORKSPACE_SLUG (default workspace)
 * - PLANE_PROJECT_ID (default project)
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createServiceClient } from '../_shared/supabase-client.ts'

// Configuration
const PLANE_BASE_URL = Deno.env.get('PLANE_BASE_URL') || 'https://api.plane.so/api/v1'
const PLANE_API_TOKEN = Deno.env.get('PLANE_API_TOKEN')
const PLANE_WORKSPACE_SLUG = Deno.env.get('PLANE_WORKSPACE_SLUG') || 'default'
const PLANE_PROJECT_ID = Deno.env.get('PLANE_PROJECT_ID')

// Types
interface PlaneIssue {
  id: string
  name: string
  description?: string
  state?: string
  priority?: number
  labels?: string[]
  assignees?: string[]
}

interface CreateIssuePayload {
  name: string
  description?: string
  priority?: number
  state?: string
  labels?: string[]
}

interface SyncRequest {
  action: 'create' | 'update' | 'sync_failures' | 'sync_alerts'
  source_type: 'eval_alert' | 'queue_failure' | 'drift_alert' | 'custom'
  source_id: string
  title?: string
  description?: string
  priority?: 'urgent' | 'high' | 'medium' | 'low' | 'none'
  labels?: string[]
  project_id?: string
  workspace_slug?: string
}

// Priority mapping
const PRIORITY_MAP: Record<string, number> = {
  'urgent': 1,
  'high': 2,
  'medium': 3,
  'low': 4,
  'none': 0,
}

/**
 * Make authenticated request to Plane API
 */
async function planeRequest(
  method: string,
  path: string,
  body?: Record<string, unknown>
): Promise<{ ok: boolean; data?: unknown; error?: string }> {
  if (!PLANE_API_TOKEN) {
    return { ok: false, error: 'PLANE_API_TOKEN not configured' }
  }

  const url = `${PLANE_BASE_URL}${path}`

  try {
    const response = await fetch(url, {
      method,
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': PLANE_API_TOKEN,
      },
      body: body ? JSON.stringify(body) : undefined,
    })

    if (!response.ok) {
      const text = await response.text()
      return { ok: false, error: `Plane API error: ${response.status} ${text}` }
    }

    const data = await response.json()
    return { ok: true, data }
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : 'Unknown error' }
  }
}

/**
 * Create a Plane issue
 */
async function createIssue(
  workspaceSlug: string,
  projectId: string,
  payload: CreateIssuePayload
): Promise<{ ok: boolean; issue?: PlaneIssue; error?: string }> {
  const result = await planeRequest(
    'POST',
    `/workspaces/${workspaceSlug}/projects/${projectId}/issues/`,
    payload
  )

  if (!result.ok) {
    return { ok: false, error: result.error }
  }

  return { ok: true, issue: result.data as PlaneIssue }
}

/**
 * Update a Plane issue
 */
async function updateIssue(
  workspaceSlug: string,
  projectId: string,
  issueId: string,
  payload: Partial<CreateIssuePayload>
): Promise<{ ok: boolean; issue?: PlaneIssue; error?: string }> {
  const result = await planeRequest(
    'PATCH',
    `/workspaces/${workspaceSlug}/projects/${projectId}/issues/${issueId}/`,
    payload
  )

  if (!result.ok) {
    return { ok: false, error: result.error }
  }

  return { ok: true, issue: result.data as PlaneIssue }
}

/**
 * Get or create entity mapping for Plane issue
 */
async function getOrCreateMapping(
  supabase: ReturnType<typeof createServiceClient>,
  sourceType: string,
  sourceId: string,
  planeIssueId?: string
): Promise<{ localId: string; remoteId: string | null }> {
  // Get target ID for Plane connector
  const { data: target } = await supabase
    .from('connectors.targets')
    .select('id')
    .eq('connector_type', 'plane')
    .eq('status', 'active')
    .limit(1)
    .single()

  if (!target) {
    // Create default Plane target if not exists
    const { data: newTarget } = await supabase
      .from('connectors.targets')
      .insert({
        name: 'plane-default',
        connector_type: 'plane',
        display_name: 'Plane (Default)',
        base_url: PLANE_BASE_URL,
        status: 'active',
      })
      .select('id')
      .single()

    if (!newTarget) {
      return { localId: sourceId, remoteId: null }
    }
  }

  const targetId = target?.id

  // Check existing mapping
  const { data: existing } = await supabase
    .from('connectors.entity_mappings')
    .select('local_id, remote_id')
    .eq('target_id', targetId)
    .eq('entity_type', sourceType)
    .eq('local_id', sourceId)
    .single()

  if (existing) {
    return { localId: existing.local_id, remoteId: existing.remote_id }
  }

  // Create new mapping if we have a Plane issue ID
  if (planeIssueId && targetId) {
    await supabase.rpc('connectors.get_or_create_mapping', {
      p_target_id: targetId,
      p_entity_type: sourceType,
      p_local_id: sourceId,
      p_remote_id: planeIssueId,
    })
  }

  return { localId: sourceId, remoteId: planeIssueId || null }
}

/**
 * Sync failed queue jobs to Plane issues
 */
async function syncFailedJobs(
  supabase: ReturnType<typeof createServiceClient>,
  workspaceSlug: string,
  projectId: string
): Promise<{ created: number; errors: string[] }> {
  let created = 0
  const errors: string[] = []

  // Get recent failed jobs without Plane issues
  const { data: failedJobs } = await supabase
    .from('ops.queue')
    .select('id, job_type, job_name, error_message, completed_at, attempt, max_attempts')
    .eq('status', 'failed')
    .gte('completed_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
    .order('completed_at', { ascending: false })
    .limit(20)

  if (!failedJobs || failedJobs.length === 0) {
    return { created: 0, errors: [] }
  }

  for (const job of failedJobs) {
    // Check if already has a Plane issue
    const mapping = await getOrCreateMapping(supabase, 'queue_failure', job.id)
    if (mapping.remoteId) {
      continue // Already synced
    }

    // Create Plane issue
    const result = await createIssue(workspaceSlug, projectId, {
      name: `[Auto] Job Failed: ${job.job_name || job.job_type}`,
      description: `## Job Failure\n\n**Job ID:** ${job.id}\n**Type:** ${job.job_type}\n**Attempts:** ${job.attempt}/${job.max_attempts}\n**Failed At:** ${job.completed_at}\n\n### Error\n\`\`\`\n${job.error_message || 'No error message'}\n\`\`\`\n\n---\n*Auto-created by Platform Kit*`,
      priority: job.attempt >= job.max_attempts ? PRIORITY_MAP.high : PRIORITY_MAP.medium,
      labels: ['platform-kit', 'auto-created', 'job-failure'],
    })

    if (result.ok && result.issue) {
      await getOrCreateMapping(supabase, 'queue_failure', job.id, result.issue.id)
      created++
    } else {
      errors.push(`Failed to create issue for job ${job.id}: ${result.error}`)
    }
  }

  return { created, errors }
}

/**
 * Sync drift/eval alerts to Plane issues
 */
async function syncAlerts(
  supabase: ReturnType<typeof createServiceClient>,
  workspaceSlug: string,
  projectId: string
): Promise<{ created: number; errors: string[] }> {
  let created = 0
  const errors: string[] = []

  // Get open alerts without Plane issues
  const { data: alerts } = await supabase
    .from('eval.drift_alerts')
    .select('id, alert_type, severity, title, description, metric_name, metric_value, created_at')
    .in('status', ['open', 'acknowledged'])
    .order('created_at', { ascending: false })
    .limit(20)

  if (!alerts || alerts.length === 0) {
    return { created: 0, errors: [] }
  }

  for (const alert of alerts) {
    // Check if already has a Plane issue
    const mapping = await getOrCreateMapping(supabase, 'drift_alert', alert.id)
    if (mapping.remoteId) {
      continue // Already synced
    }

    // Map severity to priority
    const priority = alert.severity === 'critical'
      ? PRIORITY_MAP.urgent
      : alert.severity === 'warning'
        ? PRIORITY_MAP.high
        : PRIORITY_MAP.medium

    // Create Plane issue
    const result = await createIssue(workspaceSlug, projectId, {
      name: `[Alert] ${alert.title}`,
      description: `## ${alert.alert_type.replace('_', ' ').toUpperCase()}\n\n${alert.description || ''}\n\n**Metric:** ${alert.metric_name || 'N/A'}\n**Value:** ${alert.metric_value || 'N/A'}\n**Detected:** ${alert.created_at}\n\n---\n*Auto-created by Platform Kit*`,
      priority,
      labels: ['platform-kit', 'auto-created', alert.alert_type, alert.severity],
    })

    if (result.ok && result.issue) {
      // Store Plane issue URL in alert
      await supabase
        .from('eval.drift_alerts')
        .update({
          related_issue_url: `${PLANE_BASE_URL.replace('/api/v1', '')}/${workspaceSlug}/projects/${projectId}/issues/${result.issue.id}`,
        })
        .eq('id', alert.id)

      await getOrCreateMapping(supabase, 'drift_alert', alert.id, result.issue.id)
      created++
    } else {
      errors.push(`Failed to create issue for alert ${alert.id}: ${result.error}`)
    }
  }

  return { created, errors }
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

  // Start ops run
  const { data: runId } = await supabase.rpc('ops.start_run', {
    p_system: 'supabase',
    p_job_name: 'plane-sync',
    p_job_type: 'integration',
    p_trigger_type: req.method === 'POST' ? 'api' : 'manual',
  })

  try {
    const url = new URL(req.url)
    const action = url.searchParams.get('action') || 'sync_all'
    const workspaceSlug = url.searchParams.get('workspace') || PLANE_WORKSPACE_SLUG
    const projectId = url.searchParams.get('project') || PLANE_PROJECT_ID

    if (!projectId) {
      throw new Error('PLANE_PROJECT_ID not configured and no project parameter provided')
    }

    let result: { created: number; errors: string[] } = { created: 0, errors: [] }

    switch (action) {
      case 'sync_failures': {
        result = await syncFailedJobs(supabase, workspaceSlug, projectId)
        break
      }

      case 'sync_alerts': {
        result = await syncAlerts(supabase, workspaceSlug, projectId)
        break
      }

      case 'sync_all': {
        const [failures, alerts] = await Promise.all([
          syncFailedJobs(supabase, workspaceSlug, projectId),
          syncAlerts(supabase, workspaceSlug, projectId),
        ])
        result = {
          created: failures.created + alerts.created,
          errors: [...failures.errors, ...alerts.errors],
        }
        break
      }

      case 'create': {
        // Create single issue from request body
        const body = await req.json() as SyncRequest

        if (!body.title) {
          throw new Error('Missing required field: title')
        }

        const issueResult = await createIssue(
          body.workspace_slug || workspaceSlug,
          body.project_id || projectId,
          {
            name: body.title,
            description: body.description,
            priority: body.priority ? PRIORITY_MAP[body.priority] : PRIORITY_MAP.medium,
            labels: body.labels || ['platform-kit'],
          }
        )

        if (!issueResult.ok) {
          throw new Error(issueResult.error)
        }

        // Store mapping
        if (body.source_id) {
          await getOrCreateMapping(supabase, body.source_type, body.source_id, issueResult.issue!.id)
        }

        result = { created: 1, errors: [] }
        break
      }

      default:
        throw new Error(`Unknown action: ${action}`)
    }

    // Complete the run
    await supabase.rpc('ops.complete_run', {
      p_run_id: runId,
      p_records_processed: result.created,
      p_records_failed: result.errors.length,
      p_metadata: {
        action,
        workspace: workspaceSlug,
        project: projectId,
        errors: result.errors,
      },
    })

    return new Response(
      JSON.stringify({
        success: true,
        run_id: runId,
        duration_ms: Date.now() - startTime,
        issues_created: result.created,
        errors: result.errors,
      }),
      {
        status: 200,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      }
    )
  } catch (error) {
    console.error('Plane sync error:', error)

    await supabase.rpc('ops.fail_run', {
      p_run_id: runId,
      p_error_message: error instanceof Error ? error.message : 'Unknown error',
      p_should_retry: false,
    })

    return new Response(
      JSON.stringify({
        success: false,
        run_id: runId,
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
