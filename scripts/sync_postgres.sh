#!/usr/bin/env bash
# sync_postgres.sh — best-effort mirror of harness.db into Postgres (hosted
# Supabase or a local/self-hosted instance fronted by PostgREST). Every
# failure here is a [WARN], never a [FAIL]: the harness must keep working
# with zero Postgres connectivity. Requires curl; skips cleanly without it.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

URL_ENV="$(config '.supabase_url_env')"
KEY_ENV="$(config '.supabase_key_env')"

if [ -z "$URL_ENV" ] || [ -z "$KEY_ENV" ]; then
  warn "no supabase_url_env/supabase_key_env configured in $HARNESS_CONFIG — skipping mirror sync"
  exit 0
fi

SUPABASE_URL="$(resolve_indirect "$URL_ENV")"
SUPABASE_KEY="$(resolve_indirect "$KEY_ENV")"

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_KEY" ]; then
  warn "\$$URL_ENV / \$$KEY_ENV not set — skipping mirror sync"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  warn "curl not available — skipping mirror sync"
  exit 0
fi

# SUPABASE_URL is the project root (standard Supabase convention: hosted
# Supabase and `supabase start`'s bundled Kong gateway both serve PostgREST
# under /rest/v1). A bare `postgrest/postgrest` container has no such
# prefix — set supabase_rest_path to "" in .harness.json for that case.
REST_PATH="$(config '.supabase_rest_path' '/rest/v1')"
REST_ROOT="${SUPABASE_URL%/}${REST_PATH}"

# rpc <name> <json-payload>. Prints the response body on success; returns
# non-zero (with the body/status on stderr) on any non-2xx response so
# callers can't mistake a 404/500 for a successful upsert.
rpc() {
  local name="$1" payload="$2"
  local resp status body
  resp=$(curl -sS -m 10 -w '\n%{http_code}' -X POST "$REST_ROOT/rpc/$name" \
    -H "apikey: $SUPABASE_KEY" \
    -H "Authorization: Bearer $SUPABASE_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload") || return 1
  status="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$status" != 2* ]]; then
    echo "HTTP $status: $body" >&2
    return 1
  fi
  printf '%s' "$body"
}

if ! curl -sS -m 5 -o /dev/null -w '' "$REST_ROOT/" -H "apikey: $SUPABASE_KEY"; then
  warn "cannot reach $REST_ROOT — skipping mirror sync"
  exit 0
fi

pid=$(db "SELECT id FROM projects WHERE slug='$(sql_escape "$PROJECT_SLUG")' AND deleted_at IS NULL LIMIT 1;")
desc=$(db "SELECT description FROM projects WHERE id='$(sql_escape "$pid")';")
one_at_a_time=$(db "SELECT one_feature_at_a_time FROM projects WHERE id='$(sql_escape "$pid")';")
require_tests=$(db "SELECT require_tests_to_close FROM projects WHERE id='$(sql_escape "$pid")';")

payload=$(jq -n --arg slug "$PROJECT_SLUG" --arg desc "$desc" \
  --argjson one_at_a_time "$([ "$one_at_a_time" = "1" ] && echo true || echo false)" \
  --argjson require_tests "$([ "$require_tests" = "1" ] && echo true || echo false)" \
  '{p_slug:$slug, p_description:$desc, p_one_feature_at_a_time:$one_at_a_time, p_require_tests_to_close:$require_tests}')
out=$(rpc bootstrap_project "$payload") || { warn "bootstrap_project sync failed: $out"; exit 0; }

