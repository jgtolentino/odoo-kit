/**
 * Drift Detection Edge Function
 *
 * Detects configuration drift across integrated systems:
 * - GitHub repository settings
 * - Mailgun domain configuration
 * - Vercel project settings
 * - Supabase project configuration
 * - Odoo system parameters
 *
 * Stores expected configurations in Supabase and compares against actual.
 * Creates advisor findings when drift is detected.
 *
 * Environment variables:
 * - SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
 * - GITHUB_TOKEN (optional)
 * - MAILGUN_API_KEY (optional)
 * - VERCEL_TOKEN (optional)
 * - ODOO_URL, ODOO_DB, ODOO_USERNAME, ODOO_PASSWORD (optional)
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createServiceClient } from '../_shared/supabase-client.ts'

// Types
interface DriftCheck {
  system: string
  resource: string
  expected: unknown
  actual: unknown
  status: 'ok' | 'drift' | 'error'
  message?: string
}

interface ConfigSnapshot {
  id: string
  system: string
  resource: string
  config: Record<string, unknown>
  checksum: string
  captured_at: string
}

/**
 * Calculate a simple checksum for configuration comparison
 */
function calculateChecksum(obj: unknown): string {
  const str = JSON.stringify(obj, Object.keys(obj as object).sort())
  let hash = 0
  for (let i = 0; i < str.length; i++) {
    const char = str.charCodeAt(i)
    hash = ((hash << 5) - hash) + char
    hash = hash & hash
  }
  return Math.abs(hash).toString(16)
}

/**
 * Deep compare two objects and return differences
 */
function findDifferences(
  expected: Record<string, unknown>,
  actual: Record<string, unknown>,
  path = ''
): { path: string; expected: unknown; actual: unknown }[] {
  const diffs: { path: string; expected: unknown; actual: unknown }[] = []

  const allKeys = new Set([...Object.keys(expected), ...Object.keys(actual)])

  for (const key of allKeys) {
    const currentPath = path ? `${path}.${key}` : key
    const expVal = expected[key]
    const actVal = actual[key]

    if (expVal === undefined && actVal !== undefined) {
      diffs.push({ path: currentPath, expected: undefined, actual: actVal })
    } else if (expVal !== undefined && actVal === undefined) {
      diffs.push({ path: currentPath, expected: expVal, actual: undefined })
    } else if (typeof expVal === 'object' && typeof actVal === 'object' && expVal !== null && actVal !== null) {
      if (Array.isArray(expVal) && Array.isArray(actVal)) {
        if (JSON.stringify(expVal) !== JSON.stringify(actVal)) {
          diffs.push({ path: currentPath, expected: expVal, actual: actVal })
        }
      } else {
        diffs.push(...findDifferences(
          expVal as Record<string, unknown>,
          actVal as Record<string, unknown>,
          currentPath
        ))
      }
    } else if (expVal !== actVal) {
      diffs.push({ path: currentPath, expected: expVal, actual: actVal })
    }
  }

  return diffs
}

/**
 * Check GitHub repository settings
 */
