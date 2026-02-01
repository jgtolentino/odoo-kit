/**
 * Slack Alert Edge Function
 *
 * Sends alerts to Slack based on ops events and advisor findings.
 * Can be triggered by:
 * - Database webhooks
 * - Cron jobs
 * - Direct HTTP calls
 *
 * Environment variables required:
 * - SLACK_WEBHOOK_URL: Slack Incoming Webhook URL
 * - SLACK_CHANNEL: (optional) Override channel
 * - SUPABASE_URL: Supabase project URL
 * - SUPABASE_SERVICE_ROLE_KEY: Service role key
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createServiceClient } from '../_shared/supabase-client.ts'

// Types
interface SlackMessage {
  channel?: string
  username?: string
  icon_emoji?: string
  text?: string
  blocks?: SlackBlock[]
  attachments?: SlackAttachment[]
}

interface SlackBlock {
  type: string
  text?: { type: string; text: string; emoji?: boolean }
  fields?: { type: string; text: string }[]
  elements?: unknown[]
  accessory?: unknown
}

interface SlackAttachment {
  color?: string
  blocks?: SlackBlock[]
  fallback?: string
}

interface AlertPayload {
  type: 'finding' | 'run_failed' | 'health_degraded' | 'custom'
  severity: 'critical' | 'high' | 'medium' | 'low' | 'info'
  title: string
  description?: string
  resource?: string
  link?: string
  metadata?: Record<string, unknown>
  // For database webhook triggers
  record?: Record<string, unknown>
  old_record?: Record<string, unknown>
}

// Severity to color mapping
const SEVERITY_COLORS: Record<string, string> = {
  critical: '#dc2626', // Red
  high: '#ea580c', // Orange
  medium: '#ca8a04', // Yellow
  low: '#2563eb', // Blue
  info: '#6b7280', // Gray
}

// Severity to emoji mapping
const SEVERITY_EMOJI: Record<string, string> = {
  critical: '🚨',
  high: '⚠️',
  medium: '📢',
  low: 'ℹ️',
  info: '💡',
}

/**
 * Format an alert as a Slack message
 */
function formatAlertMessage(alert: AlertPayload): SlackMessage {
  const emoji = SEVERITY_EMOJI[alert.severity] || '📌'
  const color = SEVERITY_COLORS[alert.severity] || '#6b7280'

  const blocks: SlackBlock[] = [
    {
      type: 'header',
      text: {
        type: 'plain_text',
        text: `${emoji} ${alert.title}`,
        emoji: true,
      },
    },
  ]

  if (alert.description) {
    blocks.push({
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: alert.description,
      },
    })
  }

  // Add metadata fields
  const fields: { type: string; text: string }[] = [
    { type: 'mrkdwn', text: `*Severity:*\n${alert.severity.toUpperCase()}` },
    { type: 'mrkdwn', text: `*Type:*\n${alert.type}` },
  ]

  if (alert.resource) {
    fields.push({ type: 'mrkdwn', text: `*Resource:*\n${alert.resource}` })
  }

  blocks.push({
    type: 'section',
    fields,
  })

  // Add additional metadata if present
  if (alert.metadata && Object.keys(alert.metadata).length > 0) {
    const metadataText = Object.entries(alert.metadata)
      .map(([key, value]) => `• *${key}:* ${JSON.stringify(value)}`)
      .join('\n')

    blocks.push({
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: `*Additional Details:*\n${metadataText}`,
      },
    })
  }

  // Add link button if present
  if (alert.link) {
    blocks.push({
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: ' ',
      },
      accessory: {
        type: 'button',
        text: {
          type: 'plain_text',
          text: 'View Details',
          emoji: true,
        },
        url: alert.link,
        action_id: 'view_details',
      },
    })
  }

  // Add timestamp
  blocks.push({
    type: 'context',
    elements: [
      {
        type: 'mrkdwn',
        text: `Sent at <!date^${Math.floor(Date.now() / 1000)}^{date_short_pretty} {time}|${new Date().toISOString()}>`,
      },
    ],
  })

  return {
    username: 'Supabase Advisor',
    icon_emoji: ':shield:',
    attachments: [
      {
        color,
        blocks,
      },
    ],
  }
}

/**
 * Send a message to Slack
 */