sqlite3 -json "$DB_PATH" "SELECT id, feature_number, name, title, description, acceptance, sdd, status, deleted_at
  FROM features WHERE project_id='$(sql_escape "$pid")';" | jq -c '.[]' | while IFS= read -r row; do
  payload=$(jq -n --arg slug "$PROJECT_SLUG" \
    --argjson local_id "$(jq '.id' <<<"$row")" \
    --argjson number "$(jq '.feature_number' <<<"$row")" \
    --arg name "$(jq -r '.name' <<<"$row")" \
    --arg title "$(jq -r '.title' <<<"$row")" \
    --arg desc "$(jq -r '.description // ""' <<<"$row")" \
    --argjson acceptance "$(jq -c '.acceptance | fromjson' <<<"$row")" \
    --argjson sdd "$([ "$(jq -r '.sdd' <<<"$row")" = "1" ] && echo true || echo false)" \
    --arg status "$(jq -r '.status' <<<"$row")" \
    --arg deleted_at "$(jq -r '.deleted_at // ""' <<<"$row")" \
    '{p_project_slug:$slug, p_local_id:$local_id, p_feature_number:$number, p_name:$name, p_title:$title,
      p_description:$desc, p_acceptance:$acceptance, p_status:$status, p_sdd:$sdd,
      p_deleted_at: (if $deleted_at == "" then null else $deleted_at end)}')
  out=$(rpc upsert_feature "$payload") || warn "upsert_feature failed for local_id $(jq '.id' <<<"$row"): $out"
done

sqlite3 -json "$DB_PATH" "SELECT s.id, f.name AS feature_name, s.path, s.status, s.requirements_count,
  s.tasks_count, s.drafted_by, s.ready_at, s.approved_at, s.approved_by, s.deleted_at, s.feature_id
  FROM specs s JOIN features f ON f.id = s.feature_id
  WHERE f.project_id='$(sql_escape "$pid")';" | jq -c '.[]' | while IFS= read -r row; do
  payload=$(jq -n --arg slug "$PROJECT_SLUG" \
    --argjson local_id "$(jq '.id' <<<"$row")" \
    --arg feature_name "$(jq -r '.feature_name' <<<"$row")" \
    --arg path "$(jq -r '.path' <<<"$row")" \
    --arg status "$(jq -r '.status' <<<"$row")" \
    --argjson requirements_count "$(jq '.requirements_count' <<<"$row")" \
    --argjson tasks_count "$(jq '.tasks_count' <<<"$row")" \
    --arg drafted_by "$(jq -r '.drafted_by // ""' <<<"$row")" \
    --arg ready_at "$(jq -r '.ready_at // ""' <<<"$row")" \
    --arg approved_at "$(jq -r '.approved_at // ""' <<<"$row")" \
    --arg approved_by "$(jq -r '.approved_by // ""' <<<"$row")" \
    --arg deleted_at "$(jq -r '.deleted_at // ""' <<<"$row")" \
    --argjson feature_local_id "$(jq '.feature_id' <<<"$row")" \
    '{p_project_slug:$slug, p_local_id:$local_id, p_feature_name:$feature_name, p_feature_local_id:$feature_local_id,
      p_path:$path, p_status:$status,
      p_requirements_count:$requirements_count, p_tasks_count:$tasks_count,
      p_drafted_by: (if $drafted_by == "" then null else $drafted_by end),
      p_ready_at: (if $ready_at == "" then null else $ready_at end),
      p_approved_at: (if $approved_at == "" then null else $approved_at end),
      p_approved_by: (if $approved_by == "" then null else $approved_by end),
      p_deleted_at: (if $deleted_at == "" then null else $deleted_at end)}')
  out=$(rpc upsert_spec "$payload") || warn "upsert_spec failed for local_id $(jq '.id' <<<"$row"): $out"
done