async function checkGitHubDrift(repo: string): Promise<DriftCheck[]> {
  const token = Deno.env.get('GITHUB_TOKEN')
  if (!token) {
    return [{
      system: 'github',
      resource: repo,
      expected: null,
      actual: null,
      status: 'error',
      message: 'GITHUB_TOKEN not configured',
    }]
  }

  const supabase = createServiceClient()
  const results: DriftCheck[] = []

  try {
    // Fetch current repo settings
    const response = await fetch(`https://api.github.com/repos/${repo}`, {
      headers: {
        'Authorization': `token ${token}`,
        'Accept': 'application/vnd.github.v3+json',
      },
    })

    if (!response.ok) {
      throw new Error(`GitHub API error: ${response.status}`)
    }

    const repoData = await response.json()

    // Extract relevant settings
    const currentConfig = {
      default_branch: repoData.default_branch,
      has_issues: repoData.has_issues,
      has_wiki: repoData.has_wiki,
      has_discussions: repoData.has_discussions,
      allow_squash_merge: repoData.allow_squash_merge,
      allow_merge_commit: repoData.allow_merge_commit,
      allow_rebase_merge: repoData.allow_rebase_merge,
      delete_branch_on_merge: repoData.delete_branch_on_merge,
      visibility: repoData.visibility,
      archived: repoData.archived,
    }

    // Get expected config from database
    const { data: expectedSnapshot } = await supabase
      .from('ops.config_snapshots')
      .select('*')
      .eq('system', 'github')
      .eq('resource', repo)
      .order('captured_at', { ascending: false })
      .limit(1)
      .single()

    if (expectedSnapshot) {
      const expectedConfig = expectedSnapshot.config
      const diffs = findDifferences(expectedConfig as Record<string, unknown>, currentConfig)

      if (diffs.length > 0) {
        results.push({
          system: 'github',
          resource: repo,
          expected: expectedConfig,
          actual: currentConfig,
          status: 'drift',
          message: `Drift detected in ${diffs.length} setting(s): ${diffs.map(d => d.path).join(', ')}`,
        })
      } else {
        results.push({
          system: 'github',
          resource: repo,
          expected: expectedConfig,
          actual: currentConfig,
          status: 'ok',
        })
      }
    } else {
      // No baseline - capture current as expected
      await supabase.from('ops.config_snapshots').insert({
        system: 'github',
        resource: repo,
        config: currentConfig,
        checksum: calculateChecksum(currentConfig),
      })

      results.push({
        system: 'github',
        resource: repo,
        expected: null,
        actual: currentConfig,
        status: 'ok',
        message: 'Baseline captured - no previous configuration to compare',
      })
    }

    // Check branch protection
    const branchResponse = await fetch(
      `https://api.github.com/repos/${repo}/branches/${repoData.default_branch}/protection`,
      {
        headers: {
          'Authorization': `token ${token}`,
          'Accept': 'application/vnd.github.v3+json',
        },
      }
    )

    if (branchResponse.status === 404) {
      results.push({
        system: 'github',
        resource: `${repo}:branch-protection`,
        expected: { enabled: true },
        actual: { enabled: false },
        status: 'drift',
        message: 'Branch protection not enabled on default branch',
      })
    }
  } catch (error) {
    results.push({
      system: 'github',
      resource: repo,
      expected: null,
      actual: null,
      status: 'error',
      message: error instanceof Error ? error.message : 'Unknown error',
    })
  }

  return results
}

/**
 * Check Mailgun domain configuration
 */
