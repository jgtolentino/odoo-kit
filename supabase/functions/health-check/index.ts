/**
 * Health Check Control Loop Edge Function
 *
 * Runs automated health checks and advisor checks, then triggers alerts.
 * This is the core control loop for the observability system.
 *
 * Control Loop Pattern:
 * Cron → check systems
 *      → write ops_event
 *      → if severity >= HIGH
 *          → Slack alert
 *          → GitHub issue (optional)
 *
 * Environment variables required:
 * - SUPABASE_URL: Supabase project URL
 * - SUPABASE_SERVICE_ROLE_KEY: Service role key
 * - SLACK_WEBHOOK_URL: (optional) For alerts
 * - GITHUB_TOKEN: (optional) For creating issues
 * - GITHUB_REPO: (optional) e.g., "owner/repo"
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createServiceClient } from '../_shared/supabase-client.ts'

// Types
interface HealthCheckResult {
  system: string
  component?: string
  signal: string
  value: number
  unit?: string
  status: 'healthy' | 'degraded' | 'unhealthy'
  message?: string
}

interface SystemCheck {
  name: string
  check: () => Promise<HealthCheckResult[]>
}

/**
 * Check Supabase database health
 */
async function checkDatabaseHealth(): Promise<HealthCheckResult[]> {
  const supabase = createServiceClient()
  const results: HealthCheckResult[] = []

  // Check database connectivity
  const startTime = Date.now()
  const { error } = await supabase.from('ops.runs').select('id').limit(1)
  const latency = Date.now() - startTime

  results.push({
    system: 'supabase',
    component: 'database',
    signal: 'latency_p50',
    value: latency,
    unit: 'ms',
    status: latency < 100 ? 'healthy' : latency < 500 ? 'degraded' : 'unhealthy',
    message: latency > 500 ? 'High database latency detected' : undefined,
  })

  if (error) {
    results.push({
      system: 'supabase',
      component: 'database',
      signal: 'error_rate',
      value: 1,
      unit: 'boolean',
      status: 'unhealthy',
      message: `Database error: ${error.message}`,
    })
  }

  // Check for long-running queries
  const { data: longQueries } = await supabase.rpc('advisor.run_check', {
    p_check_id: 'REL-003', // Long-running queries check
  })

  if (longQueries?.findings_created > 0) {
    results.push({
      system: 'supabase',
      component: 'database',
      signal: 'custom',
      value: longQueries.findings_created,
      unit: 'count',
      status: 'degraded',
      message: `${longQueries.findings_created} long-running queries detected`,
    })
  }

  return results
}

/**
 * Check ops system health (job success rates)
 */
async function checkOpsHealth(): Promise<HealthCheckResult[]> {
  const supabase = createServiceClient()
  const results: HealthCheckResult[] = []

  // Get job stats from the last hour
  const { data: stats } = await supabase
    .from('ops.v_job_stats')
    .select('*')

  if (stats && stats.length > 0) {
    const totalRuns = stats.reduce((sum, s) => sum + (s.total_runs || 0), 0)
    const successfulRuns = stats.reduce((sum, s) => sum + (s.successful_runs || 0), 0)
    const failedRuns = stats.reduce((sum, s) => sum + (s.failed_runs || 0), 0)

    const successRate = totalRuns > 0 ? (successfulRuns / totalRuns) * 100 : 100

    results.push({
      system: 'supabase',
      component: 'ops',
      signal: 'success_rate',
      value: successRate,
      unit: 'percent',
      status: successRate >= 95 ? 'healthy' : successRate >= 80 ? 'degraded' : 'unhealthy',
      message: successRate < 80 ? `Low job success rate: ${successRate.toFixed(1)}%` : undefined,
    })

    // Check for stuck jobs
    const { data: activeRuns } = await supabase
      .from('ops.v_active_runs')
      .select('*')

    const stuckJobs = (activeRuns || []).filter(
      (r) => r.running_duration && r.running_duration > '01:00:00'
    )

    if (stuckJobs.length > 0) {
      results.push({
        system: 'supabase',
        component: 'ops',
        signal: 'queue_depth',
        value: stuckJobs.length,
        unit: 'count',
        status: 'degraded',
        message: `${stuckJobs.length} potentially stuck jobs detected`,
      })
    }
  }

  return results
}

/**
 * Check mirror sync health
 */
