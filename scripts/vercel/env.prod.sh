#!/usr/bin/env bash
set -euo pipefail

# Required Vercel credentials
: "${VERCEL_TOKEN:?VERCEL_TOKEN is required}"
: "${VERCEL_ORG_ID:?VERCEL_ORG_ID is required}"
: "${VERCEL_PROJECT_ID:?VERCEL_PROJECT_ID is required}"

# Required app env vars
: "${SUPABASE_URL:?SUPABASE_URL is required}"
: "${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY is required}"
: "${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY is required}"

export VERCEL_TOKEN

echo "Setting production environment variables..."

# Public vars (safe to expose in browser)
printf "%s" "$SUPABASE_URL" | vercel env add NEXT_PUBLIC_SUPABASE_URL production --token "$VERCEL_TOKEN" --scope "$VERCEL_ORG_ID" --yes >/dev/null 2>&1 || true
printf "%s" "$SUPABASE_ANON_KEY" | vercel env add NEXT_PUBLIC_SUPABASE_ANON_KEY production --token "$VERCEL_TOKEN" --scope "$VERCEL_ORG_ID" --yes >/dev/null 2>&1 || true

# Server-only vars (never NEXT_PUBLIC_)
printf "%s" "$SUPABASE_URL" | vercel env add SUPABASE_URL production --token "$VERCEL_TOKEN" --scope "$VERCEL_ORG_ID" --yes >/dev/null 2>&1 || true
printf "%s" "$SUPABASE_SERVICE_ROLE_KEY" | vercel env add SUPABASE_SERVICE_ROLE_KEY production --token "$VERCEL_TOKEN" --scope "$VERCEL_ORG_ID" --yes >/dev/null 2>&1 || true

echo "OK: production env vars set"
