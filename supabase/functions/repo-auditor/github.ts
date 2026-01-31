/**
 * GitHub App API helpers for repo-auditor Edge Function
 *
 * Handles JWT generation, installation token minting, and GitHub API calls.
 * Uses RS256 (RSASSA-PKCS1-v1_5 with SHA-256) for GitHub App authentication.
 */

// ============================================================================
// JWT / Crypto Utilities
// ============================================================================

function b64url(bytes: Uint8Array): string {
  const b64 = btoa(String.fromCharCode(...bytes))
  return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

function b64urlText(s: string): string {
  return b64url(new TextEncoder().encode(s))
}

function pemToDer(pem: string): Uint8Array {
  const clean = pem
    .replace(/-----BEGIN [A-Z ]+-----/g, '')
    .replace(/-----END [A-Z ]+-----/g, '')
    .replace(/\s+/g, '')
  const bin = atob(clean)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

async function importPkcs8(pem: string): Promise<CryptoKey> {
  const der = pemToDer(pem)
  return await crypto.subtle.importKey(
    'pkcs8',
    der.buffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign']
  )
}

// ============================================================================
// GitHub App JWT Generation
// ============================================================================

/**
 * Mint a GitHub App JWT for API authentication
 *
 * JWT is valid for 10 minutes (GitHub's maximum)
 * We use iat - 30s to account for clock drift
 */
export async function mintAppJwt(
  appId: number,
  privateKeyPem: string
): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const header = { alg: 'RS256', typ: 'JWT' }
  const payload = {
    iat: now - 30, // 30s clock drift buffer
    exp: now + 9 * 60, // 9 minutes (GitHub max is 10)
    iss: appId,
  }

  const unsigned = `${b64urlText(JSON.stringify(header))}.${b64urlText(JSON.stringify(payload))}`
  const key = await importPkcs8(privateKeyPem)
  const sig = await crypto.subtle.sign(
    { name: 'RSASSA-PKCS1-v1_5' },
    key,
    new TextEncoder().encode(unsigned)
  )

  return `${unsigned}.${b64url(new Uint8Array(sig))}`
}

// ============================================================================
// GitHub API Helpers
// ============================================================================

/**
 * Make an authenticated GitHub API request
 */
export async function gh(
  url: string,
  token: string,
  init?: RequestInit
): Promise<unknown> {
  const headers = new Headers(init?.headers ?? {})
  headers.set('Accept', 'application/vnd.github+json')
  headers.set('User-Agent', 'repo-auditor-edge')
  headers.set('Authorization', `Bearer ${token}`)
  headers.set('X-GitHub-Api-Version', '2022-11-28')

  const r = await fetch(url, { ...init, headers })
  const t = await r.text()

  if (!r.ok) {
    throw new Error(`GitHub API ${r.status}: ${t}`)
  }

  return t ? JSON.parse(t) : null
}

/**
 * Mint an installation access token from a GitHub App JWT
 */
export async function mintInstallationToken(
  appJwt: string,
  installationId: number
): Promise<string> {
  const tok = (await gh(
    `https://api.github.com/app/installations/${installationId}/access_tokens`,
    appJwt,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    }
  )) as { token: string }
  return tok.token
}

// ============================================================================
// Repository Discovery
// ============================================================================

export interface Installation {
  installation_id: number
  account: string
  repos: Array<{ full_name: string; default_branch: string }>
}

/**
 * List all installations and their repositories
 */
export async function listInstallationRepos(
  appJwt: string
): Promise<Installation[]> {
  const installs = (await gh(
    'https://api.github.com/app/installations',
    appJwt
  )) as Array<{ id: number; account?: { login?: string } }>

  const out: Installation[] = []

  for (const inst of installs) {
    const installation_id = inst.id
    const account = inst.account?.login ?? 'unknown'

    // Get installation token for this specific installation
    const instToken = await mintInstallationToken(appJwt, installation_id)

    // List repos visible to this installation
    const reposResp = (await gh(
      'https://api.github.com/installation/repositories?per_page=100',
      instToken
    )) as { repositories: Array<{ full_name: string; default_branch: string }> }

    const repos = (reposResp.repositories ?? []).map(
      (r: { full_name: string; default_branch: string }) => ({
        full_name: r.full_name,
        default_branch: r.default_branch,
      })
    )

    out.push({ installation_id, account, repos })
  }

  return out
}

// ============================================================================
// File Content Fetching
// ============================================================================

/**
 * Get file content from a repository
 *
 * Returns null if file doesn't exist (404)
 */
export async function getFileContent(
  installationToken: string,
  repo: string,
  path: string,
  ref?: string
): Promise<string | null> {
  const u = new URL(`https://api.github.com/repos/${repo}/contents/${path}`)
  if (ref) u.searchParams.set('ref', ref)

  try {
    const j = (await gh(u.toString(), installationToken)) as {
      content?: string
      type?: string
    }

    // Handle case where path is a directory
    if (j.type === 'dir' || Array.isArray(j)) {
      return null
    }

    if (!j?.content) return null

    // GitHub returns base64-encoded content
    const decoded = atob((j.content as string).replace(/\n/g, ''))
    return decoded
  } catch (e) {
    // 404 or other error - file doesn't exist
    if (String(e).includes('404')) return null
    throw e
  }
}

/**
 * Check if a directory exists in a repository
 */
export async function directoryExists(
  installationToken: string,
  repo: string,
  path: string,
  ref?: string
): Promise<boolean> {
  const u = new URL(`https://api.github.com/repos/${repo}/contents/${path}`)
  if (ref) u.searchParams.set('ref', ref)

  try {
    const j = await gh(u.toString(), installationToken)
    return Array.isArray(j) // Directories return an array
  } catch {
    return false
  }
}

// ============================================================================
// Issue Management
// ============================================================================

export interface GitHubIssue {
  number: number
  html_url: string
  title: string
}

/**
 * Create a GitHub issue
 */
export async function createIssue(
  installationToken: string,
  repo: string,
  title: string,
  body: string,
  labels: string[] = []
): Promise<GitHubIssue> {
  return (await gh(`https://api.github.com/repos/${repo}/issues`, installationToken, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title, body, labels }),
  })) as GitHubIssue
}

/**
 * Search for existing issues by title pattern
 */
export async function findExistingIssue(
  installationToken: string,
  repo: string,
  titlePattern: string
): Promise<GitHubIssue | null> {
  const q = encodeURIComponent(`repo:${repo} is:issue "${titlePattern}" in:title`)
  const result = (await gh(
    `https://api.github.com/search/issues?q=${q}&per_page=1`,
    installationToken
  )) as { items: GitHubIssue[] }

  return result.items?.[0] ?? null
}

/**
 * Add a comment to an existing issue
 */
export async function addIssueComment(
  installationToken: string,
  repo: string,
  issueNumber: number,
  body: string
): Promise<void> {
  await gh(`https://api.github.com/repos/${repo}/issues/${issueNumber}/comments`, installationToken, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ body }),
  })
}
