# Supabase Observability & Governance Architecture

> **Supabase = Control Plane + Telemetry Brain**
> **Odoo = Transactional SoR**
> **Vercel / MCP / n8n = Execution Layer**

This architecture provides Azure Portal–style **Advisor** (security, cost, reliability),
Databricks-like **job + pipeline observability**, and settings-as-code governance—all
without paying for Vercel Observability Plus or Supabase Enterprise.

## Core Principle

**"Enterprise ≠ Paid, Enterprise = Architecture"**

Supabase Enterprise features mostly give:
1. Visibility
2. Guardrails
3. Auditability
4. Control loops

We recreate these with primitives you already have.

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                           EXECUTION LAYER                               │
├────────────┬────────────┬────────────┬────────────┬───────────────────┤
│   Vercel   │   Slack    │   GitHub   │    n8n     │   MCP Agents      │
│  (Apps)    │  (Alerts)  │  (Actions) │ (Workflows)│   (AI Tooling)    │
└─────┬──────┴─────┬──────┴─────┬──────┴─────┬──────┴────────┬──────────┘
      │            │            │            │               │
      └────────────┴────────────┼────────────┴───────────────┘
                                │
                    ┌───────────▼───────────┐
                    │                       │
                    │   SUPABASE            │
                    │   (Control Plane)     │
                    │                       │
                    │   ┌─────────────────┐ │
                    │   │ Auth (Identity) │ │
                    │   └─────────────────┘ │
                    │   ┌─────────────────┐ │
                    │   │ RLS (Security)  │ │
                    │   └─────────────────┘ │
                    │   ┌─────────────────┐ │
                    │   │ ops.* (Telemetry)│ │
                    │   └─────────────────┘ │
                    │   ┌─────────────────┐ │
                    │   │ advisor.*       │ │
                    │   │ (Governance)    │ │
                    │   └─────────────────┘ │
                    │   ┌─────────────────┐ │
                    │   │ mirror.*        │ │
                    │   │ (Read Models)   │ │
                    │   └─────────────────┘ │
                    │                       │
                    └───────────┬───────────┘
                                │
                    ┌───────────▼───────────┐
                    │                       │
                    │   ODOO                │
                    │   (System of Record)  │
                    │                       │
                    │   • Accounting        │
                    │   • Contacts          │
                    │   • Invoices          │
                    │   • HR / Operations   │
                    │                       │
                    └───────────────────────┘
```

---

## Schema Organization

### `ops` Schema - Observability

Central telemetry for all job/pipeline/workflow executions.

| Table | Purpose |
|-------|---------|
| `ops.runs` | Track all job executions (status, timing, metrics) |
| `ops.events` | Append-only event log (audit trail) |
| `ops.health` | Time-series health signals |
| `ops.cost_edge_invocations` | Edge Function cost tracking |
| `ops.cost_db_queries` | Database query cost tracking |
| `ops.cost_storage_growth` | Storage growth and cost |
| `ops.config_snapshots` | Configuration baselines for drift detection |
| `ops.cron_jobs` | Cron job definitions and status |

**Key Functions:**
- `ops.start_run()` - Start tracking a job execution
- `ops.complete_run()` - Mark job as successful
- `ops.fail_run()` - Mark job as failed (with retry logic)
- `ops.log_event()` - Log an event
- `ops.record_health()` - Record a health signal
- `ops.record_edge_cost()` - Track function costs

**Views:**
- `ops.v_recent_failures` - Failed runs in last 24h
- `ops.v_active_runs` - Currently running jobs
- `ops.v_job_stats` - Success rates by job
- `ops.v_current_health` - Latest health signals
- `ops.v_cost_anomalies` - Unusual cost patterns

### `advisor` Schema - Governance

Azure Advisor-style automated checks and recommendations.

| Table | Purpose |
|-------|---------|
| `advisor.checks` | Check definitions (SQL queries, functions) |
| `advisor.findings` | Detected issues |
| `advisor.check_runs` | Check execution audit trail |
| `advisor.recommendations` | High-level recommendations |

**Built-in Checks:**

| ID | Category | Description |
|----|----------|-------------|
| SEC-001 | Security | RLS not enabled on public tables |
| SEC-002 | Security | Secrets in environment variables |
| SEC-003 | Security | Overly permissive RLS policies |
| SEC-004 | Security | Anonymous access enabled |
| COST-001 | Cost | Unused database tables |
| COST-002 | Cost | Large unused indexes |
| COST-003 | Cost | High Edge Function invocations |
| REL-001 | Reliability | Missing primary keys |
| REL-002 | Reliability | Tables without timestamps |
| REL-003 | Reliability | Long-running queries |
| PERF-001 | Performance | Missing indexes on foreign keys |
| PERF-002 | Performance | Bloated tables |
| OPS-001 | Operational | Failed jobs in last 24 hours |
| OPS-002 | Operational | Stuck or long-running jobs |
| DRIFT-001 | Operational | Configuration drift detected |

**Key Functions:**
- `advisor.run_check(check_id)` - Run a specific check
- `advisor.run_all_checks()` - Run all enabled checks
- `advisor.dismiss_finding()` - Dismiss a finding
- `advisor.resolve_finding()` - Mark finding as resolved
- `advisor.get_summary()` - Get findings summary

**Views:**
- `advisor.v_open_findings` - All open findings by severity
- `advisor.v_findings_by_category` - Counts by category
- `advisor.v_recent_check_runs` - Recent check executions
- `advisor.v_score` - Overall advisor score (0-100)

### `mirror` Schema - Odoo Read Models

Read-only mirrors of Odoo data for fast access and joins.

| Table | Odoo Model |
|-------|------------|
| `mirror.res_company` | Companies |
| `mirror.res_partner` | Customers/Vendors |
| `mirror.account_move` | Invoices |
| `mirror.sale_order` | Sales Orders |
| `mirror.product_template` | Products |
| `mirror.res_users` | Users (reference only) |
| `mirror.sync_log` | Sync audit trail |

**Sync Pattern:**
- Odoo → Supabase: cron / webhook / n8n (append-only or upsert)
- Supabase → Odoo: NEVER direct writes, always via Edge Function → Odoo API

**Views:**
- `mirror.v_customers` - Active customers
- `mirror.v_vendors` - Active vendors
- `mirror.v_open_invoices` - Unpaid invoices with due status
- `mirror.v_recent_orders` - Last 30 days of orders
- `mirror.v_sync_health` - Sync status per table

---

## Edge Functions

### `slack-alert`

Sends alerts to Slack based on findings and failures.

**Endpoints:**
- `?action=send` - Direct alert (POST body = AlertPayload)
- `?action=check_findings` - Check for new critical findings
- `?action=check_failures` - Check for failed runs
- `?action=check_all` - Check everything
- `?action=webhook` - Database webhook trigger

**Environment Variables:**
- `SLACK_WEBHOOK_URL` (required)
- `SLACK_CHANNEL` (optional)

### `health-check`

Core control loop for system health monitoring.

**Endpoints:**
- `?action=full` - Run all checks (default)
- `?action=database` - Database health only
- `?action=ops` - Job success rates only
- `?action=mirror` - Sync health only
- `?action=external` - External services only
- `?action=advisor` - Run advisor checks only

**Control Loop Pattern:**
```
Cron → check systems
     → write ops_health
     → run advisor checks
     → if severity >= HIGH
         → Slack alert
         → GitHub issue (optional)
