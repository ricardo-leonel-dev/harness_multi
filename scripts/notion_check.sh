#!/usr/bin/env bash
# notion_check.sh — best-effort, token-efficient check for new tasks in a Notion
# database. Queries the Notion API directly via curl+jq (not the MCP connector) so
# the raw, verbose Notion JSON never enters the model's context — only the
# filtered/trimmed {source_id, name, title, description, acceptance} array does.
# That output is already exactly the shape scripts/harness.sh notion-diff expects.
#
# Every failure here is a [WARN] + `[]` on stdout, never a [FAIL]: the harness must
# keep working with zero Notion connectivity. Requires curl; skips cleanly without it.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DATABASE_ID="$(config '.notion_database_id')"
TOKEN_ENV="$(config '.notion_token_env' 'NOTION_API_TOKEN')"

if [ -z "$DATABASE_ID" ]; then
  warn "no notion_database_id configured in $HARNESS_CONFIG — skipping Notion check"
  echo '[]'
  exit 0
fi

TOKEN="${!TOKEN_ENV:-}"
if [ -z "$TOKEN" ]; then
  warn "\$$TOKEN_ENV not set — skipping Notion check (create a Notion internal integration, share the database with it, and export its token as \$$TOKEN_ENV)"
  echo '[]'
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  warn "curl not available — skipping Notion check"
  echo '[]'
  exit 0
fi

# Notion databases created under the newer "multi-source database" model reject
# query filters that reference a property by name ("Could not find property with
# name or id: Project") even though the name is correct — only the property's
# opaque id works there. Names stay stable for display but ids are the only
# thing guaranteed to resolve in a filter, so look the id up from the schema
# first instead of hardcoding "Project" into the filter payload.
schema=$(curl -sS -m 10 -w '\n%{http_code}' -X GET \
  "https://api.notion.com/v1/databases/$DATABASE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Notion-Version: 2022-06-28") || { warn "Notion schema lookup failed (network error) — skipping"; echo '[]'; exit 0; }

schema_status="${schema##*$'\n'}"
schema_body="${schema%$'\n'*}"

if [[ "$schema_status" != 2* ]]; then
  warn "Notion schema lookup failed (HTTP $schema_status) — skipping. Body: $schema_body"
  echo '[]'
  exit 0
fi

# Matched by normalized name (lowercased, non-alphanumerics stripped) rather than
# an exact "Project" bareword: a stray leading/trailing space or invisible
# character in the property name (invisible in the Notion UI, but not equal
# byte-for-byte) would otherwise silently fail an exact match.
project_prop_id=$(jq -r '
  [.properties | to_entries[]
    | select((.key | ascii_downcase | gsub("[^a-z0-9]"; "")) == "project")
  ][0].value.id // empty
' <<<"$schema_body")
if [ -z "$project_prop_id" ]; then
  warn "database $DATABASE_ID has no property matching 'Project' — skipping"
  echo '[]'
  exit 0
fi

# Server-side filter on Project (reduces what travels over the wire); Status is
# filtered client-side below since it may be a select or a native status property.
payload=$(jq -n --arg pid "$project_prop_id" --arg slug "$PROJECT_SLUG" \
  '{filter: {property: $pid, select: {equals: $slug}}}')

resp=$(curl -sS -m 10 -w '\n%{http_code}' -X POST \
  "https://api.notion.com/v1/databases/$DATABASE_ID/query" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d "$payload") || { warn "Notion query failed (network error) — skipping"; echo '[]'; exit 0; }

status="${resp##*$'\n'}"
body="${resp%$'\n'*}"

if [[ "$status" != 2* ]]; then
  warn "Notion query failed (HTTP $status) — skipping. Body: $body"
  echo '[]'
  exit 0
fi

# Same normalized-name lookup as the Project filter above, applied to every
# property this script reads out of each result page — a page's properties
# object can have the same invisible-character-in-the-name quirk as the
# database schema did, and an exact bareword match would silently break here
# in a much harder to diagnose way (a jq parse failure with no property name
# in the error at all).
echo "$body" | jq -c '
  def propval($norm):
    ([to_entries[] | select((.key | ascii_downcase | gsub("[^a-z0-9]"; "")) == $norm) | .value] | first) // null;

  [.results[]
    | .properties as $p
    | ($p | propval("status")) as $status
    | ($p | propval("name")) as $namep
    | ($p | propval("description")) as $descp
    | ($p | propval("acceptancecriteria")) as $accp
    | select((($status.select.name // $status.status.name // "")) == "Ready")
    | {
        source_id: .id,
        name: (($namep.title // []) | map(.plain_text) | join("")
               | ascii_downcase
               | gsub("[^a-z0-9]+"; "_")
               | gsub("^_+|_+$"; "")),
        title: (($namep.title // []) | map(.plain_text) | join("")),
        description: (($descp.rich_text // []) | map(.plain_text) | join("")),
        acceptance: ((($accp.rich_text // []) | map(.plain_text) | join(""))
                     | split("\n") | map(select(length > 0)))
      }
  ]' 2>/dev/null || { warn "failed to parse Notion response — skipping"; echo '[]'; }
