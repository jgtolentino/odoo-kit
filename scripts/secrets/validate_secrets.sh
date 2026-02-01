#!/usr/bin/env bash
#
# Validate required secrets are present in environment
# Usage: ./scripts/secrets/validate_secrets.sh
#
# Loads .env.local if present (dev), otherwise expects env vars already exported (CI)
#
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "================================"
echo "Platform Kit Secrets Validation"
echo "================================"

# Load .env.local if present (for local dev)
if [[ -f ".env.local" ]]; then
  echo -e "${YELLOW}Loading .env.local...${NC}"
  set -a
  # shellcheck disable=SC1091
  source .env.local
  set +a
fi

missing=()
warnings=()

# Required secrets (P0)
required=(
  SUPABASE_URL
  SUPABASE_SERVICE_ROLE_KEY
  GITHUB_TOKEN
  N8N_BASE_URL
  N8N_API_KEY
  MCP_BASE_URL
  MCP_API_KEY
  PLANE_BASE_URL
  PLANE_API_TOKEN
  MAILGUN_DOMAIN
  MAILGUN_API_KEY
  MAILGUN_WEBHOOK_SIGNING_KEY
  SHELF_API_KEY
  ATOMIC_CRM_API_KEY
)

# Recommended secrets (P1)
recommended=(
  SLACK_BOT_TOKEN
  SLACK_WEBHOOK_URL
  ODOO_BASE_URL
  ODOO_API_KEY
)

echo ""
echo "Checking required secrets..."
for k in "${required[@]}"; do
  if [[ -z "${!k:-}" ]]; then
    missing+=("$k")
    echo -e "  ${RED}✗${NC} $k"
  else
    echo -e "  ${GREEN}✓${NC} $k"
  fi
done

echo ""
echo "Checking recommended secrets..."
for k in "${recommended[@]}"; do
  if [[ -z "${!k:-}" ]]; then
    warnings+=("$k")
    echo -e "  ${YELLOW}○${NC} $k (not set)"
  else
    echo -e "  ${GREEN}✓${NC} $k"
  fi
done

echo ""

# Anti-footgun checks
if [[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  if [[ "${SUPABASE_SERVICE_ROLE_KEY}" == *"anon"* ]]; then
    echo -e "${RED}✗ SUPABASE_SERVICE_ROLE_KEY appears to be anon key. Use service_role key.${NC}"
    missing+=("SUPABASE_SERVICE_ROLE_KEY (wrong key type)")
  fi

  # Check minimum length
  if [[ ${#SUPABASE_SERVICE_ROLE_KEY} -lt 100 ]]; then
    echo -e "${YELLOW}⚠ SUPABASE_SERVICE_ROLE_KEY seems short. Verify it's correct.${NC}"
  fi
fi

if [[ -n "${SUPABASE_URL:-}" ]]; then
  if [[ ! "${SUPABASE_URL}" =~ ^https:// ]]; then
    echo -e "${YELLOW}⚠ SUPABASE_URL should use HTTPS${NC}"
  fi
fi

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  if [[ ${#GITHUB_TOKEN} -lt 10 ]]; then
    echo -e "${YELLOW}⚠ GITHUB_TOKEN seems too short${NC}"
  fi
fi

# Summary
echo "================================"
if (( ${#missing[@]} > 0 )); then
  echo -e "${RED}❌ Missing ${#missing[@]} required secret(s):${NC}"
  printf '   - %s\n' "${missing[@]}"
  echo ""
  echo "Set these in:"
  echo "  - .env.local (local dev)"
  echo "  - Supabase secrets (Edge Functions)"
  echo "  - GitHub Actions secrets (CI)"
  exit 1
fi

if (( ${#warnings[@]} > 0 )); then
  echo -e "${YELLOW}⚠ ${#warnings[@]} recommended secret(s) not set${NC}"
  echo "  These are optional but recommended for full functionality."
fi

echo -e "${GREEN}✅ All required secrets validated successfully!${NC}"
echo "================================"
