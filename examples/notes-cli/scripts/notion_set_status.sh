#!/usr/bin/env bash
# notion_set_status.sh — best-effort, one-way push of a feature's status back to its
# source Notion page's Status column, so Notion reflects harness.db without manual
# updates. Called from claim (-> notion_status_in_progress) and log-out (->
# notion_status_done); every failure here is a [WARN], never a [FAIL] — it must never
# block claim or log-out. Requires curl; skips cleanly without it, without a token, or
# when the feature being claimed/closed has no source_id (wasn't imported from Notion).
#
# Requires the Notion integration to have "Update content" capability, not just read
# (notion.so/my-integrations -> your integration -> Capabilities) — the read-only
# check in notion_check.sh doesn't need this, but writing the status back does.
#
# Usage: notion_set_status.sh <notion-page-id> <status-value>
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PAGE_ID="${1:-}"
STATUS_VALUE="${2:-}"

if [ -z "$PAGE_ID" ] || [ -z "$STATUS_VALUE" ]; then
  # Nothing to update (no source_id on this feature) — not an error.
  exit 0
fi

DATABASE_ID="$(config '.notion_database_id')"
TOKEN_ENV="$(config '.notion_token_env' 'NOTION_API_TOKEN')"

if [ -z "$DATABASE_ID" ]; then
  exit 0
fi

TOKEN="$(resolve_indirect "$TOKEN_ENV")"
if [ -z "$TOKEN" ]; then
  warn "\$$TOKEN_ENV not set — skipping Notion status update"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  warn "curl not available — skipping Notion status update"
  exit 0
fi

# Same property-id + type resolution as notion_check.sh: an exact "Status" bareword
# match can fail on some databases (multi-source database quirks, or a hidden
# character in the property name — both seen in practice), so resolve id and type
# from the schema first instead of assuming both.
schema=$(curl -sS -m 10 -w '\n%{http_code}' -X GET \
  "https://api.notion.com/v1/databases/$DATABASE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Notion-Version: 2022-06-28") || { warn "Notion schema lookup failed (network error) — skipping status update"; exit 0; }

schema_status="${schema##*$'\n'}"
schema_body="${schema%$'\n'*}"

if [[ "$schema_status" != 2* ]]; then
  warn "Notion schema lookup failed (HTTP $schema_status) — skipping status update. Body: $schema_body"
  exit 0
fi

status_prop=$(jq -c '
  [.properties | to_entries[]
    | select((.key | ascii_downcase | gsub("[^a-z0-9]"; "")) == "status")
  ][0].value | {id, type}
' <<<"$schema_body")

status_prop_id=$(jq -r '.id // empty' <<<"$status_prop")
status_prop_type=$(jq -r '.type // empty' <<<"$status_prop")

if [ -z "$status_prop_id" ] || { [ "$status_prop_type" != "select" ] && [ "$status_prop_type" != "status" ]; }; then
  warn "database $DATABASE_ID has no select/status 'Status' property — skipping status update"
  exit 0
fi

payload=$(jq -n --arg pid "$status_prop_id" --arg type "$status_prop_type" --arg val "$STATUS_VALUE" \
  '{properties: {($pid): {($type): {name: $val}}}}')

resp=$(curl -sS -m 10 -w '\n%{http_code}' -X PATCH \
  "https://api.notion.com/v1/pages/$PAGE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d "$payload") || { warn "Notion status update failed (network error) — skipping"; exit 0; }

resp_status="${resp##*$'\n'}"
resp_body="${resp%$'\n'*}"

if [[ "$resp_status" != 2* ]]; then
  warn "Notion status update failed (HTTP $resp_status) — skipping. Body: $resp_body"
  exit 0
fi

ok "pushed Notion status \"$STATUS_VALUE\" to page $PAGE_ID"
