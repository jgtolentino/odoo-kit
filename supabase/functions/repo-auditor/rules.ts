/**
 * Audit rules for repo-auditor Edge Function
 *
 * Each rule checks for a specific security/hardening concern and returns
 * findings with severity, title, and details.
 */

// ============================================================================
// Types
// ============================================================================

export type Severity = 'low' | 'med' | 'high' | 'critical'

export interface Finding {
  rule_id: string
  severity: Severity
  title: string
  details: Record<string, unknown>
  fingerprint: string
}

export interface RepoFiles {
  'README.md'?: string | null
  'docs/SECURITY.md'?: string | null
  'Dockerfile'?: string | null
  'docker-compose.yml'?: string | null
  'docker-compose.yaml'?: string | null
  'supabase/config.toml'?: string | null
  '.github/dependabot.yml'?: string | null
  '.github/dependabot.yaml'?: string | null
  '.github/workflows/codeql.yml'?: string | null
  '.github/workflows/codeql.yaml'?: string | null
  '.github/CODEOWNERS'?: string | null
  '.env.example'?: string | null
  'package.json'?: string | null
  'package-lock.json'?: string | null
  // Directory existence markers
  'supabase/migrations/.exists'?: string | null
  'supabase/functions/.exists'?: string | null
  [key: string]: string | null | undefined
}

// ============================================================================
// Helpers
// ============================================================================

/**
 * Generate stable fingerprint for deduplication
 */
function fp(parts: string[]): string {
  return parts.join('|').toLowerCase()
}

// ============================================================================
// Individual Rules
// ============================================================================

function ruleCodeQLMissing(repo: string, files: RepoFiles): Finding | null {
  const hasCodeQL =
    (files['.github/workflows/codeql.yml'] ?? '').length > 0 ||
    (files['.github/workflows/codeql.yaml'] ?? '').length > 0

  if (!hasCodeQL) {
    return {
      rule_id: 'ci.codeql.missing',
      severity: 'med',
      title: 'Missing CodeQL workflow',
      details: {
        hint: 'Add GitHub CodeQL workflow to scan code for vulnerabilities.',
        docs: 'https://docs.github.com/en/code-security/code-scanning/creating-an-advanced-setup-for-code-scanning/configuring-advanced-setup-for-code-scanning',
      },
      fingerprint: fp([repo, 'ci.codeql.missing']),
    }
  }
  return null
}

function ruleDependabotMissing(repo: string, files: RepoFiles): Finding | null {
  const hasDependabot =
    (files['.github/dependabot.yml'] ?? '').length > 0 ||
    (files['.github/dependabot.yaml'] ?? '').length > 0

  if (!hasDependabot) {
    return {
      rule_id: 'deps.dependabot.missing',
      severity: 'low',
      title: 'Dependabot configuration missing',
      details: {
        hint: 'Add dependabot.yml to keep dependencies updated automatically.',
        docs: 'https://docs.github.com/en/code-security/dependabot/dependabot-version-updates/configuration-options-for-the-dependabot.yml-file',
      },
      fingerprint: fp([repo, 'deps.dependabot.missing']),
    }
  }
  return null
}

function ruleDockerHealthcheckMissing(repo: string, files: RepoFiles): Finding | null {
  const dockerfile = files['Dockerfile']

  if (dockerfile && !/HEALTHCHECK/i.test(dockerfile)) {
    return {
      rule_id: 'docker.healthcheck.missing',
      severity: 'med',
      title: 'Dockerfile missing HEALTHCHECK',
      details: {
        hint: 'Add HEALTHCHECK instruction to improve container orchestration reliability.',
        docs: 'https://docs.docker.com/engine/reference/builder/#healthcheck',
      },
      fingerprint: fp([repo, 'docker.healthcheck.missing']),
    }
  }
  return null
}

function ruleDockerRunAsRoot(repo: string, files: RepoFiles): Finding | null {
  const dockerfile = files['Dockerfile']

  if (dockerfile && !/USER\s+\w+/i.test(dockerfile)) {
    return {
      rule_id: 'docker.runs.as.root',
      severity: 'high',
      title: 'Dockerfile runs as root',
      details: {
        hint: 'Add USER instruction to run container as non-root user.',
        docs: 'https://docs.docker.com/develop/develop-images/dockerfile_best-practices/#user',
      },
      fingerprint: fp([repo, 'docker.runs.as.root']),
    }
  }
  return null
}

function ruleSupabaseRLSNotDocumented(repo: string, files: RepoFiles): Finding | null {
  const hasSupabaseConfig = (files['supabase/config.toml'] ?? '').length > 0
  const hasMigrations = files['supabase/migrations/.exists'] === '1'

  if (hasSupabaseConfig && hasMigrations) {
    const readme = (files['README.md'] ?? '') + (files['docs/SECURITY.md'] ?? '')
    if (!/row level security|rls/i.test(readme)) {
      return {
        rule_id: 'supabase.rls.docs.missing',
        severity: 'low',
        title: 'RLS not documented',
        details: {
          hint: 'Document Row Level Security posture and which schemas are exposed.',
          docs: 'https://supabase.com/docs/guides/auth/row-level-security',
        },
        fingerprint: fp([repo, 'supabase.rls.docs.missing']),
      }
    }
  }
  return null
}

