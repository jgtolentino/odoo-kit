/**
 * Repo Auditor Edge Function
 *
 * Crawls GitHub repositories via GitHub App installation, runs security/hardening
 * checks, and creates issues for high/critical findings.
 *
 * Triggered by:
 * - Cron (scheduled daily via pg_cron)
 * - Manual invocation via HTTP POST
 *
 * Required secrets (via Vault or env):
 * - GITHUB_APP_ID: GitHub App ID
 * - GITHUB_APP_PRIVATE_KEY_B64: Base64-encoded GitHub App private key
 * - ADMIN_API_KEY (optional): Admin key for endpoint protection
 */

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts'
import { getVaultSecrets, supabaseServiceClient } from './vault.ts'
import {
  mintAppJwt,
  listInstallationRepos,
  mintInstallationToken,
  getFileContent,
  directoryExists,
  createIssue,
  findExistingIssue,
  addIssueComment,
} from './github.ts'
import {
  runRules,
  getRequiredFilePaths,
  getRequiredDirectoryPaths,
  type Finding,
  type RepoFiles,
} from './rules.ts'

// ============================================================================
// Helpers
// ============================================================================

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

const SB = supabaseServiceClient()

// ============================================================================
// Database Operations
// ============================================================================

async function startRun(): Promise<number> {
  const { data, error } = await SB.rpc('start_repo_audit_run', {
    p_metadata: { triggered_by: 'edge_function' },
  })

  if (error) {
    throw new Error(`Failed to start audit run: ${error.message}`)
  }

  return data as number
}

async function completeRun(
  runId: number,
  status: 'ok' | 'error',
  notes: string,
  reposScanned: number,
  findingsCount: number,
  issuesCreated: number
): Promise<void> {
  const { error } = await SB.rpc('complete_repo_audit_run', {
    p_run_id: runId,
    p_status: status,
    p_notes: notes,
    p_repos_scanned: reposScanned,
    p_findings_count: findingsCount,
    p_issues_created: issuesCreated,
  })

  if (error) {
    console.error(`Failed to complete audit run: ${error.message}`)
  }
}

async function upsertFinding(
  repo: string,
  finding: Finding,
  issueNumber?: number,
  issueUrl?: string
): Promise<number> {
  // First, upsert the core finding
  const { data: findingId, error } = await SB.rpc('upsert_repo_audit_finding', {
    p_repo_full_name: repo,
    p_rule_id: finding.rule_id,
    p_severity: finding.severity,
    p_title: finding.title,
    p_details: finding.details,
    p_fingerprint: finding.fingerprint,
  })

  if (error) {
    throw new Error(`Failed to upsert finding: ${error.message}`)
  }

  // If we have issue info, update it separately
  if (issueNumber && issueUrl) {
    await SB.from('repo_audit_findings')
      .update({
        github_issue_number: issueNumber,
        github_issue_url: issueUrl,
      })
      .eq('finding_id', findingId)
  }

  return findingId as number
}

// ============================================================================
// Issue Generation
// ============================================================================

function generateIssueBody(finding: Finding): string {
  return `## Automated Hardening Finding

**Rule:** \`${finding.rule_id}\`
**Severity:** ${finding.severity.toUpperCase()}

### Details

\`\`\`json
${JSON.stringify(finding.details, null, 2)}
\`\`\`

### Suggested Action

${finding.details.hint ?? 'Review and implement the recommended mitigation.'}

${finding.details.docs ? `**Documentation:** ${finding.details.docs}` : ''}

---

*This issue was automatically created by the repo-auditor Edge Function.*
*Last detected: ${new Date().toISOString()}*
`
}

// ============================================================================
// Main Audit Logic
// ============================================================================

