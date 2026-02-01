/**
 * Plane ↔ Odoo Sync Edge Function
 *
 * Bidirectional webhook handler for syncing between Plane CE and Odoo.
 * Uses Supabase as the orchestration layer with full audit logging.
 *
 * Pattern:
 *   Plane Webhook → This Function → ops.events + odoo-proxy → Odoo
 *   Odoo Webhook  → This Function → ops.events + Plane API  → Plane
 *
 * Endpoints:
 *   POST ?source=plane   - Handle Plane webhooks (issue created, updated, etc.)
 *   POST ?source=odoo    - Handle Odoo webhooks (task created, sale confirmed, etc.)
 *   GET  ?action=status  - Get sync status and recent activity
 *   POST ?action=sync    - Manual sync trigger for specific entities
 *
 * Environment Variables:
 *   - PLANE_API_URL: Plane CE API endpoint
 *   - PLANE_API_KEY: Plane API key
 *   - SUPABASE_URL: Supabase project URL
 *   - SUPABASE_SERVICE_ROLE_KEY: For database operations
 *   - PLANE_WEBHOOK_SECRET: For verifying Plane webhooks
 *   - ODOO_WEBHOOK_SECRET: For verifying Odoo webhooks
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Entity mapping configuration
const ENTITY_MAPPINGS = {
  // Plane → Odoo mappings
  plane_to_odoo: {
    issue: 'project.task',
    project: 'project.project',
    cycle: 'project.milestone',
    module: 'project.project', // Maps to sub-project
  },
  // Odoo → Plane mappings
  odoo_to_plane: {
    'project.task': 'issue',
    'project.project': 'project',
    'sale.order': 'issue', // Sales orders create visibility issues
    'account.move': 'issue', // Invoices create visibility issues
  },
}

// Priority mappings
const PRIORITY_MAP = {
  plane_to_odoo: {
    urgent: '3',
    high: '2',
    medium: '1',
    low: '0',
    none: '0',
  },
  odoo_to_plane: {
    '3': 'urgent',
    '2': 'high',
    '1': 'medium',
    '0': 'low',
  },
}

interface SyncResult {
  success: boolean
  source_id: string
  target_id?: string
  entity_type: string
  action: string
  error?: string
}

/**
 * Get required environment variable
 */
function required(name: string): string {
  const value = Deno.env.get(name)
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`)
  }
  return value
}

/**
 * Get Supabase client with service role
 */
function getSupabaseClient(): SupabaseClient {
  return createClient(
    required('SUPABASE_URL'),
    required('SUPABASE_SERVICE_ROLE_KEY')
  )
}

/**
 * Verify webhook signature (HMAC-SHA256)
 */
async function verifyWebhookSignature(
  payload: string,
  signature: string,
  secret: string
): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey(
      'raw',
      new TextEncoder().encode(secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['verify']
    )

    const signatureBytes = hexToBytes(signature)
    const payloadBytes = new TextEncoder().encode(payload)

    return await crypto.subtle.verify('HMAC', key, signatureBytes, payloadBytes)
  } catch {
    return false
  }
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substr(i, 2), 16)
  }
  return bytes
}

/**
 * Log sync event to ops.events
 */
async function logSyncEvent(
  supabase: SupabaseClient,
  level: 'info' | 'warning' | 'error',
  message: string,
  metadata: Record<string, unknown>
): Promise<void> {
  try {
    await supabase.rpc('ops.log_event', {
      p_level: level,
      p_message: message,
      p_system: 'supabase',
      p_category: 'plane-sync',
      p_event_type: 'webhook',
      p_component: 'plane-sync',
      p_metadata: metadata,
    })
  } catch (err) {
    console.error('Failed to log sync event:', err)
  }
}

/**
 * Record sync mapping in database
 */
async function recordSyncMapping(
  supabase: SupabaseClient,
  source: 'plane' | 'odoo',
  sourceId: string,
  sourceType: string,
  targetId: string,
  targetType: string
): Promise<void> {
  await supabase.from('plane.sync_mappings').upsert({
    source_system: source,
    source_id: sourceId,
    source_type: sourceType,
    target_id: targetId,
    target_type: targetType,
    last_synced_at: new Date().toISOString(),
  }, {
    onConflict: 'source_system,source_id,source_type',
  })
}

/**
 * Get existing mapping for an entity
 */
async function getMapping(
  supabase: SupabaseClient,
  source: 'plane' | 'odoo',
  sourceId: string,
  sourceType: string
): Promise<{ target_id: string; target_type: string } | null> {
  const { data } = await supabase
    .from('plane.sync_mappings')
    .select('target_id, target_type')
    .eq('source_system', source)
    .eq('source_id', sourceId)
    .eq('source_type', sourceType)
    .single()

  return data
}

/**
 * Call Plane API
 */
async function callPlaneApi(
  method: string,
  path: string,
  body?: Record<string, unknown>
): Promise<Response> {
  const planeUrl = required('PLANE_API_URL')
  const planeKey = required('PLANE_API_KEY')

  const response = await fetch(`${planeUrl}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      'X-API-Key': planeKey,
    },
    body: body ? JSON.stringify(body) : undefined,
  })

  return response
}

