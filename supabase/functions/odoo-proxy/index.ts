/**
 * Odoo Proxy Edge Function
 *
 * Secure gateway for Vercel apps to call Odoo (System of Record).
 * Signs requests with HMAC so Odoo can verify the caller.
 *
 * Pattern:
 *   Vercel App → Supabase Auth → This Function → Odoo API
 *
 * NEVER let apps call Odoo directly. This function:
 * 1. Verifies the Supabase JWT
 * 2. Signs the request with HMAC
 * 3. Forwards to Odoo
 * 4. Returns the response
 *
 * Environment Variables:
 * - ODOO_BASE_URL: Odoo server URL (e.g., https://erp.example.com)
 * - IPAI_APP_HMAC_SECRET: Shared secret with Odoo (must match Odoo's env)
 * - SUPABASE_URL: For JWT verification
 * - SUPABASE_ANON_KEY: For JWT verification
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

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
 * Calculate HMAC-SHA256 signature
 */
async function hmacSha256Hex(secret: string, data: Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  )
  const signature = await crypto.subtle.sign('HMAC', key, data)
  return Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

/**
 * Verify Supabase JWT and extract user info
 */
async function verifyJwt(
  authHeader: string | null
): Promise<{ valid: boolean; user?: Record<string, unknown>; error?: string }> {
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return { valid: false, error: 'Missing or invalid Authorization header' }
  }

  const token = authHeader.replace('Bearer ', '')

  try {
    const supabaseUrl = required('SUPABASE_URL')
    const supabaseAnonKey = required('SUPABASE_ANON_KEY')

    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: {
        headers: { Authorization: `Bearer ${token}` },
      },
    })

    const { data: { user }, error } = await supabase.auth.getUser()

    if (error || !user) {
      return { valid: false, error: error?.message || 'Invalid token' }
    }

    return { valid: true, user: user as unknown as Record<string, unknown> }
  } catch (err) {
    return { valid: false, error: err instanceof Error ? err.message : 'JWT verification failed' }
  }
}

/**
 * Forward request to Odoo with HMAC signature
 */
async function forwardToOdoo(
  path: string,
  method: string,
  body: Uint8Array,
  contentType: string,
  user?: Record<string, unknown>
): Promise<Response> {
  const odooBaseUrl = required('ODOO_BASE_URL')
  const hmacSecret = required('IPAI_APP_HMAC_SECRET')

  // Calculate signature
  const signature = await hmacSha256Hex(hmacSecret, body)

  // Build request URL
  const url = `${odooBaseUrl}${path}`

  // Forward headers
  const headers: Record<string, string> = {
    'Content-Type': contentType || 'application/json',
    'X-IPAI-SIGNATURE': signature,
    'X-IPAI-TIMESTAMP': Date.now().toString(),
  }

  // Add user context if available
  if (user) {
    headers['X-IPAI-USER-ID'] = (user.id as string) || ''
    headers['X-IPAI-USER-EMAIL'] = (user.email as string) || ''

    // Extract company_id from metadata if present
    const metadata = (user.user_metadata || user.app_metadata || {}) as Record<string, unknown>
    if (metadata.company_id) {
      headers['X-IPAI-COMPANY-ID'] = String(metadata.company_id)
    }
  }

  // Forward the request
  const response = await fetch(url, {
    method,
    headers,
    body: body.length > 0 ? body : undefined,
  })

  // Return the response
  return new Response(response.body, {
    status: response.status,
    headers: {
      'Content-Type': response.headers.get('Content-Type') || 'application/json',
      'Access-Control-Allow-Origin': '*',
    },
  })
}

/**
 * Log the request to ops.events
 */
async function logRequest(
  path: string,
  method: string,
  status: number,
  durationMs: number,
  user?: Record<string, unknown>,
  error?: string
): Promise<void> {
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

    if (!supabaseUrl || !serviceRoleKey) return

    const supabase = createClient(supabaseUrl, serviceRoleKey)

    await supabase.rpc('ops.log_event', {
      p_level: error ? 'error' : 'info',
      p_message: error || `Odoo proxy: ${method} ${path}`,
      p_system: 'supabase',
      p_category: 'odoo-proxy',
      p_event_type: 'http_request',
      p_component: 'odoo-proxy',
      p_duration_ms: durationMs,
      p_metadata: {
        path,
        method,
        status,
        user_id: user?.id,
        user_email: user?.email,
        error,
      },
    })
  } catch (err) {
    console.error('Failed to log request:', err)
  }
}

/**
 * Main handler
 */
serve(async (req: Request): Promise<Response> => {
  const startTime = Date.now()

  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        'Access-Control-Max-Age': '86400',
      },
    })
  }

  const url = new URL(req.url)
  const path = url.searchParams.get('path')

  // Validate path parameter
  if (!path) {
    return new Response(
      JSON.stringify({ ok: false, error: 'Missing path parameter' }),
      {
        status: 400,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      }
    )
  }

  // Validate path starts with allowed prefixes
  const allowedPrefixes = ['/ipai/', '/web/', '/api/']
  if (!allowedPrefixes.some((prefix) => path.startsWith(prefix))) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: `Path must start with one of: ${allowedPrefixes.join(', ')}`,
      }),
      {
        status: 400,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      }
    )
  }

  try {
    // Verify JWT (optional - can be disabled for internal calls)
    const skipAuth = url.searchParams.get('skip_auth') === 'true'
    let user: Record<string, unknown> | undefined

    if (!skipAuth) {
      const authResult = await verifyJwt(req.headers.get('Authorization'))

      if (!authResult.valid) {
        await logRequest(path, req.method, 401, Date.now() - startTime, undefined, authResult.error)

        return new Response(
          JSON.stringify({ ok: false, error: authResult.error }),
          {
            status: 401,
            headers: {
              'Content-Type': 'application/json',
              'Access-Control-Allow-Origin': '*',
            },
          }
        )
      }

      user = authResult.user
    }

    // Get request body
    const body = new Uint8Array(await req.arrayBuffer())
    const contentType = req.headers.get('Content-Type') || 'application/json'

    // Forward to Odoo
    const response = await forwardToOdoo(path, req.method, body, contentType, user)

    // Log the request
    await logRequest(path, req.method, response.status, Date.now() - startTime, user)

    // Record cost metrics
    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

    if (supabaseUrl && serviceRoleKey) {
      const supabase = createClient(supabaseUrl, serviceRoleKey)
      await supabase.rpc('ops.record_edge_cost', {
        p_function_name: 'odoo-proxy',
        p_invocations: 1,
        p_execution_time_ms: Date.now() - startTime,
      }).catch((err: Error) => console.error('Failed to record cost:', err))
    }

    return response
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error'

    await logRequest(path, req.method, 500, Date.now() - startTime, undefined, errorMessage)

    return new Response(
      JSON.stringify({ ok: false, error: errorMessage }),
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