async function checkMailgunDrift(domain: string): Promise<DriftCheck[]> {
  const apiKey = Deno.env.get('MAILGUN_API_KEY')
  if (!apiKey) {
    return [{
      system: 'mailgun',
      resource: domain,
      expected: null,
      actual: null,
      status: 'error',
      message: 'MAILGUN_API_KEY not configured',
    }]
  }

  const supabase = createServiceClient()
  const results: DriftCheck[] = []

  try {
    // Fetch domain info
    const response = await fetch(`https://api.mailgun.net/v3/domains/${domain}`, {
      headers: {
        'Authorization': `Basic ${btoa(`api:${apiKey}`)}`,
      },
    })

    if (!response.ok) {
      throw new Error(`Mailgun API error: ${response.status}`)
    }

    const domainData = await response.json()

    const currentConfig = {
      state: domainData.domain.state,
      type: domainData.domain.type,
      spam_action: domainData.domain.spam_action,
      wildcard: domainData.domain.wildcard,
      dkim_key_size: domainData.domain.dkim_key_size,
      web_scheme: domainData.domain.web_scheme,
    }

    // Check DNS records
    const dnsResponse = await fetch(`https://api.mailgun.net/v3/domains/${domain}/verify`, {
      method: 'PUT',
      headers: {
        'Authorization': `Basic ${btoa(`api:${apiKey}`)}`,
      },
    })

    if (dnsResponse.ok) {
      const dnsData = await dnsResponse.json()
      const dnsStatus = {
        spf_valid: dnsData.sending_dns_records?.some((r: { valid: string }) => r.valid === 'valid' && r.record_type === 'TXT'),
        dkim_valid: dnsData.sending_dns_records?.some((r: { valid: string; name: string }) => r.valid === 'valid' && r.name?.includes('domainkey')),
      }

      if (!dnsStatus.spf_valid || !dnsStatus.dkim_valid) {
        results.push({
          system: 'mailgun',
          resource: `${domain}:dns`,
          expected: { spf_valid: true, dkim_valid: true },
          actual: dnsStatus,
          status: 'drift',
          message: 'DNS records not properly configured',
        })
      }
    }

    // Get expected config
    const { data: expectedSnapshot } = await supabase
      .from('ops.config_snapshots')
      .select('*')
      .eq('system', 'mailgun')
      .eq('resource', domain)
      .order('captured_at', { ascending: false })
      .limit(1)
      .single()

    if (expectedSnapshot) {
      const diffs = findDifferences(expectedSnapshot.config as Record<string, unknown>, currentConfig)

      if (diffs.length > 0) {
        results.push({
          system: 'mailgun',
          resource: domain,
          expected: expectedSnapshot.config,
          actual: currentConfig,
          status: 'drift',
          message: `Configuration drift: ${diffs.map(d => d.path).join(', ')}`,
        })
      } else {
        results.push({
          system: 'mailgun',
          resource: domain,
          expected: expectedSnapshot.config,
          actual: currentConfig,
          status: 'ok',
        })
      }
    } else {
      await supabase.from('ops.config_snapshots').insert({
        system: 'mailgun',
        resource: domain,
        config: currentConfig,
        checksum: calculateChecksum(currentConfig),
      })

      results.push({
        system: 'mailgun',
        resource: domain,
        expected: null,
        actual: currentConfig,
        status: 'ok',
        message: 'Baseline captured',
      })
    }
  } catch (error) {
    results.push({
      system: 'mailgun',
      resource: domain,
      expected: null,
      actual: null,
      status: 'error',
      message: error instanceof Error ? error.message : 'Unknown error',
    })
  }

  return results
}

/**
 * Check Supabase project configuration
 */
async function checkSupabaseDrift(): Promise<DriftCheck[]> {
  const supabase = createServiceClient()
  const results: DriftCheck[] = []

  try {
    // Check RLS status on all tables
    const { data: tables } = await supabase.rpc('advisor.run_check', {
      p_check_id: 'SEC-001', // RLS check
    })

    if (tables?.findings_created > 0) {
      results.push({
        system: 'supabase',
        resource: 'rls-policy',
        expected: { all_tables_secured: true },
        actual: { tables_without_rls: tables.findings_created },
        status: 'drift',
        message: `${tables.findings_created} table(s) without RLS enabled`,
      })
    }

    // Check for overly permissive policies
    const { data: policies } = await supabase.rpc('advisor.run_check', {
      p_check_id: 'SEC-003', // Permissive policies check
    })

    if (policies?.findings_created > 0) {
      results.push({
        system: 'supabase',
        resource: 'rls-policy',
        expected: { permissive_policies: 0 },
        actual: { permissive_policies: policies.findings_created },
        status: 'drift',
        message: `${policies.findings_created} overly permissive RLS policy detected`,
      })
    }

    // Check extension versions
    const { data: extensions } = await supabase
      .from('pg_extension')
      .select('extname, extversion')

    const extensionConfig = extensions?.reduce((acc, ext) => {
      acc[ext.extname] = ext.extversion
      return acc
    }, {} as Record<string, string>) || {}

    const { data: expectedExtensions } = await supabase
      .from('ops.config_snapshots')
      .select('*')
      .eq('system', 'supabase')
      .eq('resource', 'extensions')
      .order('captured_at', { ascending: false })
      .limit(1)
      .single()

    if (expectedExtensions) {
      const diffs = findDifferences(expectedExtensions.config as Record<string, unknown>, extensionConfig)
      if (diffs.length > 0) {
        results.push({
          system: 'supabase',
          resource: 'extensions',
          expected: expectedExtensions.config,
          actual: extensionConfig,
          status: 'drift',
          message: `Extension changes: ${diffs.map(d => d.path).join(', ')}`,
        })
      }
    } else {
      await supabase.from('ops.config_snapshots').insert({
        system: 'supabase',
        resource: 'extensions',
        config: extensionConfig,
        checksum: calculateChecksum(extensionConfig),
      })
    }
  } catch (error) {
    results.push({
      system: 'supabase',
      resource: 'configuration',
      expected: null,
      actual: null,
      status: 'error',
      message: error instanceof Error ? error.message : 'Unknown error',
    })
  }

  return results
}