/**
 * Call Odoo via odoo-proxy Edge Function
 */
async function callOdooProxy(
  path: string,
  method: string,
  body?: Record<string, unknown>
): Promise<Response> {
  const supabaseUrl = required('SUPABASE_URL')
  const serviceKey = required('SUPABASE_SERVICE_ROLE_KEY')

  const response = await fetch(
    `${supabaseUrl}/functions/v1/odoo-proxy?path=${encodeURIComponent(path)}&skip_auth=true`,
    {
      method,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${serviceKey}`,
      },
      body: body ? JSON.stringify(body) : undefined,
    }
  )

  return response
}

/**
 * Handle Plane webhook
 */
async function handlePlaneWebhook(
  supabase: SupabaseClient,
  event: string,
  payload: Record<string, unknown>
): Promise<SyncResult> {
  const eventParts = event.split('.')
  const entityType = eventParts[0] // e.g., 'issue', 'project'
  const action = eventParts[1] // e.g., 'created', 'updated'

  const sourceId = String(payload.id || payload.issue_id || '')
  const odooModel = ENTITY_MAPPINGS.plane_to_odoo[entityType as keyof typeof ENTITY_MAPPINGS.plane_to_odoo]

  if (!odooModel) {
    return {
      success: false,
      source_id: sourceId,
      entity_type: entityType,
      action,
      error: `No Odoo mapping for Plane entity type: ${entityType}`,
    }
  }

  try {
    // Check for existing mapping
    const existingMapping = await getMapping(supabase, 'plane', sourceId, entityType)

    if (action === 'deleted') {
      // Archive in Odoo instead of deleting
      if (existingMapping) {
        await callOdooProxy('/ipai/write/', 'POST', {
          model: odooModel,
          id: existingMapping.target_id,
          values: { active: false },
        })
      }
      return {
        success: true,
        source_id: sourceId,
        target_id: existingMapping?.target_id,
        entity_type: entityType,
        action: 'archived',
      }
    }

    // Build Odoo values from Plane data
    const odooValues = transformPlaneToOdoo(entityType, payload)

    let targetId: string

    if (existingMapping) {
      // Update existing Odoo record
      await callOdooProxy('/ipai/write/', 'POST', {
        model: odooModel,
        id: existingMapping.target_id,
        values: odooValues,
      })
      targetId = existingMapping.target_id
    } else {
      // Create new Odoo record
      const createResponse = await callOdooProxy('/ipai/write/', 'POST', {
        model: odooModel,
        values: odooValues,
      })
      const createResult = await createResponse.json()
      targetId = String(createResult.id || createResult.result)

      // Record mapping
      await recordSyncMapping(supabase, 'plane', sourceId, entityType, targetId, odooModel)
    }

    return {
      success: true,
      source_id: sourceId,
      target_id: targetId,
      entity_type: entityType,
      action,
    }
  } catch (err) {
    return {
      success: false,
      source_id: sourceId,
      entity_type: entityType,
      action,
      error: err instanceof Error ? err.message : 'Unknown error',
    }
  }
}

/**
 * Handle Odoo webhook
 */
async function handleOdooWebhook(
  supabase: SupabaseClient,
  model: string,
  action: string,
  payload: Record<string, unknown>
): Promise<SyncResult> {
  const sourceId = String(payload.id || '')
  const planeType = ENTITY_MAPPINGS.odoo_to_plane[model as keyof typeof ENTITY_MAPPINGS.odoo_to_plane]

  if (!planeType) {
    return {
      success: false,
      source_id: sourceId,
      entity_type: model,
      action,
      error: `No Plane mapping for Odoo model: ${model}`,
    }
  }

  try {
    // Check for existing mapping
    const existingMapping = await getMapping(supabase, 'odoo', sourceId, model)

    if (action === 'unlink') {
      // Archive in Plane
      if (existingMapping) {
        await callPlaneApi('PATCH', `/api/v1/issues/${existingMapping.target_id}/`, {
          archived_at: new Date().toISOString(),
        })
      }
      return {
        success: true,
        source_id: sourceId,
        target_id: existingMapping?.target_id,
        entity_type: model,
        action: 'archived',
      }
    }

    // Build Plane values from Odoo data
    const planeValues = transformOdooToPlane(model, payload)

    let targetId: string

    if (existingMapping) {
      // Update existing Plane issue
      await callPlaneApi('PATCH', `/api/v1/issues/${existingMapping.target_id}/`, planeValues)
      targetId = existingMapping.target_id
    } else {
      // Create new Plane issue
      const createResponse = await callPlaneApi('POST', '/api/v1/issues/', planeValues)
      const createResult = await createResponse.json()
      targetId = String(createResult.id)

      // Record mapping
      await recordSyncMapping(supabase, 'odoo', sourceId, model, targetId, planeType)
    }

    return {
      success: true,
      source_id: sourceId,
      target_id: targetId,
      entity_type: model,
      action,
    }
  } catch (err) {
    return {
      success: false,
      source_id: sourceId,
      entity_type: model,
      action,
      error: err instanceof Error ? err.message : 'Unknown error',
    }
  }
}

/**
 * Transform Plane entity to Odoo values
 */
function transformPlaneToOdoo(
  entityType: string,
  payload: Record<string, unknown>
): Record<string, unknown> {
  switch (entityType) {
    case 'issue':
      return {
        name: payload.name || payload.title,
        description: payload.description || '',
        priority: PRIORITY_MAP.plane_to_odoo[(payload.priority as string) || 'none'],
        x_plane_id: payload.id,
        x_plane_url: payload.url || '',
      }
    case 'project':
      return {
        name: payload.name,
        description: payload.description || '',
        x_plane_id: payload.id,
      }
    default:
      return { name: payload.name || 'Synced from Plane' }
  }
}

/**
 * Transform Odoo entity to Plane values
 */
function transformOdooToPlane(
  model: string,
  payload: Record<string, unknown>
): Record<string, unknown> {
  switch (model) {
    case 'project.task':
      return {
        name: payload.name,
        description: payload.description || '',
        priority: PRIORITY_MAP.odoo_to_plane[(payload.priority as string) || '0'],
      }
    case 'sale.order':
      return {
        name: `[Sale] ${payload.name}`,
        description: `Sale Order: ${payload.name}\nCustomer: ${payload.partner_id}\nAmount: ${payload.amount_total}`,
        priority: 'medium',
        labels: ['sales', 'odoo-sync'],
      }
    case 'account.move':
      return {
        name: `[Invoice] ${payload.name}`,
        description: `Invoice: ${payload.name}\nPartner: ${payload.partner_id}\nAmount: ${payload.amount_total}`,
        priority: 'medium',
        labels: ['finance', 'odoo-sync'],
      }
    default:
      return { name: payload.name || 'Synced from Odoo' }
  }
}

/**
 * Get sync status
 */
async function getSyncStatus(supabase: SupabaseClient): Promise<Record<string, unknown>> {
  const [mappingsResult, recentEventsResult] = await Promise.all([
    supabase.from('plane.sync_mappings').select('source_system, count').limit(100),
    supabase
      .from('ops.events')
      .select('*')
      .eq('category', 'plane-sync')
      .order('created_at', { ascending: false })
      .limit(20),
  ])

  return {
    mappings: mappingsResult.data || [],
    recent_events: recentEventsResult.data || [],
    last_checked: new Date().toISOString(),
  }
}

/**
 * Main handler
 */
serve(async (req: Request): Promise<Response> => {
  const startTime = Date.now()

  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Plane-Signature, X-Odoo-Signature',
      },
    })
  }

  const url = new URL(req.url)
  const source = url.searchParams.get('source') // 'plane' or 'odoo'
  const action = url.searchParams.get('action') // 'status' or 'sync'

  const supabase = getSupabaseClient()

  try {
    // Handle status request
    if (req.method === 'GET' && action === 'status') {
      const status = await getSyncStatus(supabase)
      return new Response(JSON.stringify({ ok: true, ...status }), {
        headers: { 'Content-Type': 'application/json' },
      })
    }

    // Require POST for webhooks
    if (req.method !== 'POST') {
      return new Response(JSON.stringify({ ok: false, error: 'Method not allowed' }), {
        status: 405,
        headers: { 'Content-Type': 'application/json' },
      })
    }

    const rawBody = await req.text()
    const payload = JSON.parse(rawBody)

    let result: SyncResult

    if (source === 'plane') {
      // Verify Plane webhook signature
      const signature = req.headers.get('X-Plane-Signature') || ''
      const webhookSecret = Deno.env.get('PLANE_WEBHOOK_SECRET') || ''

      if (webhookSecret && signature) {
        const valid = await verifyWebhookSignature(rawBody, signature, webhookSecret)
        if (!valid) {
          await logSyncEvent(supabase, 'warning', 'Invalid Plane webhook signature', {
            source: 'plane',
          })
          return new Response(JSON.stringify({ ok: false, error: 'Invalid signature' }), {
            status: 401,
            headers: { 'Content-Type': 'application/json' },
          })
        }
      }

      const event = payload.event || payload.type || 'issue.updated'
      result = await handlePlaneWebhook(supabase, event, payload.data || payload)

    } else if (source === 'odoo') {
      // Verify Odoo webhook signature
      const signature = req.headers.get('X-Odoo-Signature') || ''
      const webhookSecret = Deno.env.get('ODOO_WEBHOOK_SECRET') || ''

      if (webhookSecret && signature) {
        const valid = await verifyWebhookSignature(rawBody, signature, webhookSecret)
        if (!valid) {
          await logSyncEvent(supabase, 'warning', 'Invalid Odoo webhook signature', {
            source: 'odoo',
          })
          return new Response(JSON.stringify({ ok: false, error: 'Invalid signature' }), {
            status: 401,
            headers: { 'Content-Type': 'application/json' },
          })
        }
      }

      const model = payload.model || 'project.task'
      const odooAction = payload.action || payload.method || 'write'
      result = await handleOdooWebhook(supabase, model, odooAction, payload.data || payload)

    } else {
      return new Response(JSON.stringify({ ok: false, error: 'Missing source parameter (plane or odoo)' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      })
    }

    // Log the sync result
    await logSyncEvent(
      supabase,
      result.success ? 'info' : 'error',
      `Sync ${result.action}: ${result.entity_type} ${result.source_id}`,
      {
        ...result,
        source,
        duration_ms: Date.now() - startTime,
      }
    )

    return new Response(JSON.stringify({ ok: result.success, ...result }), {
      status: result.success ? 200 : 500,
      headers: { 'Content-Type': 'application/json' },
    })

  } catch (err) {
    const errorMessage = err instanceof Error ? err.message : 'Unknown error'

    await logSyncEvent(supabase, 'error', `Sync error: ${errorMessage}`, {
      source,
      error: errorMessage,
      duration_ms: Date.now() - startTime,
    })

    return new Response(JSON.stringify({ ok: false, error: errorMessage }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }
})