async function auditRepo(
  instToken: string,
  repo: string,
  defaultBranch: string
): Promise<{ findings: Finding[]; issuesCreated: number }> {
  // Fetch all required files
  const files: RepoFiles = {}
  const filePaths = getRequiredFilePaths()
  const dirPaths = getRequiredDirectoryPaths()

  // Fetch files in parallel
  const filePromises = filePaths.map(async (path) => {
    try {
      files[path] = await getFileContent(instToken, repo, path, defaultBranch)
    } catch {
      files[path] = null
    }
  })

  // Check directories in parallel
  const dirPromises = dirPaths.map(async (path) => {
    try {
      const exists = await directoryExists(instToken, repo, path, defaultBranch)
      files[`${path}/.exists`] = exists ? '1' : '0'
    } catch {
      files[`${path}/.exists`] = '0'
    }
  })

  await Promise.all([...filePromises, ...dirPromises])

  // Run rules
  const findings = runRules(repo, files)
  let issuesCreated = 0

  // Create issues for high/critical findings
  for (const finding of findings) {
    try {
      // Only auto-create issues for high/critical severity
      if (finding.severity !== 'high' && finding.severity !== 'critical') {
        await upsertFinding(repo, finding)
        continue
      }

      const issueTitle = `[hardening] ${finding.title}`

      // Check if issue already exists
      const existingIssue = await findExistingIssue(instToken, repo, finding.title)

      if (existingIssue) {
        // Update existing issue with comment about latest detection
        await addIssueComment(
          instToken,
          repo,
          existingIssue.number,
          `This finding was detected again on ${new Date().toISOString()}.`
        )
        await upsertFinding(
          repo,
          finding,
          existingIssue.number,
          existingIssue.html_url
        )
      } else {
        // Create new issue
        const issue = await createIssue(
          instToken,
          repo,
          issueTitle,
          generateIssueBody(finding),
          ['hardening', 'automated', finding.severity]
        )
        await upsertFinding(repo, finding, issue.number, issue.html_url)
        issuesCreated++
      }
    } catch (e) {
      console.error(`Failed to process finding ${finding.rule_id} for ${repo}: ${e}`)
      // Still record the finding even if issue creation failed
      await upsertFinding(repo, finding)
    }
  }

  return { findings, issuesCreated }
}

// ============================================================================
// HTTP Handler
// ============================================================================

serve(async (req: Request): Promise<Response> => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, x-admin-key, Authorization',
      },
    })
  }

  try {
    // Admin key authentication (optional but recommended)
    const adminKey = Deno.env.get('ADMIN_API_KEY')
    if (adminKey) {
      const gotKey = req.headers.get('x-admin-key')
      if (gotKey !== adminKey) {
        return json({ ok: false, error: 'Forbidden' }, 403)
      }
    }

    // Start audit run
    let runId: number
    try {
      runId = await startRun()
    } catch (e) {
      console.error('Failed to start run:', e)
      return json({ ok: false, error: 'Failed to start audit run' }, 500)
    }

    // Get GitHub App credentials
    let appId: number
    let privateKeyPem: string

    try {
      const secrets = await getVaultSecrets([
        'GITHUB_APP_ID',
        'GITHUB_APP_PRIVATE_KEY_B64',
      ])
      appId = Number(secrets['GITHUB_APP_ID'])
      privateKeyPem = atob(secrets['GITHUB_APP_PRIVATE_KEY_B64'])
    } catch (e) {
      await completeRun(runId, 'error', `Failed to get secrets: ${e}`, 0, 0, 0)
      return json({ ok: false, error: 'Failed to get GitHub App credentials' }, 500)
    }

    // Generate App JWT
    const appJwt = await mintAppJwt(appId, privateKeyPem)

    // List all installations and repos
    const installations = await listInstallationRepos(appJwt)

    let totalRepos = 0
    let totalFindings = 0
    let totalIssues = 0
    const results: Array<{
      repo: string
      findings: number
      issues_created: number
    }> = []

    // Audit each repo
    for (const inst of installations) {
      const instToken = await mintInstallationToken(appJwt, inst.installation_id)

      for (const repo of inst.repos) {
        try {
          const { findings, issuesCreated } = await auditRepo(
            instToken,
            repo.full_name,
            repo.default_branch
          )

          totalRepos++
          totalFindings += findings.length
          totalIssues += issuesCreated

          if (findings.length > 0) {
            results.push({
              repo: repo.full_name,
              findings: findings.length,
              issues_created: issuesCreated,
            })
          }
        } catch (e) {
          console.error(`Failed to audit ${repo.full_name}: ${e}`)
        }
      }
    }

    // Complete the run
    await completeRun(
      runId,
      'ok',
      `Scanned ${totalRepos} repos, found ${totalFindings} findings, created ${totalIssues} issues`,
      totalRepos,
      totalFindings,
      totalIssues
    )

    return json({
      ok: true,
      run_id: runId,
      repos_scanned: totalRepos,
      findings: totalFindings,
      issues_created: totalIssues,
      results,
    })
  } catch (e) {
    console.error('Audit failed:', e)

    // Try to record error
    try {
      const { data: runId } = await SB.rpc('start_repo_audit_run', {
        p_metadata: { error: String(e) },
      })
      if (runId) {
        await completeRun(runId as number, 'error', String(e), 0, 0, 0)
      }
    } catch {
      // Best effort
    }

    return json({ ok: false, error: String(e) }, 500)
  }
})