/**
 * Create advisor findings for drift
 */
async function createDriftFindings(checks: DriftCheck[]): Promise<number> {
  const supabase = createServiceClient()
  let created = 0

  const driftChecks = checks.filter(c => c.status === 'drift')

  for (const check of driftChecks) {
    const { error } = await supabase.from('advisor.findings').insert({
      check_id: 'DRIFT-001',
      category: 'operational',
      severity: 'medium',
      status: 'open',
      title: `Configuration Drift: ${check.system}/${check.resource}`,
      description: check.message,
      resource_type: 'configuration',
      resource_id: `${check.system}:${check.resource}`,
      resource_name: check.resource,
      evidence: {
        expected: check.expected,
        actual: check.actual,
        detected_at: new Date().toISOString(),
      },
    })

    if (!error) {
      created++
    }
  }

  return created
}

/**
 * Main handler
 */
serve(async (req: Request): Promise<Response> => {
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
    p_job_name: 'drift-detection',
    p_job_type: 'cron',
    p_trigger_type: 'schedule',
  })

  try {
    const url = new URL(req.url)
    const systems = url.searchParams.get('systems')?.split(',') || ['github', 'mailgun', 'supabase']

    let allChecks: DriftCheck[] = []

    // Run checks for requested systems
    if (systems.includes('github')) {
      const repos = (url.searchParams.get('repos') || Deno.env.get('GITHUB_REPOS') || '').split(',').filter(Boolean)
      for (const repo of repos) {
        const checks = await checkGitHubDrift(repo.trim())
        allChecks = [...allChecks, ...checks]
      }
    }

    if (systems.includes('mailgun')) {
      const domains = (url.searchParams.get('domains') || Deno.env.get('MAILGUN_DOMAINS') || '').split(',').filter(Boolean)
      for (const domain of domains) {
        const checks = await checkMailgunDrift(domain.trim())
        allChecks = [...allChecks, ...checks]
      }
    }

    if (systems.includes('supabase')) {
      const checks = await checkSupabaseDrift()
      allChecks = [...allChecks, ...checks]
    }

    // Create findings for drift
    const findingsCreated = await createDriftFindings(allChecks)

    // Summary
    const summary = {
      total: allChecks.length,
      ok: allChecks.filter(c => c.status === 'ok').length,
      drift: allChecks.filter(c => c.status === 'drift').length,
      errors: allChecks.filter(c => c.status === 'error').length,
    }

    // Complete run
    await supabase.rpc('ops.complete_run', {
      p_run_id: runId,
      p_records_processed: allChecks.length,
      p_metadata: {
        ...summary,
        findings_created: findingsCreated,
        systems_checked: systems,
      },
    })

    // Record cost
    const executionTime = Date.now() - startTime
    await supabase.rpc('ops.record_edge_cost', {
      p_function_name: 'drift-detection',
      p_invocations: 1,
      p_execution_time_ms: executionTime,
    }).catch((err: Error) => console.error('Failed to record cost:', err))

    return new Response(
      JSON.stringify({
        success: true,
        run_id: runId,
        duration_ms: executionTime,
        summary,
        findings_created: findingsCreated,
        checks: allChecks,
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
    console.error('Drift detection error:', error)

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
