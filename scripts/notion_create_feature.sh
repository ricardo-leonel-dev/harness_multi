#!/usr/bin/env bash
# notion_create_feature.sh — best-effort creation of a new Notion page (a
# feature card) in the configured database. Built for cross-project
# dependency requests: a feature in one project needs work done in a sibling
# project, so this creates that sibling's Notion card directly instead of
# asking a human to copy-paste it by hand.
#
# Same schema-resolution pattern as notion_check.sh/notion_set_status.sh:
# property ids/types are looked up from the database schema, never hardcoded
# by name — multi-source databases reject property filters/writes addressed
# by name even when the name is correct, only the opaque id reliably works.
#
# Requires the Notion integration to have "Insert content" capability
# (notion.so/my-integrations -> your integration -> Capabilities), in
# addition to "Read content" (already required by notion_check.sh).
#
# Unlike notion_check.sh/notion_set_status.sh, a failure here is NOT a silent
# [WARN]: the caller (harness.sh block) must not mark a feature blocked on a
# card that was never actually created, so this script exits non-zero (with
# a [FAIL] on stderr) on any failure instead of degrading to `[]`/no-op.
#
# Usage:
#   notion_create_feature.sh (--project <slug> | --project-path <dir>) --title <text> \
#                             --description <text> [--acceptance <text>] [--status <value, default "Backlog">] [--sdd]
#                             [--mode normal|risk] [--approval]
#
# --sdd checks the database's optional "SDD" checkbox property (the same one
# notion_check.sh reads back on import) on the created page. Pass it whenever the local
# feature this card mirrors was itself created with `add-feature --sdd` — otherwise the
# card silently reads as a non-spec-driven feature to anyone looking at the Notion board,
# even though harness.db enforces the spec gate correctly regardless of what Notion shows.
# A database without an "SDD" property just ignores the flag (same graceful-skip as the
# optional Description/Acceptance Criteria properties below).
#
# --mode normal|risk sets the database's optional "Mode" select ("Normal"/"Risk", read back
# by notion_check.sh) and --approval its optional "Plan approval" checkbox: pass them
# exactly as given to `add-feature --mode/--approval`, so the board shows the lean flow
# harness.db enforces. Same graceful skip when the database lacks either property (or
# has it with another type). --mode risk --approval is accepted with a warning and
# leaves the checkbox unticked.
#
# --project-path <dir> reads <dir>/.harness.json's project_slug directly instead of
# trusting a hand-typed/guessed slug — use this whenever the target project's directory
# is known (which AGENTS.md's cross-project dependency flow always requires anyway, for
# the BLOCKED_ON note). A guessed slug (e.g. "rushr-web-display-database" instead of the
# real "rushr-web-display-db") silently produces a card the target project's own
# notion-check never matches, since that filters on an exact Project-property match —
# reading the slug from the actual config file makes that class of mismatch impossible.
# --project <slug> still exists for callers that don't have a directory to point at.
#
# On success, prints {"page_id": "...", "url": "...", "predicted_name": "..."}
# to stdout. predicted_name applies the exact same title normalization
# notion_check.sh uses to derive a feature's `name` from its Notion title, so
# the caller knows ahead of time what name that feature will have once
# `notion-import` picks up this card in the target project — no need to
# query Notion again later just to find out.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

TARGET_PROJECT=""
TARGET_PROJECT_PATH=""
TITLE=""
DESCRIPTION=""
ACCEPTANCE=""
STATUS_VALUE="Backlog"
SDD_FLAG=""
MODE=""
APPROVAL_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project) TARGET_PROJECT="$2"; shift 2 ;;
    --project-path) TARGET_PROJECT_PATH="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --acceptance) ACCEPTANCE="$2"; shift 2 ;;
    --status) STATUS_VALUE="$2"; shift 2 ;;
    --sdd) SDD_FLAG=1; shift ;;
    --mode) MODE="${2-}"; shift; [ $# -eq 0 ] || shift ;;
    --approval) APPROVAL_FLAG=1; shift ;;
    *) echo "[FAIL] unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$TARGET_PROJECT_PATH" ]; then
  if [ -n "$TARGET_PROJECT" ]; then
    echo "[FAIL] pass either --project or --project-path, not both" >&2
    exit 1
  fi
  target_config="$TARGET_PROJECT_PATH/.harness.json"
  if [ ! -f "$target_config" ]; then
    echo "[FAIL] $target_config not found -- is --project-path correct?" >&2
    exit 1
  fi
  TARGET_PROJECT="$(jq -r '.project_slug // empty' "$target_config")"
  if [ -z "$TARGET_PROJECT" ]; then
    echo "[FAIL] $target_config has no project_slug" >&2
    exit 1
  fi
