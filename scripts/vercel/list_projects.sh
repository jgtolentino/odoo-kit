#!/usr/bin/env bash
#
# List Vercel Projects
#
# Retrieves all projects for the authenticated account/team.
# Useful for finding project IDs.
#
# Usage:
#   export VERCEL_TOKEN="***"
#   export VERCEL_TEAM_ID="team_***"  # optional
#   ./list_projects.sh
#
#   # Filter by name:
#   VERCEL_PROJECT_NAME="my-project" ./list_projects.sh
#
set -euo pipefail

: "${VERCEL_TOKEN:?Missing VERCEL_TOKEN}"
: "${VERCEL_TEAM_ID:=}"
: "${VERCEL_PROJECT_NAME:=}"

qs=""
if [ -n "${VERCEL_TEAM_ID}" ]; then
  qs="?teamId=${VERCEL_TEAM_ID}"
fi

echo "Fetching Vercel projects..."
echo ""

response=$(curl -sS \
  -H "Authorization: Bearer ${VERCEL_TOKEN}" \
  "https://api.vercel.com/v9/projects${qs}")

if echo "${response}" | grep -q '"error"'; then
  echo "ERROR: Failed to fetch projects"
  echo "${response}" | python3 -m json.tool 2>/dev/null || echo "${response}"
  exit 1
fi

export VERCEL_PROJECT_NAME

echo "${response}" | python3 -c "
import json, sys, os

filter_name = os.environ.get('VERCEL_PROJECT_NAME', '')
data = json.load(sys.stdin)
projects = data.get('projects', [])

if filter_name:
    projects = [p for p in projects if p.get('name') == filter_name]
    if not projects:
        print(f'No project found with name: {filter_name}')
        sys.exit(1)

print(f'Found {len(projects)} project(s):')
print()

for p in projects:
    print(f\"Project: {p.get('name')}\")
    print(f\"  ID: {p.get('id')}\")
    print(f\"  Framework: {p.get('framework')}\")
    print(f\"  Node Version: {p.get('nodeVersion')}\")
    rc = p.get('resourceConfig') or {}
    print(f\"  Build Machine: {rc.get('buildMachineType', 'default')}\")
    link = p.get('link') or {}
    print(f\"  Repo: {link.get('repo')}\")
    print()
"