async function sendToSlack(message: SlackMessage): Promise<Response> {
  const webhookUrl = Deno.env.get('SLACK_WEBHOOK_URL')

  if (!webhookUrl) {
    throw new Error('SLACK_WEBHOOK_URL not configured')
  }

  const channel = Deno.env.get('SLACK_CHANNEL')
  if (channel) {
    message.channel = channel
  }

  const response = await fetch(webhookUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(message),
  })

  if (!response.ok) {
    const text = await response.text()
    throw new Error(`Slack API error: ${response.status} ${text}`)
  }

  return response
}

/**
 * Process a database webhook payload (for advisor.findings inserts)
 */
function processFindingWebhook(record: Record<string, unknown>): AlertPayload {
  return {
    type: 'finding',
    severity: (record.severity as string) || 'medium',
    title: (record.title as string) || 'New Advisor Finding',
    description: record.description as string,
    resource: record.resource_name as string || record.resource_id as string,
    metadata: {
      check_id: record.check_id,
      category: record.category,
      resource_type: record.resource_type,
    },
  }
}

/**
 * Process a database webhook payload (for ops.runs failures)
 */
function processRunFailureWebhook(record: Record<string, unknown>): AlertPayload {
  return {
    type: 'run_failed',
    severity: 'high',
    title: `Job Failed: ${record.job_name}`,
    description: record.error_message as string,
    resource: `${record.system}/${record.job_name}`,
    metadata: {
      run_id: record.id,
      system: record.system,
      attempt: record.attempt_number,
      started_at: record.started_at,
      ended_at: record.ended_at,
    },
  }
}

/**
 * Check for critical findings and send alerts
 */
async function checkAndAlertCriticalFindings(): Promise<number> {
  const supabase = createServiceClient()

  // Get critical/high findings from the last hour that haven't been alerted
  const { data: findings, error } = await supabase
    .from('advisor.findings')
    .select('*')
    .in('severity', ['critical', 'high'])
    .eq('status', 'open')
    .gt('first_seen_at', new Date(Date.now() - 60 * 60 * 1000).toISOString())
    .is('metadata->alerted_at', null)

  if (error) {
    console.error('Error fetching findings:', error)
    throw error
  }

  let alertCount = 0

  for (const finding of findings || []) {
    const alert = processFindingWebhook(finding)
    const message = formatAlertMessage(alert)

    try {
      await sendToSlack(message)
      alertCount++

      // Mark as alerted
      await supabase
        .from('advisor.findings')
        .update({
          metadata: {
            ...(finding.metadata || {}),
            alerted_at: new Date().toISOString(),
          },
        })
        .eq('id', finding.id)
    } catch (err) {
      console.error(`Failed to send alert for finding ${finding.id}:`, err)
    }
  }

  return alertCount
}

/**
 * Check for failed runs and send alerts
 */
async function checkAndAlertFailedRuns(): Promise<number> {
  const supabase = createServiceClient()

  // Get failed runs from the last hour that haven't been alerted
  const { data: runs, error } = await supabase
    .from('ops.runs')
    .select('*')
    .eq('status', 'failed')
    .gt('ended_at', new Date(Date.now() - 60 * 60 * 1000).toISOString())
    .is('metadata->alerted_at', null)

  if (error) {
    console.error('Error fetching failed runs:', error)
    throw error
  }

  let alertCount = 0

  for (const run of runs || []) {
    const alert = processRunFailureWebhook(run)
    const message = formatAlertMessage(alert)

    try {
      await sendToSlack(message)
      alertCount++

      // Mark as alerted
      await supabase
        .from('ops.runs')
        .update({
          metadata: {
            ...(run.metadata || {}),
            alerted_at: new Date().toISOString(),
          },
        })
        .eq('id', run.id)
    } catch (err) {
      console.error(`Failed to send alert for run ${run.id}:`, err)
    }
  }

  return alertCount
}

/**
 * Process a queue failure into an alert payload
 */
function processQueueFailurePayload(record: Record<string, unknown>): AlertPayload {
  const attempt = record.attempt as number || 1
  const maxAttempts = record.max_attempts as number || 3

  return {
    type: 'run_failed',
    severity: attempt >= maxAttempts ? 'high' : 'medium',
    title: `Queue Job Failed: ${record.job_name || record.job_type}`,
    description: record.error_message as string,
    resource: `queue/${record.job_type}`,
    metadata: {
      queue_id: record.id,
      job_type: record.job_type,
      attempt: attempt,
      max_attempts: maxAttempts,
      completed_at: record.completed_at,
    },
  }
}