fi

if [ -z "$TARGET_PROJECT" ] || [ -z "$TITLE" ] || [ -z "$DESCRIPTION" ]; then
  echo "[FAIL] usage: notion_create_feature.sh (--project <slug> | --project-path <dir>) --title <text> --description <text> [--acceptance <text>] [--status <value>] [--sdd] [--mode normal|risk] [--approval]" >&2
  exit 1
fi

# Same combinations add-feature accepts (and the same warning for risk with
# --approval), so the card can't claim a flow the local feature doesn't have.
case "$MODE" in
  "") mode_label="" ;;
  normal) mode_label="Normal" ;;
  risk) mode_label="Risk" ;;
  *) echo "[FAIL] --mode must be 'normal' or 'risk', got: $MODE" >&2; exit 1 ;;
esac
# --mode risk --approval: risk always needs approval, so the flag is redundant;
# accepted with the same warning add-feature and notion-import give, and the checkbox is left
# unticked so the card reads the same as any other risk card.
if [ -n "$APPROVAL_FLAG" ] && [ "$MODE" = risk ]; then
  echo "[WARN]  --approval with --mode risk: risk always requires approval; checkbox ignored" >&2
  APPROVAL_FLAG=""
fi
if [ -n "$APPROVAL_FLAG" ] && [ "$MODE" != normal ]; then
  echo "[FAIL] --approval only applies with --mode normal (risk always needs approval)" >&2; exit 1
fi
if [ -n "$MODE" ] && [ -n "$SDD_FLAG" ]; then
  echo "[FAIL] --sdd and --mode are alternatives (the spec flow or the lean flow), not both" >&2; exit 1
fi

DATABASE_ID="$(config '.notion_database_id')"
TOKEN_ENV="$(config '.notion_token_env' 'NOTION_API_TOKEN')"

if [ -z "$DATABASE_ID" ]; then
  echo "[FAIL] no notion_database_id configured in $HARNESS_CONFIG" >&2
  exit 1
fi

TOKEN="$(resolve_indirect "$TOKEN_ENV")"
if [ -z "$TOKEN" ]; then
  echo "[FAIL] \$$TOKEN_ENV not set (create a Notion internal integration, share the database with it, and export its token as \$$TOKEN_ENV)" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "[FAIL] curl not available" >&2
  exit 1
fi

schema=$(curl -sS -m 10 -w '\n%{http_code}' -X GET \
  "https://api.notion.com/v1/databases/$DATABASE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Notion-Version: 2022-06-28") || { echo "[FAIL] Notion schema lookup failed (network error)" >&2; exit 1; }

schema_status="${schema##*$'\n'}"
schema_body="${schema%$'\n'*}"

if [[ "$schema_status" != 2* ]]; then
  echo "[FAIL] Notion schema lookup failed (HTTP $schema_status). Body: $schema_body" >&2
  exit 1
fi

# Same normalized-name property resolution as notion_check.sh/notion_set_status.sh
# (lowercased, non-alphanumerics stripped) — guards against a stray space or
# invisible character in the property name that would silently fail an exact match.
prop() {
  local norm="$1"
  jq -c --arg n "$norm" '
    [.properties | to_entries[]
      | select((.key | ascii_downcase | gsub("[^a-z0-9]"; "")) == $n)
    ][0].value | {id, type}
  ' <<<"$schema_body"
}