async function checkMirrorHealth(): Promise<HealthCheckResult[]> {
  const supabase = createServiceClient()
  const results: HealthCheckResult[] = []

  const { data: syncStatus } = await supabase.rpc('mirror.get_sync_status')

  if (syncStatus) {
    for (const table of syncStatus) {
      const isFailed = table.last_status === 'failed'
      const isStale = table.last_sync_at &&
        new Date(table.last_sync_at) < new Date(Date.now() - 60 * 60 * 1000)

      if (isFailed || isStale) {
        results.push({
          system: 'odoo',
          component: `mirror.${table.table_name}`,
          signal: 'custom',
          value: isFailed ? 0 : 1,
          unit: 'status',
          status: isFailed ? 'unhealthy' : 'degraded',
          message: isFailed
            ? `Sync failed for ${table.table_name}`
            : `Stale data in ${table.table_name} (last sync: ${table.last_sync_at})`,
        })
      }
    }
  }

  return results
}

/**
 * Check external service connectivity
 */
async function checkExternalServices(): Promise<HealthCheckResult[]> {
  const results: HealthCheckResult[] = []

  // Check Odoo connectivity (if configured)
  const odooUrl = Deno.env.get('ODOO_URL')
  if (odooUrl) {
    try {
      const startTime = Date.now()
      const response = await fetch(`${odooUrl}/web/webclient/version_info`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({}),
        signal: AbortSignal.timeout(10000),
      })
      const latency = Date.now() - startTime

      results.push({
        system: 'odoo',
        component: 'api',
        signal: 'latency_p50',
        value: latency,
        unit: 'ms',
        status: response.ok
          ? latency < 500 ? 'healthy' : 'degraded'
          : 'unhealthy',
        message: !response.ok ? `Odoo returned ${response.status}` : undefined,
      })
    } catch (error) {
      results.push({
        system: 'odoo',
        component: 'api',
        signal: 'uptime',
        value: 0,
        unit: 'boolean',
        status: 'unhealthy',
        message: `Odoo unreachable: ${error instanceof Error ? error.message : 'Unknown error'}`,
      })
    }
  }

  // Check Slack connectivity (if configured)
  const slackWebhook = Deno.env.get('SLACK_WEBHOOK_URL')
  if (slackWebhook) {
    try {
      // Just check that the URL is valid, don't actually send
      const url = new URL(slackWebhook)
      results.push({
        system: 'slack',
        signal: 'uptime',
        value: 1,
        unit: 'boolean',
        status: 'healthy',
      })
    } catch {
      results.push({
        system: 'slack',
        signal: 'uptime',
        value: 0,
        unit: 'boolean',
        status: 'unhealthy',
        message: 'Invalid Slack webhook URL configured',
      })
    }
  }

  return results
}

/**
 * Run all advisor checks
 */
async function runAdvisorChecks(): Promise<{ total: number; created: number; resolved: number }> {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('advisor.run_all_checks')

  if (error) {
    console.error('Error running advisor checks:', error)
    throw error
  }

  const results = data || []
  const total = results.length
  const created = results.reduce((sum: number, r: { findings_created?: number }) => sum + (r.findings_created || 0), 0)
  const resolved = results.reduce((sum: number, r: { findings_resolved?: number }) => sum + (r.findings_resolved || 0), 0)

  return { total, created, resolved }
}

/**
 * Record health check results
 */
async function recordHealthResults(results: HealthCheckResult[]): Promise<void> {
  const supabase = createServiceClient()

  for (const result of results) {
    await supabase.rpc('ops.record_health', {
      p_system: result.system,
      p_signal: result.signal,
      p_value: result.value,
      p_component: result.component,
      p_unit: result.unit,
      p_metadata: { status: result.status, message: result.message },
    })
  }
}

/**
 * Create GitHub issue for critical findings
 */
