#!/usr/bin/env bash
# harness.sh — the single entry point agents use to read/write harness state.
#
# SQLite (harness.db) is the primary source of truth. Every subcommand here
# operates on it directly; the generated markdown snapshot (state/) and the
# optional Postgres/Supabase mirror are downstream of it, never the other
# way around. Prerequisites: sqlite3, jq; curl only if a mirror is configured.
#
# Usage: scripts/harness.sh <subcommand> [args...]
#   import-features <seed.json>              bulk-load features (status defaults to pending)
#   import-sessions <seed.json>               bulk-load historical (closed) sessions
#   notion-diff                               (stdin: JSON array of {source_id,...}) prints only entries not yet imported
#   notion-import <file.json>                 import entries as pending features, auto-numbered, source_id stored
#   claim [--agent NAME] [TARGET]             claim TARGET (number or name), or lowest pending if omitted
#   append-log <entry> [--agent NAME]         append a line to the current open session's log
#   set-plan <item> [item...]                 replace the current open session's plan
#   set-next-step <item> [item...]            replace the current open session's next_step
#   log-out --changes <item...> --verification <text> --closure <text>
#                                              close the open session and mark its feature done
#   delete-feature <TARGET>                   soft-delete a feature (sets deleted_at)
#   status                                     print current project/feature/session state
#   snapshot                                   regenerate state/*.md from harness.db
#   sync                                       best-effort push to the Postgres mirror

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

project_id() {
  db "SELECT id FROM projects WHERE slug = '$(sql_escape "$PROJECT_SLUG")' AND deleted_at IS NULL LIMIT 1;"
}

cmd_import_features() {
  local seed_file="${1:?usage: import-features <seed.json>}"
  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }

  jq -c '.[]' "$seed_file" | while IFS= read -r item; do
    local number name title desc status accept now
    number=$(jq -r '.feature_number' <<<"$item")
    name=$(jq -r '.name' <<<"$item")
    title=$(jq -r '.title' <<<"$item")
    desc=$(jq -r '.description // ""' <<<"$item")
    status=$(jq -r '.status // "pending"' <<<"$item")
    accept=$(jq -c '.acceptance // []' <<<"$item")
    now="$(now_iso)"
    db_exec "INSERT INTO features (project_id, feature_number, name, title, description, acceptance, status, created_at, updated_at)
VALUES ('$(sql_escape "$pid")', $number, '$(sql_escape "$name")', '$(sql_escape "$title")', '$(sql_escape "$desc")', '$(sql_escape "$accept")', '$(sql_escape "$status")', '$now', '$now');"
  done
  ok "imported features from $seed_file"
}

cmd_import_sessions() {
  local seed_file="${1:?usage: import-sessions <seed.json>}"
  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }

  jq -c '.[]' "$seed_file" | while IFS= read -r item; do
    local feature_name agent plan next_step changes verification closure started_at closed_at fid_expr
    feature_name=$(jq -r '.feature_name // empty' <<<"$item")
    agent=$(jq -r '.agent // "unknown"' <<<"$item")
    plan=$(jq -c '.plan // []' <<<"$item")
    next_step=$(jq -c '.next_step // []' <<<"$item")
    changes=$(jq -c '.changes // []' <<<"$item")
    verification=$(jq -r '.verification // ""' <<<"$item")
    closure=$(jq -r '.closure // ""' <<<"$item")
    started_at=$(jq -r '.started_at // empty' <<<"$item")
    closed_at=$(jq -r '.closed_at // empty' <<<"$item")
    [ -n "$started_at" ] || started_at="$(now_iso)"

    if [ -n "$feature_name" ]; then
      fid_expr="(SELECT id FROM features WHERE project_id='$(sql_escape "$pid")' AND name='$(sql_escape "$feature_name")' AND deleted_at IS NULL)"
    else
      fid_expr="NULL"
    fi

    db_exec "INSERT INTO session_log (project_id, feature_id, agent, plan, next_step, changes, verification, closure, started_at, closed_at)