/**
 * Check for failed queue jobs and send alerts
 */
async function checkAndAlertQueueFailures(): Promise<number> {
  const supabase = createServiceClient()

  // Get failed queue jobs from the last hour that haven't been alerted
  const { data: jobs, error } = await supabase
    .from('ops.queue')
    .select('*')
    .eq('status', 'failed')
    .gt('completed_at', new Date(Date.now() - 60 * 60 * 1000).toISOString())
    .is('metadata->alerted_at', null)

  if (error) {
    console.error('Error fetching failed queue jobs:', error)
    // Table might not exist yet, return 0
    return 0
  }

  let alertCount = 0

  for (const job of jobs || []) {
    const alert = processQueueFailurePayload(job)
    const message = formatAlertMessage(alert)

    try {
      await sendToSlack(message)
      alertCount++

      // Mark as alerted
      await supabase
        .from('ops.queue')
        .update({
          metadata: {
            ...(job.metadata || {}),
            alerted_at: new Date().toISOString(),
          },
        })
        .eq('id', job.id)
    } catch (err) {
      console.error(`Failed to send alert for queue job ${job.id}:`, err)
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
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      },
    })
  }

  try {
    const url = new URL(req.url)
    const action = url.searchParams.get('action') || 'send'

    // Record function invocation for cost tracking
    const supabase = createServiceClient()
    const startTime = Date.now()

    let result: Record<string, unknown> = {}

    switch (action) {
      case 'check_findings': {
        // Cron-triggered: check for new critical findings
        const alertCount = await checkAndAlertCriticalFindings()
        result = { action, alerts_sent: alertCount }
        break
      }

      case 'check_failures': {
        // Cron-triggered: check for failed runs
        const alertCount = await checkAndAlertFailedRuns()
        result = { action, alerts_sent: alertCount }
        break
      }

      case 'check_queue': {
        // Cron-triggered: check for failed queue jobs
        const alertCount = await checkAndAlertQueueFailures()
        result = { action, alerts_sent: alertCount }
        break
      }

      case 'check_all': {
        // Cron-triggered: check everything
        const findingAlerts = await checkAndAlertCriticalFindings()
        const failureAlerts = await checkAndAlertFailedRuns()
        const queueAlerts = await checkAndAlertQueueFailures()
        result = {
          action,
          finding_alerts: findingAlerts,
          failure_alerts: failureAlerts,
          queue_alerts: queueAlerts,
          total_alerts: findingAlerts + failureAlerts + queueAlerts,
        }
        break
      }

      case 'webhook': {
        // Database webhook trigger
        const payload = await req.json()
        const { type, record, old_record } = payload

        if (type === 'INSERT') {
          // Determine the table from the record structure
          let alert: AlertPayload

          if (record.check_id) {
            // This is an advisor.findings record
            alert = processFindingWebhook(record)
          } else if (record.job_name && record.status === 'failed') {
            // This is an ops.runs record
            alert = processRunFailureWebhook(record)
          } else {
            return new Response(JSON.stringify({ skipped: true, reason: 'Not an alertable event' }), {
              status: 200,
              headers: { 'Content-Type': 'application/json' },
            })
          }

          // Only alert on critical/high severity
          if (!['critical', 'high'].includes(alert.severity)) {
            return new Response(JSON.stringify({ skipped: true, reason: 'Below alerting threshold' }), {
              status: 200,
              headers: { 'Content-Type': 'application/json' },
            })
          }

          const message = formatAlertMessage(alert)
          await sendToSlack(message)
          result = { action: 'webhook', alert_sent: true, severity: alert.severity }
        }
        break
      }

      case 'send':
      default: {
        // Direct send: expects AlertPayload in body
        const alert: AlertPayload = await req.json()
        const message = formatAlertMessage(alert)
        await sendToSlack(message)
        result = { action: 'send', alert_sent: true }
        break
      }
    }

    // Record cost metrics
    const executionTime = Date.now() - startTime
    await supabase.rpc('ops.record_edge_cost', {
      p_function_name: 'slack-alert',
      p_invocations: 1,
      p_execution_time_ms: executionTime,
    }).catch((err: Error) => console.error('Failed to record cost:', err))

    return new Response(JSON.stringify({ success: true, ...result }), {
      status: 200,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      },
    })
  } catch (error) {
    console.error('Slack alert error:', error)

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
