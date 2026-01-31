/**
 * Vault secrets fetcher for repo-auditor Edge Function
 *
 * Uses service_role key to access Vault secrets via RPC.
 * Implements in-memory caching with TTL to reduce DB calls.
 */

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

const sb = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false },
})

type CacheEntry = { v: Record<string, string>; exp: number }
let cache: CacheEntry | null = null

/**
 * Fetch secrets from Vault with in-memory caching
 *
 * Falls back to direct environment variables if RPC doesn't exist
 */
export async function getVaultSecrets(
  names: string[],
  ttlMs = 5 * 60 * 1000
): Promise<Record<string, string>> {
  const now = Date.now()

  // Check cache first
  if (cache && cache.exp > now) {
    const out: Record<string, string> = {}
    for (const n of names) out[n] = cache.v[n]
    if (Object.values(out).every((x) => typeof x === 'string' && x.length > 0)) {
      return out
    }
  }

  // Try RPC first
  try {
    const { data, error } = await sb.rpc('get_vault_secrets', { p_names: names })
    if (!error && data) {
      cache = { v: data as Record<string, string>, exp: now + ttlMs }
      return cache.v
    }
  } catch {
    // RPC doesn't exist, fall through to env vars
  }

  // Fallback: read from environment variables directly
  const out: Record<string, string> = {}
  for (const name of names) {
    const val = Deno.env.get(name)
    if (val) out[name] = val
  }

  if (Object.keys(out).length > 0) {
    cache = { v: out, exp: now + ttlMs }
    return out
  }

  throw new Error(`Failed to fetch vault secrets: ${names.join(', ')}`)
}

/**
 * Get the service-role Supabase client
 */
export function supabaseServiceClient(): SupabaseClient {
  return sb
}

export default supabaseServiceClient