VALUES ('$(sql_escape "$pid")', $fid_expr, '$(sql_escape "$agent")', '$(sql_escape "$plan")', '$(sql_escape "$next_step")', '$(sql_escape "$changes")', '$(sql_escape "$verification")', '$(sql_escape "$closure")', '$(sql_escape "$started_at")', $( [ -n "$closed_at" ] && echo "'$(sql_escape "$closed_at")'" || echo NULL ));"
  done
  ok "imported sessions from $seed_file"
}

cmd_notion_diff() {
  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local input; input="$(cat)"
  local existing_raw
  existing_raw="$(db "SELECT source_id FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND source_id IS NOT NULL;")"
  local existing_json
  existing_json="$(jq -R -s -c 'split("\n") | map(select(length > 0))' <<<"$existing_raw")"
  jq -c --argjson existing "$existing_json" \
    '[.[] | select((.source_id as $s | $existing | index($s)) == null)]' <<<"$input"
}

cmd_notion_import() {
  local seed_file="${1:?usage: notion-import <file.json>}"
  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local next_number
  next_number=$(db "SELECT COALESCE(MAX(feature_number), 0) + 1 FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL;")

  jq -c '.[]' "$seed_file" | while IFS= read -r item; do
    local name title desc accept source_id now source_id_sql
    name=$(jq -r '.name' <<<"$item")
    title=$(jq -r '.title' <<<"$item")
    desc=$(jq -r '.description // ""' <<<"$item")
    accept=$(jq -c '.acceptance // []' <<<"$item")
    source_id=$(jq -r '.source_id // empty' <<<"$item")
    now="$(now_iso)"
    if [ -n "$source_id" ]; then
      source_id_sql="'$(sql_escape "$source_id")'"
    else
      source_id_sql="NULL"
    fi
    db_exec "INSERT INTO features (project_id, feature_number, name, title, description, acceptance, status, source_id, created_at, updated_at)
VALUES ('$(sql_escape "$pid")', $next_number, '$(sql_escape "$name")', '$(sql_escape "$title")', '$(sql_escape "$desc")', '$(sql_escape "$accept")', 'pending', $source_id_sql, '$now', '$now');"
    next_number=$((next_number + 1))
  done
  ok "imported notion tasks from $seed_file"
}

cmd_claim() {
  local agent="${HARNESS_AGENT:-unknown}"
  local target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) agent="$2"; shift 2 ;;
      *) target="$1"; shift ;;
    esac
  done

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local now; now="$(now_iso)"

  local update_sql
  if [ -n "$target" ]; then
    if [[ "$target" =~ ^[0-9]+$ ]]; then
      update_sql="UPDATE features SET status='in_progress', updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND status='pending' AND deleted_at IS NULL AND feature_number=$target"
    else
      update_sql="UPDATE features SET status='in_progress', updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND status='pending' AND deleted_at IS NULL AND name='$(sql_escape "$target")'"
    fi
  else
    update_sql="UPDATE features SET status='in_progress', updated_at='$now'
WHERE id = (SELECT id FROM features WHERE project_id='$(sql_escape "$pid")' AND status='pending' AND deleted_at IS NULL ORDER BY feature_number LIMIT 1)"
  fi

  # SQLite has no RAISE()/control flow outside triggers, so "claim exactly
  # one pending row or fail cleanly" is done as UPDATE ... RETURNING: if it
  # returns no row, nothing matched and there's nothing to roll back.
  local updated
  updated=$(sqlite3 -json "$DB_PATH" "$update_sql RETURNING id, feature_number, name, title;" 2>&1)
  if [ $? -ne 0 ]; then
    fail "claim failed: $updated"
    exit 1
  fi
  if [ "$updated" = "[]" ] || [ -z "$updated" ]; then
    fail "not claimable: no matching pending feature"
    exit 1
  fi
  local feature_id; feature_id=$(jq -r '.[0].id' <<<"$updated")

  db_exec "INSERT INTO session_log (project_id, feature_id, agent, started_at)
VALUES ('$(sql_escape "$pid")', $feature_id, '$(sql_escape "$agent")', '$now');"
  ok "claimed: $(jq -r '.[0] | "\(.feature_number) \(.name) — \(.title)"' <<<"$updated")"
}