function ruleCodeownersMissing(repo: string, files: RepoFiles): Finding | null {
  const hasCodeowners = (files['.github/CODEOWNERS'] ?? '').length > 0

  if (!hasCodeowners) {
    return {
      rule_id: 'github.codeowners.missing',
      severity: 'low',
      title: 'CODEOWNERS file missing',
      details: {
        hint: 'Add CODEOWNERS to enforce code review ownership.',
        docs: 'https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners',
      },
      fingerprint: fp([repo, 'github.codeowners.missing']),
    }
  }
  return null
}

function ruleSecurityPolicyMissing(repo: string, files: RepoFiles): Finding | null {
  const hasSecurityPolicy = (files['docs/SECURITY.md'] ?? '').length > 0

  // Also check for SECURITY.md at root (we don't fetch it but can add)
  if (!hasSecurityPolicy) {
    return {
      rule_id: 'github.security.policy.missing',
      severity: 'low',
      title: 'Security policy missing',
      details: {
        hint: 'Add SECURITY.md to document vulnerability reporting process.',
        docs: 'https://docs.github.com/en/code-security/getting-started/adding-a-security-policy-to-your-repository',
      },
      fingerprint: fp([repo, 'github.security.policy.missing']),
    }
  }
  return null
}

function ruleEnvExampleMissing(repo: string, files: RepoFiles): Finding | null {
  const hasPackageJson = (files['package.json'] ?? '').length > 0
  const hasEnvExample = (files['.env.example'] ?? '').length > 0

  // Only flag if this looks like a Node.js project
  if (hasPackageJson && !hasEnvExample) {
    return {
      rule_id: 'config.env.example.missing',
      severity: 'low',
      title: '.env.example file missing',
      details: {
        hint: 'Add .env.example to document required environment variables.',
      },
      fingerprint: fp([repo, 'config.env.example.missing']),
    }
  }
  return null
}

function rulePackageLockMissing(repo: string, files: RepoFiles): Finding | null {
  const hasPackageJson = (files['package.json'] ?? '').length > 0
  const hasPackageLock = (files['package-lock.json'] ?? '').length > 0

  if (hasPackageJson && !hasPackageLock) {
    return {
      rule_id: 'deps.lockfile.missing',
      severity: 'med',
      title: 'package-lock.json missing',
      details: {
        hint: 'Commit package-lock.json to ensure reproducible builds and supply chain security.',
        docs: 'https://docs.npmjs.com/cli/v10/configuring-npm/package-lock-json',
      },
      fingerprint: fp([repo, 'deps.lockfile.missing']),
    }
  }
  return null
}

function ruleDockerComposeSecrets(repo: string, files: RepoFiles): Finding | null {
  const compose =
    files['docker-compose.yml'] ?? files['docker-compose.yaml'] ?? null

  if (compose) {
    // Check for hardcoded secrets patterns
    const secretPatterns = [
      /password:\s*["']?[^${\s]/i,
      /api_key:\s*["']?[^${\s]/i,
      /secret:\s*["']?[^${\s]/i,
    ]

    for (const pattern of secretPatterns) {
      if (pattern.test(compose)) {
        return {
          rule_id: 'docker.compose.hardcoded.secrets',
          severity: 'high',
          title: 'Hardcoded secrets in docker-compose',
          details: {
            hint: 'Use environment variables or Docker secrets instead of hardcoded values.',
            docs: 'https://docs.docker.com/compose/use-secrets/',
          },
          fingerprint: fp([repo, 'docker.compose.hardcoded.secrets']),
        }
      }
    }
  }
  return null
}

// ============================================================================
// Rule Runner
// ============================================================================

const ALL_RULES = [
  ruleCodeQLMissing,
  ruleDependabotMissing,
  ruleDockerHealthcheckMissing,
  ruleDockerRunAsRoot,
  ruleSupabaseRLSNotDocumented,
  ruleCodeownersMissing,
  ruleSecurityPolicyMissing,
  ruleEnvExampleMissing,
  rulePackageLockMissing,
  ruleDockerComposeSecrets,
]

/**
 * Run all audit rules against a repository's files
 */
export function runRules(repo: string, files: RepoFiles): Finding[] {
  const findings: Finding[] = []

  for (const rule of ALL_RULES) {
    try {
      const finding = rule(repo, files)
      if (finding) {
        findings.push(finding)
      }
    } catch (e) {
      console.error(`Rule error in ${rule.name}: ${e}`)
    }
  }

  return findings
}

/**
 * Get list of files that rules need to check
 */
export function getRequiredFilePaths(): string[] {
  return [
    'README.md',
    'docs/SECURITY.md',
    'Dockerfile',
    'docker-compose.yml',
    'docker-compose.yaml',
    'supabase/config.toml',
    '.github/dependabot.yml',
    '.github/dependabot.yaml',
    '.github/workflows/codeql.yml',
    '.github/workflows/codeql.yaml',
    '.github/CODEOWNERS',
    '.env.example',
    'package.json',
    'package-lock.json',
  ]
}

/**
 * Get list of directories to check for existence
 */
export function getRequiredDirectoryPaths(): string[] {
  return ['supabase/migrations', 'supabase/functions']
}