```

### `drift-detection`

Detects configuration drift across systems.

**Endpoints:**
- `?systems=github,mailgun,supabase` - Systems to check
- `?repos=owner/repo1,owner/repo2` - GitHub repos
- `?domains=mg.example.com` - Mailgun domains

**Supported Systems:**
- GitHub repository settings
- Mailgun domain configuration
- Supabase RLS and extensions

---

## Cron Jobs

| Job | Schedule | Description |
|-----|----------|-------------|
| `health-check-full` | `*/5 * * * *` | Full health check every 5 min |
| `advisor-checks` | `0 * * * *` | Run advisor checks hourly |
| `slack-alert-check` | `* * * * *` | Check for alertable events |
| `drift-detection` | `15 * * * *` | Check for config drift hourly |
| `storage-metrics` | `0 */6 * * *` | Collect storage metrics |
| `cleanup-old-events` | `0 2 * * *` | Remove events > 30 days |
| `cleanup-old-health` | `0 3 * * *` | Remove health signals > 7 days |

---

## RLS Policies

All tables have Row Level Security enabled.

**Pattern:**
- `service_role` has full access (for Edge Functions)
- `authenticated` users have read access to ops/advisor
- `mirror` tables filter by `company_id` from JWT claims

---

## Environment Variables

### Required
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `SUPABASE_ANON_KEY`

### Optional (for full functionality)
- `SLACK_WEBHOOK_URL` - Slack alerts
- `SLACK_CHANNEL` - Override default channel
- `GITHUB_TOKEN` - GitHub drift detection
- `GITHUB_REPO` - Repo for issue creation
- `GITHUB_REPOS` - Comma-separated repos to monitor
- `MAILGUN_API_KEY` - Mailgun drift detection
- `MAILGUN_DOMAINS` - Comma-separated domains to monitor
- `ODOO_URL` - Odoo health checks

---

## Deployment

### Apply Migrations

```bash
cd supabase
supabase db push
```

### Deploy Edge Functions

```bash
supabase functions deploy slack-alert
supabase functions deploy health-check
supabase functions deploy drift-detection
```

### Set Secrets

```bash
supabase secrets set \
  SLACK_WEBHOOK_URL="https://hooks.slack.com/..." \
  GITHUB_TOKEN="ghp_..." \
  MAILGUN_API_KEY="key-..."
```

### Schedule Cron Jobs

```sql
SELECT ops.schedule_cron_jobs();
```

---

## What NOT To Do

❌ Don't make Supabase write accounting data to Odoo
❌ Don't embed credentials in Vercel environment variables
❌ Don't mirror everything eagerly (start with what you need)
❌ Don't build custom admin UI too early (use Supabase Studio)
❌ Don't chase "Enterprise" labels—build with primitives

---

## Cost Considerations

This architecture uses **free-tier friendly** primitives:

| Feature | Cost |
|---------|------|
| Supabase Cron | Included in all plans |
| Edge Functions | Pay per invocation (~$2/million) |
| Database storage | Pay per GB (~$0.125/GB/month) |
| Supabase Studio | Free |

**Avoided costs:**
- Vercel Observability Plus (~$50/month)
- Supabase Log Drains (Enterprise)
- External APM tools

---

## Migration Path to Enterprise

If you later need Enterprise features:

1. **Log Drains** → Export `ops.events` to external system
2. **SAML SSO** → Add Supabase Auth SAML provider
3. **SOC-2 Compliance** → This architecture is already SOC-2 aligned
4. **SLA** → Enterprise plan includes SLA

The architecture is designed to grow into Enterprise without redesign.
