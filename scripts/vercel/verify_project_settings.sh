#!/usr/bin/env bash
#
# Verify Vercel Project Settings
#
# Retrieves and displays current Vercel project configuration.
# Useful for drift detection and auditing.
#
# Usage:
#   export VERCEL_TOKEN="***"
#   export VERCEL_PROJECT_ID="prj_***"
#   export VERCEL_TEAM_ID="team_***"  # optional
#   ./verify_project_settings.sh
#
set -euo pipefail

: "${VERCEL_TOKEN:?Missing VERCEL_TOKEN}"
: "${VERCEL_PROJECT_ID:?Missing VERCEL_PROJECT_ID}"
: "${VERCEL_TEAM_ID:=}"

qs=""
if [ -n "${VERCEL_TEAM_ID}" ]; then
  qs="?teamId=${VERCEL_TEAM_ID}"
fi

echo "Fetching Vercel project settings..."
echo ""

response=$(curl -sS \
  -H "Authorization: Bearer ${VERCEL_TOKEN}" \
  "https://api.vercel.com/v9/projects/${VERCEL_PROJECT_ID}${qs}")

if echo "${response}" | grep -q '"error"'; then
  echo "ERROR: Failed to fetch project settings"
  echo "${response}" | python3 -m json.tool 2>/dev/null || echo "${response}"
  exit 1
fi

echo "${response}" | python3 -c "
import json, sys

p = json.load(sys.stdin)

print('=== Project Info ===')
print(f\"  ID: {p.get('id')}\")
print(f\"  Name: {p.get('name')}\")
print(f\"  Framework: {p.get('framework')}\")
print()

print('=== Runtime Settings ===')
print(f\"  Node Version: {p.get('nodeVersion')}\")
rc = p.get('resourceConfig') or {}
print(f\"  Build Machine Type: {rc.get('buildMachineType', 'default')}\")
print(f\"  Fluid Compute: {rc.get('fluid', False)}\")
print()

print('=== Build Settings ===')
print(f\"  Build Command: {p.get('buildCommand') or '(default)'}\")
print(f\"  Install Command: {p.get('installCommand') or '(default)'}\")
print(f\"  Output Directory: {p.get('outputDirectory') or '(default)'}\")
print()

print('=== Git Settings ===')
link = p.get('link') or {}
print(f\"  Repo: {link.get('repo')}\")
print(f\"  Production Branch: {link.get('productionBranch')}\")
print()

print('=== Deployment Settings ===')
print(f\"  Root Directory: {p.get('rootDirectory') or '(root)'}\")
print(f\"  Public Source: {p.get('publicSource', False)}\")

# Check for rolling releases / progressive rollouts
rr = p.get('rollingRelease')
if rr:
    print()
    print('=== Rolling Release ===')
    print(f\"  Enabled: {rr.get('enabled', False)}\")
    print(f\"  Advancement Type: {rr.get('advancementType')}\")
"

echo ""
echo "Full JSON response available via: curl with python3 -m json.tool"