async function createGitHubIssue(
  title: string,
  body: string,
  labels: string[] = ['alert', 'automated']
): Promise<void> {
  const token = Deno.env.get('GITHUB_TOKEN')
  const repo = Deno.env.get('GITHUB_REPO')

  if (!token || !repo) {
    console.log('GitHub not configured, skipping issue creation')
    return
  }

  const response = await fetch(`https://api.github.com/repos/${repo}/issues`, {
    method: 'POST',
    headers: {
      'Authorization': `token ${token}`,
      'Accept': 'application/vnd.github.v3+json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ title, body, labels }),
  })

  if (!response.ok) {
    const text = await response.text()
    console.error(`Failed to create GitHub issue: ${response.status} ${text}`)
  }
}

/**
 * Trigger Slack alert for unhealthy results
 */
async function triggerSlackAlerts(results: HealthCheckResult[]): Promise<number> {
  const unhealthyResults = results.filter((r) => r.status === 'unhealthy')

  if (unhealthyResults.length === 0) {
    return 0
  }

  const slackUrl = Deno.env.get('SLACK_WEBHOOK_URL')
  if (!slackUrl) {
    console.log('Slack not configured, skipping alerts')
    return 0
  }

  // Group by system
  const bySystem = unhealthyResults.reduce((acc, r) => {
    const key = r.system
    if (!acc[key]) acc[key] = []
    acc[key].push(r)
    return acc
  }, {} as Record<string, HealthCheckResult[]>)

  let alertCount = 0

  for (const [system, systemResults] of Object.entries(bySystem)) {
    const issues = systemResults
      .map((r) => `• ${r.component || 'general'}: ${r.message || `${r.signal} = ${r.value}`}`)
      .join('\n')

    const message = {
      username: 'Health Monitor',
      icon_emoji: ':warning:',
      attachments: [
        {
          color: '#dc2626',
          blocks: [
            {
              type: 'header',
              text: {
                type: 'plain_text',
                text: `🚨 System Unhealthy: ${system}`,
                emoji: true,
              },
            },
            {
              type: 'section',
              text: {
                type: 'mrkdwn',
                text: `*Issues detected:*\n${issues}`,
              },
            },
            {
              type: 'context',
              elements: [
                {
                  type: 'mrkdwn',
                  text: `Detected at ${new Date().toISOString()}`,
                },
              ],
            },
          ],
        },
      ],
    }

    const response = await fetch(slackUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(message),
    })

    if (response.ok) {
      alertCount++
    }
  }

  return alertCount
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
    p_job_name: 'health-check',
    p_job_type: 'cron',
    p_trigger_type: 'schedule',
  })

  try {
    const url = new URL(req.url)
    const action = url.searchParams.get('action') || 'full'

    let healthResults: HealthCheckResult[] = []
    let advisorResults = { total: 0, created: 0, resolved: 0 }

    // Run checks based on action
    switch (action) {
      case 'database':
        healthResults = await checkDatabaseHealth()
        break

      case 'ops':
        healthResults = await checkOpsHealth()
        break

      case 'mirror':
        healthResults = await checkMirrorHealth()
        break

      case 'external':
        healthResults = await checkExternalServices()
        break

      case 'advisor':
        advisorResults = await runAdvisorChecks()
        break

      case 'full':
      default: {
        // Run all health checks in parallel
        const [dbHealth, opsHealth, mirrorHealth, externalHealth] = await Promise.all([
          checkDatabaseHealth(),
          checkOpsHealth(),
          checkMirrorHealth(),
          checkExternalServices(),
        ])

        healthResults = [...dbHealth, ...opsHealth, ...mirrorHealth, ...externalHealth]
        advisorResults = await runAdvisorChecks()
        break
      }
    }

    // Record health results
    await recordHealthResults(healthResults)

    // Count status
    const healthyCount = healthResults.filter((r) => r.status === 'healthy').length
    const degradedCount = healthResults.filter((r) => r.status === 'degraded').length
    const unhealthyCount = healthResults.filter((r) => r.status === 'unhealthy').length

    // Trigger alerts for unhealthy results
    const alertsSent = await triggerSlackAlerts(healthResults)

    // Create GitHub issue for critical findings
    if (advisorResults.created > 0) {
      const { data: criticalFindings } = await supabase
        .from('advisor.v_open_findings')
        .select('*')
        .eq('severity', 'critical')
        .limit(10)

      if (criticalFindings && criticalFindings.length > 0) {
        const issueBody = criticalFindings
          .map((f) => `### ${f.title}\n- Resource: ${f.resource_name || f.resource_id}\n- Category: ${f.category}`)
          .join('\n\n')

        await createGitHubIssue(
          `[Advisor] ${criticalFindings.length} Critical Finding(s) Detected`,
          `## Critical Advisor Findings\n\n${issueBody}\n\n---\n*Automated issue from health-check control loop*`
        )
      }
    }

    // Complete the run
    await supabase.rpc('ops.complete_run', {
      p_run_id: runId,
      p_records_processed: healthResults.length + advisorResults.total,
      p_metadata: {
        healthy: healthyCount,
        degraded: degradedCount,
        unhealthy: unhealthyCount,
        advisor_findings_created: advisorResults.created,
        advisor_findings_resolved: advisorResults.resolved,
        alerts_sent: alertsSent,
      },
    })

    // Record cost metrics
    const executionTime = Date.now() - startTime
    await supabase.rpc('ops.record_edge_cost', {
      p_function_name: 'health-check',
      p_invocations: 1,
      p_execution_time_ms: executionTime,
    }).catch((err: Error) => console.error('Failed to record cost:', err))

    return new Response(
      JSON.stringify({
        success: true,
        run_id: runId,
        duration_ms: executionTime,
        health: {
          total: healthResults.length,
          healthy: healthyCount,
          degraded: degradedCount,
          unhealthy: unhealthyCount,
        },
        advisor: advisorResults,
        alerts_sent: alertsSent,
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
    console.error('Health check error:', error)

    // Fail the run
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