name_prop_id=$(jq -r '.id // empty' <<<"$(prop name)")
project_prop_id=$(jq -r '.id // empty' <<<"$(prop project)")
status_prop=$(prop status)
status_prop_id=$(jq -r '.id // empty' <<<"$status_prop")
status_prop_type=$(jq -r '.type // empty' <<<"$status_prop")
desc_prop_id=$(jq -r '.id // empty' <<<"$(prop description)")
accept_prop_id=$(jq -r '.id // empty' <<<"$(prop acceptancecriteria)")
sdd_prop=$(prop sdd)
sdd_prop_id=$(jq -r '.id // empty' <<<"$sdd_prop")
sdd_prop_type=$(jq -r '.type // empty' <<<"$sdd_prop")
if [ -n "$SDD_FLAG" ]; then sdd_flag_json=true; else sdd_flag_json=false; fi
mode_prop=$(prop mode)
mode_prop_id=$(jq -r '.id // empty' <<<"$mode_prop")
mode_prop_type=$(jq -r '.type // empty' <<<"$mode_prop")
approval_prop=$(prop planapproval)
approval_prop_id=$(jq -r '.id // empty' <<<"$approval_prop")
approval_prop_type=$(jq -r '.type // empty' <<<"$approval_prop")
if [ -n "$APPROVAL_FLAG" ]; then approval_flag_json=true; else approval_flag_json=false; fi

if [ -z "$name_prop_id" ] || [ -z "$project_prop_id" ] || [ -z "$status_prop_id" ]; then
  echo "[FAIL] database $DATABASE_ID is missing a Name/Project/Status property" >&2
  exit 1
fi

if [ "$status_prop_type" != "select" ] && [ "$status_prop_type" != "status" ]; then
  echo "[FAIL] database $DATABASE_ID's Status property is not a select/status type" >&2
  exit 1
fi

# Note: Notion's native "status" property type only accepts values that
# already exist as options (unlike "select", which auto-creates new options
# on write) — if $STATUS_VALUE isn't already a configured status option, the
# POST below fails with a Notion API error surfaced via [FAIL] HTTP <code>.
properties=$(jq -n \
  --arg name_id "$name_prop_id" --arg title "$TITLE" \
  --arg project_id "$project_prop_id" --arg project "$TARGET_PROJECT" \
  --arg status_id "$status_prop_id" --arg status_type "$status_prop_type" --arg status "$STATUS_VALUE" \
  --arg desc_id "$desc_prop_id" --arg description "$DESCRIPTION" \
  --arg accept_id "$accept_prop_id" --arg acceptance "$ACCEPTANCE" \
  --arg sdd_id "$sdd_prop_id" --arg sdd_type "$sdd_prop_type" --argjson sdd_flag "$sdd_flag_json" \
  --arg mode_id "$mode_prop_id" --arg mode_type "$mode_prop_type" --arg mode "$mode_label" \
  --arg approval_id "$approval_prop_id" --arg approval_type "$approval_prop_type" --argjson approval_flag "$approval_flag_json" \
  '{
    ($name_id): {title: [{text: {content: $title}}]},
    ($project_id): {select: {name: $project}},
    ($status_id): {($status_type): {name: $status}}
  }
  + (if $desc_id != "" then {($desc_id): {rich_text: [{text: {content: $description}}]}} else {} end)
  + (if $accept_id != "" and $acceptance != "" then {($accept_id): {rich_text: [{text: {content: $acceptance}}]}} else {} end)
  + (if $sdd_id != "" and $sdd_type == "checkbox" and $sdd_flag then {($sdd_id): {checkbox: true}} else {} end)
  + (if $mode_id != "" and $mode_type == "select" and $mode != "" then {($mode_id): {select: {name: $mode}}} else {} end)
  + (if $approval_id != "" and $approval_type == "checkbox" and $approval_flag then {($approval_id): {checkbox: true}} else {} end)
  ')

payload=$(jq -n --arg db "$DATABASE_ID" --argjson props "$properties" \
  '{parent: {database_id: $db}, properties: $props}')

resp=$(curl -sS -m 10 -w '\n%{http_code}' -X POST \
  "https://api.notion.com/v1/pages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d "$payload") || { echo "[FAIL] Notion page creation failed (network error)" >&2; exit 1; }

resp_status="${resp##*$'\n'}"
resp_body="${resp%$'\n'*}"

if [[ "$resp_status" != 2* ]]; then
  echo "[FAIL] Notion page creation failed (HTTP $resp_status). Body: $resp_body" >&2
  exit 1
fi

page_id=$(jq -r '.id' <<<"$resp_body")
page_url=$(jq -r '.url' <<<"$resp_body")
predicted_name=$(jq -Rr 'ascii_downcase | gsub("[^a-z0-9]+"; "_") | gsub("^_+|_+$"; "")' <<<"$TITLE")

jq -n --arg id "$page_id" --arg url "$page_url" --arg name "$predicted_name" \
  '{page_id: $id, url: $url, predicted_name: $name}'