sqlite3 -json "$DB_PATH" "SELECT sl.id, f.name AS feature_name, sl.feature_id, sl.agent, sl.plan, sl.next_step, sl.changes,
  sl.verification, sl.closure, sl.started_at, sl.closed_at, sl.paused_at, sl.deleted_at
  FROM session_log sl LEFT JOIN features f ON f.id = sl.feature_id
  WHERE sl.project_id='$(sql_escape "$pid")';" | jq -c '.[]' | while IFS= read -r row; do
  sid=$(jq '.id' <<<"$row")
  payload=$(jq -n --arg slug "$PROJECT_SLUG" \
    --argjson local_id "$sid" \
    --arg feature_name "$(jq -r '.feature_name // ""' <<<"$row")" \
    --arg agent "$(jq -r '.agent' <<<"$row")" \
    --argjson plan "$(jq -c 'if .plan then (.plan | fromjson) else [] end' <<<"$row")" \
    --argjson next_step "$(jq -c 'if .next_step then (.next_step | fromjson) else [] end' <<<"$row")" \
    --argjson changes "$(jq -c 'if .changes then (.changes | fromjson) else [] end' <<<"$row")" \
    --arg verification "$(jq -r '.verification // ""' <<<"$row")" \
    --arg closure "$(jq -r '.closure // ""' <<<"$row")" \
    --arg started_at "$(jq -r '.started_at' <<<"$row")" \
    --arg closed_at "$(jq -r '.closed_at // ""' <<<"$row")" \
    --arg paused_at "$(jq -r '.paused_at // ""' <<<"$row")" \
    --arg deleted_at "$(jq -r '.deleted_at // ""' <<<"$row")" \
    --argjson feature_local_id "$(jq '.feature_id // null' <<<"$row")" \
    '{p_project_slug:$slug, p_local_id:$local_id,
      p_feature_name: (if $feature_name == "" then null else $feature_name end),
      p_feature_local_id:$feature_local_id,
      p_agent:$agent, p_plan:$plan, p_next_step:$next_step, p_changes:$changes,
      p_verification:$verification, p_closure:$closure, p_started_at:$started_at,
      p_closed_at: (if $closed_at == "" then null else $closed_at end),
      p_paused_at: (if $paused_at == "" then null else $paused_at end),
      p_deleted_at: (if $deleted_at == "" then null else $deleted_at end)}')
  out=$(rpc upsert_session "$payload") || warn "upsert_session failed for local_id $sid: $out"

  sqlite3 -json "$DB_PATH" "SELECT id, entry, created_at, deleted_at FROM session_log_entries WHERE session_id=$sid;" \
    | jq -c '.[]' | while IFS= read -r erow; do
    epayload=$(jq -n --arg slug "$PROJECT_SLUG" --argjson session_local_id "$sid" \
      --argjson local_id "$(jq '.id' <<<"$erow")" \
      --arg entry "$(jq -r '.entry' <<<"$erow")" \
      --arg created_at "$(jq -r '.created_at' <<<"$erow")" \
      --arg deleted_at "$(jq -r '.deleted_at // ""' <<<"$erow")" \
      '{p_project_slug:$slug, p_session_local_id:$session_local_id, p_local_id:$local_id, p_entry:$entry,
        p_created_at:$created_at, p_deleted_at: (if $deleted_at == "" then null else $deleted_at end)}')
    rpc upsert_session_entry "$epayload" >/dev/null || warn "upsert_session_entry failed for local_id $(jq '.id' <<<"$erow")"
  done
done

# Agent runs after sessions: upsert_agent_run resolves session/feature by
# their local ids, so those rows must already be mirrored. A mirror without
# migration 0004 just [WARN]s here (one per row, like the other steps).
# source_path stays local: it is a path on this machine, meaningless (and
# identifying) in a shared mirror.
sqlite3 -json "$DB_PATH" "SELECT id, session_id, feature_id, runtime, agent_role, label, external_id,
  parent_external_id, spawn_depth, model, started_at, finished_at, duration_seconds, input_tokens,
  cache_read_tokens, cache_write_tokens, output_tokens, reasoning_tokens, total_tokens, deleted_at
  FROM agent_runs WHERE project_id='$(sql_escape "$pid")';" | jq -c '.[]' | while IFS= read -r row; do
  payload=$(jq -c --arg slug "$PROJECT_SLUG" '{p_project_slug:$slug, p_local_id:.id,
    p_session_local_id:.session_id, p_feature_local_id:.feature_id, p_runtime:.runtime,
    p_agent_role:.agent_role, p_label:.label, p_external_id:.external_id,
    p_parent_external_id:.parent_external_id, p_spawn_depth:.spawn_depth, p_model:.model,
    p_started_at:.started_at, p_finished_at:.finished_at, p_duration_seconds:.duration_seconds,
    p_input_tokens:.input_tokens, p_cache_read_tokens:.cache_read_tokens,
    p_cache_write_tokens:.cache_write_tokens, p_output_tokens:.output_tokens,
    p_reasoning_tokens:.reasoning_tokens, p_total_tokens:.total_tokens,
    p_deleted_at:.deleted_at}' <<<"$row")
  out=$(rpc upsert_agent_run "$payload") || warn "upsert_agent_run failed for local_id $(jq '.id' <<<"$row"): $out"
done

ok "mirror sync complete"