current_session_id() {
  local pid; pid="$(project_id)"
  db "SELECT id FROM session_log WHERE project_id='$(sql_escape "$pid")' AND closed_at IS NULL AND deleted_at IS NULL LIMIT 1;"
}

cmd_append_log() {
  local entry="${1:?usage: append-log <entry>}"
  local sid; sid="$(current_session_id)"
  [ -n "$sid" ] || { fail "no open session — run 'claim' first"; exit 1; }
  db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "$entry")', '$(now_iso)');"
  ok "appended log entry to session $sid"
}

cmd_set_array_field() {
  local field="$1"; shift
  local sid; sid="$(current_session_id)"
  [ -n "$sid" ] || { fail "no open session — run 'claim' first"; exit 1; }
  local arr; arr=$(json_array "$@")
  db_exec "UPDATE session_log SET $field = '$(sql_escape "$arr")' WHERE id=$sid;"
  ok "updated $field on session $sid"
}

cmd_log_out() {
  local changes=() verification="" closure=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --changes)
        shift
        while [ $# -gt 0 ] && [ "$1" != "--verification" ] && [ "$1" != "--closure" ]; do
          changes+=("$1"); shift
        done
        ;;
      --verification) verification="$2"; shift 2 ;;
      --closure) closure="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local sid; sid="$(current_session_id)"
  [ -n "$sid" ] || { fail "no open session to log out"; exit 1; }
  local changes_json; changes_json=$(json_array "${changes[@]:-}")
  local now; now="$(now_iso)"

  sqlite3 "$DB_PATH" <<SQL
.bail on
BEGIN;
UPDATE session_log SET changes='$(sql_escape "$changes_json")', verification='$(sql_escape "$verification")',
  closure='$(sql_escape "$closure")', closed_at='$now' WHERE id=$sid;
UPDATE features SET status='done', updated_at='$now'
  WHERE id = (SELECT feature_id FROM session_log WHERE id=$sid);
COMMIT;
SQL
  ok "session $sid logged out"
}

cmd_status() {
  local pid; pid="$(project_id)"
  echo "project: $PROJECT_SLUG ($pid)"
  echo "--- features ---"
  db -header -column "SELECT feature_number, name, status FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL ORDER BY feature_number;"
  echo "--- open session ---"
  db -header -column "SELECT id, agent, started_at FROM session_log WHERE project_id='$(sql_escape "$pid")' AND closed_at IS NULL AND deleted_at IS NULL;"
}

cmd_delete_feature() {
  local target="${1:?usage: delete-feature <feature_number|name>}"
  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local now; now="$(now_iso)"
  local where
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    where="feature_number=$target"
  else
    where="name='$(sql_escape "$target")'"
  fi
  db_exec "UPDATE features SET deleted_at='$now', updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND $where;"
  ok "soft-deleted feature $target"
}

cmd_snapshot() {
  bash "$SCRIPT_DIR/snapshot.sh"
}

cmd_sync() {
  bash "$SCRIPT_DIR/sync_postgres.sh"
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    import-features) cmd_import_features "$@" ;;
    import-sessions) cmd_import_sessions "$@" ;;
    notion-diff) cmd_notion_diff "$@" ;;
    notion-import) cmd_notion_import "$@" ;;
    claim) cmd_claim "$@" ;;
    append-log) cmd_append_log "$@" ;;
    set-plan) cmd_set_array_field plan "$@" ;;
    set-next-step) cmd_set_array_field next_step "$@" ;;
    log-out) cmd_log_out "$@" ;;
    delete-feature) cmd_delete_feature "$@" ;;
    status) cmd_status ;;
    snapshot) cmd_snapshot ;;
    sync) cmd_sync ;;
    *)
      echo "usage: harness.sh <import-features|import-sessions|notion-diff|notion-import|claim|append-log|set-plan|set-next-step|log-out|status|snapshot|sync> [args...]" >&2
      exit 1
      ;;
  esac
}

main "$@"
