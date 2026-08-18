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
#   add-feature --name <slug> --title <t> [--description <d>] [--acceptance <item...>]
#                                              create a single pending feature directly (no seed file) — for
#                                              ad-hoc tasks the leader creates on the spot, no matching pending
#                                              feature existed
#   link-notion <feature_number|name> <notion_page_id>
#                                              stamp a feature's source_id so claim/log-out's existing best-effort
#                                              Notion push-back starts applying to it (pairs with notion-create-feature
#                                              for the ad-hoc-task-to-Notion flow — see AGENTS.md)
#   import-sessions <seed.json>               bulk-load historical (closed) sessions
#   notion-diff                               (stdin: JSON array of {source_id,...}) prints only entries not yet imported
#   notion-import <file.json>                 import entries as pending features, auto-numbered, source_id stored
#   claim [--agent NAME] [TARGET]             claim TARGET (number or name), or lowest pending if omitted
#                                              (best-effort: also pushes notion_status_in_progress to the
#                                              feature's source Notion page, if it has a source_id)
#   append-log <entry> [--agent NAME]         append a line to the current open session's log
#   set-plan <item> [item...]                 replace the current open session's plan
#   set-next-step <item> [item...]            replace the current open session's next_step
#   log-out --changes <item...> --verification <text> --closure <text>
#                                              close the open session and mark its feature done
#                                              (best-effort: also pushes notion_status_done to the
#                                              feature's source Notion page, if it has a source_id)
#   delete-feature <TARGET>                   soft-delete a feature (sets deleted_at)
#   status                                     print current project/feature/session state
#   snapshot                                   regenerate state/*.md from harness.db
#   sync                                       best-effort push to the Postgres mirror
#   notion-check                               best-effort curl+jq query for new Notion tasks (prints notion-diff-ready JSON)
#   notion-create-feature --project <slug> --title <t> --description <d> [--acceptance <a>] [--status <s>]
#                                              create a new Notion page (feature card) in a project — for cross-
#                                              project dependency requests; fails loudly (not a [WARN]) since the
#                                              caller must not proceed to block a feature on a card that wasn't
#                                              actually created
#   block <TARGET> <reason...>                mark an in_progress feature blocked (leaves its session open)
#   unblock <TARGET>                          mark a blocked feature in_progress again, resuming its open session
#   reopen <TARGET> <reason...>               mark a done feature in_progress again, opening a fresh session
#                                              (e.g. it was closed without meeting a checkpoint) — logs a
#                                              REOPENED: <reason> entry on the new session for the audit trail
#   check-blockers                            best-effort: for every blocked feature with a BLOCKED_ON note,
#                                              check the referenced sibling project's harness.db directly

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

cmd_add_feature() {
  local name="" title="" desc="" accept_items=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --description) desc="$2"; shift 2 ;;
      --acceptance)
        shift
        while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
          accept_items+=("$1"); shift
        done
        ;;
      *) fail "unknown argument: $1"; exit 1 ;;
    esac
  done
  if [ -z "$name" ] || [ -z "$title" ]; then
    fail "usage: add-feature --name <slug> --title <text> [--description <text>] [--acceptance <item...>]"
    exit 1
  fi

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local next_number
  next_number=$(db "SELECT COALESCE(MAX(feature_number), 0) + 1 FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL;")
  local accept; accept="$(json_array "${accept_items[@]:-}")"
  local now; now="$(now_iso)"

  db_exec "INSERT INTO features (project_id, feature_number, name, title, description, acceptance, status, created_at, updated_at)
VALUES ('$(sql_escape "$pid")', $next_number, '$(sql_escape "$name")', '$(sql_escape "$title")', '$(sql_escape "$desc")', '$(sql_escape "$accept")', 'pending', '$now', '$now');"
  ok "added feature $next_number: $name (pending)"
}

cmd_link_notion() {
  local target="${1:?usage: link-notion <feature_number|name> <notion_page_id>}"
  local page_id="${2:?usage: link-notion <feature_number|name> <notion_page_id>}"

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local now; now="$(now_iso)"

  local where
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    where="feature_number=$target"
  else
    where="name='$(sql_escape "$target")'"
  fi

  # No status/session-state check here (unlike claim/block/unblock) — linking a
  # source_id is valid at any feature status, since it's purely metadata used by
  # claim/log-out's existing best-effort Notion push-back, not a lifecycle step.
  local updated
  updated=$(sqlite3 -json "$DB_PATH" "UPDATE features SET source_id='$(sql_escape "$page_id")', updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND $where
RETURNING id, feature_number, name, source_id;" 2>&1)
  if [ $? -ne 0 ]; then
    fail "link-notion failed: $updated"
    exit 1
  fi
  if [ "$updated" = "[]" ] || [ -z "$updated" ]; then
    fail "not linkable: no matching feature $target"
    exit 1
  fi
  ok "linked feature $target to Notion page $page_id"
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
  updated=$(sqlite3 -json "$DB_PATH" "$update_sql RETURNING id, feature_number, name, title, source_id;" 2>&1)
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

  local source_id; source_id=$(jq -r '.[0].source_id // empty' <<<"$updated")
  if [ -n "$source_id" ]; then
    bash "$SCRIPT_DIR/notion_set_status.sh" "$source_id" "$(config '.notion_status_in_progress' 'In Progress')"
  fi
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

  local source_id; source_id=$(db "SELECT source_id FROM features WHERE id = (SELECT feature_id FROM session_log WHERE id=$sid);")
  if [ -n "$source_id" ]; then
    bash "$SCRIPT_DIR/notion_set_status.sh" "$source_id" "$(config '.notion_status_done' 'Done')"
  fi
}

cmd_block() {
  local target="${1:?usage: block <feature_number|name> <reason...>}"; shift
  local reason="$*"
  [ -n "$reason" ] || { fail "usage: block <feature_number|name> <reason...>"; exit 1; }

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local now; now="$(now_iso)"

  local where
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    where="feature_number=$target"
  else
    where="name='$(sql_escape "$target")'"
  fi

  # Same "UPDATE ... RETURNING or fail cleanly" shape as cmd_claim — only an
  # in_progress feature can be blocked (mirrors: only a pending one can be
  # claimed). The session stays open (no closed_at write) — same "leave it
  # for the next session to pick up" idiom AGENTS.md already documents for
  # getting stuck, just with status='blocked' instead of 'in_progress'.
  local updated
  updated=$(sqlite3 -json "$DB_PATH" "UPDATE features SET status='blocked', updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND status='in_progress' AND deleted_at IS NULL AND $where
RETURNING id, feature_number, name, title;" 2>&1)
  if [ $? -ne 0 ]; then
    fail "block failed: $updated"
    exit 1
  fi
  if [ "$updated" = "[]" ] || [ -z "$updated" ]; then
    fail "not blockable: no matching in_progress feature"
    exit 1
  fi

  local sid; sid="$(current_session_id)"
  if [ -n "$sid" ]; then
    db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "$reason")', '$now');"
  fi

  ok "blocked: $(jq -r '.[0] | "\(.feature_number) \(.name) — \(.title)"' <<<"$updated")"
}

cmd_unblock() {
  local target="${1:?usage: unblock <feature_number|name>}"

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local now; now="$(now_iso)"

  local where
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    where="feature_number=$target"
  else
    where="name='$(sql_escape "$target")'"
  fi

  # Respects the same one_in_progress_per_project unique index cmd_claim
  # does — if another feature is already in_progress, the UPDATE fails and
  # we report that clearly instead of surfacing SQLite's raw constraint error.
  local updated
  updated=$(sqlite3 -json "$DB_PATH" "UPDATE features SET status='in_progress', updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND status='blocked' AND deleted_at IS NULL AND $where
RETURNING id, feature_number, name, title;" 2>&1)
  if [ $? -ne 0 ]; then
    fail "unblock failed (is another feature already in_progress?): $updated"
    exit 1
  fi
  if [ "$updated" = "[]" ] || [ -z "$updated" ]; then
    fail "not unblockable: no matching blocked feature"
    exit 1
  fi
  ok "unblocked: $(jq -r '.[0] | "\(.feature_number) \(.name) — \(.title)"' <<<"$updated")"
}

cmd_reopen() {
  local target="${1:?usage: reopen <feature_number|name> <reason...>}"; shift
  local reason="$*"
  [ -n "$reason" ] || { fail "usage: reopen <feature_number|name> <reason...>"; exit 1; }

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local now; now="$(now_iso)"

  local where
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    where="feature_number=$target"
  else
    where="name='$(sql_escape "$target")'"
  fi

  # Same "UPDATE ... RETURNING or fail cleanly" shape as cmd_claim/cmd_unblock — only a
  # done feature can be reopened, and the same one_in_progress_per_project unique index
  # applies (surfaced as the same "is another feature already in_progress?" hint).
  local updated
  updated=$(sqlite3 -json "$DB_PATH" "UPDATE features SET status='in_progress', updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND status='done' AND deleted_at IS NULL AND $where
RETURNING id, feature_number, name, title, source_id;" 2>&1)
  if [ $? -ne 0 ]; then
    fail "reopen failed (is another feature already in_progress?): $updated"
    exit 1
  fi
  if [ "$updated" = "[]" ] || [ -z "$updated" ]; then
    fail "not reopenable: no matching done feature"
    exit 1
  fi
  local feature_id; feature_id=$(jq -r '.[0].id' <<<"$updated")

  # Opens a fresh session (the one from the original log-out is already
  # closed_at-stamped) — mirrors cmd_claim's session INSERT.
  local agent="${HARNESS_AGENT:-unknown}"
  db_exec "INSERT INTO session_log (project_id, feature_id, agent, started_at)
VALUES ('$(sql_escape "$pid")', $feature_id, '$(sql_escape "$agent")', '$now');"
  local sid; sid="$(current_session_id)"
  db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "REOPENED: $reason")', '$now');"

  ok "reopened: $(jq -r '.[0] | "\(.feature_number) \(.name) — \(.title)"' <<<"$updated")"

  local source_id; source_id=$(jq -r '.[0].source_id // empty' <<<"$updated")
  if [ -n "$source_id" ]; then
    bash "$SCRIPT_DIR/notion_set_status.sh" "$source_id" "$(config '.notion_status_in_progress' 'In Progress')"
  fi
}

cmd_notion_create_feature() {
  bash "$SCRIPT_DIR/notion_create_feature.sh" "$@"
}

cmd_check_blockers() {
  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }

  local blocked_features
  blocked_features=$(sqlite3 -json "$DB_PATH" "SELECT id, feature_number, name, title FROM features
WHERE project_id='$(sql_escape "$pid")' AND status='blocked' AND deleted_at IS NULL;")

  if [ "$blocked_features" = "[]" ] || [ -z "$blocked_features" ]; then
    ok "no blocked features"
    return 0
  fi

  jq -c '.[]' <<<"$blocked_features" | while IFS= read -r feat; do
    local fid fnum fname ftitle
    fid=$(jq -r '.id' <<<"$feat")
    fnum=$(jq -r '.feature_number' <<<"$feat")
    fname=$(jq -r '.name' <<<"$feat")
    ftitle=$(jq -r '.title' <<<"$feat")

    # Most recent BLOCKED_ON note across any session logged for this
    # feature (block writes one, see cmd_block's caller in the
    # cross-project-dependency flow documented in AGENTS.md).
    local note
    note=$(sqlite3 "$DB_PATH" "SELECT sle.entry FROM session_log_entries sle
JOIN session_log sl ON sl.id = sle.session_id
WHERE sl.feature_id=$fid AND sle.deleted_at IS NULL AND sle.entry LIKE '%BLOCKED_ON:%'
ORDER BY sle.created_at DESC LIMIT 1;")

    if [ -z "$note" ]; then
      warn "$fnum $fname is blocked but has no BLOCKED_ON note — can't check automatically"
      continue
    fi

    local target_path target_feature target_url
    target_path=$(sed -n 's/.*BLOCKED_ON: path=\([^ ]*\).*/\1/p' <<<"$note")
    target_feature=$(sed -n 's/.*feature=\([^ ]*\).*/\1/p' <<<"$note")
    target_url=$(sed -n 's/.*notion_page=\([^ ]*\).*/\1/p' <<<"$note")

    if [ -z "$target_path" ] || [ -z "$target_feature" ]; then
      warn "$fnum $fname has a malformed BLOCKED_ON note — can't check automatically"
      continue
    fi

    if [ ! -f "$target_path/harness.db" ]; then
      warn "$fnum $fname: target harness.db not found at $target_path — can't check"
      continue
    fi

    # Direct query against the sibling project's harness.db, not the Notion
    # API — faster, doesn't depend on that project's own Notion push-back
    # having succeeded, and harness.db is already this toolkit's source of
    # truth everywhere else.
    local target_status
    target_status=$(sqlite3 "$target_path/harness.db" "SELECT status FROM features WHERE name='$(sql_escape "$target_feature")' AND deleted_at IS NULL LIMIT 1;")

    if [ -z "$target_status" ]; then
      warn "$fnum $fname: no feature named '$target_feature' found in $target_path — can't check"
      continue
    fi

    if [ "$target_status" = "done" ]; then
      ok "$fnum $fname: dependency '$target_feature' is done — run 'unblock $fnum' to resume"
    else
      warn "$fnum $fname: dependency '$target_feature' is still '$target_status'${target_url:+ ($target_url)}"
    fi
  done
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

cmd_notion_check() {
  bash "$SCRIPT_DIR/notion_check.sh"
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    import-features) cmd_import_features "$@" ;;
    add-feature) cmd_add_feature "$@" ;;
    link-notion) cmd_link_notion "$@" ;;
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
    notion-check) cmd_notion_check ;;
    notion-create-feature) cmd_notion_create_feature "$@" ;;
    block) cmd_block "$@" ;;
    unblock) cmd_unblock "$@" ;;
    reopen) cmd_reopen "$@" ;;
    check-blockers) cmd_check_blockers ;;
    *)
      echo "usage: harness.sh <import-features|add-feature|link-notion|import-sessions|notion-diff|notion-import|claim|append-log|set-plan|set-next-step|log-out|status|snapshot|sync|notion-check|notion-create-feature|block|unblock|reopen|check-blockers> [args...]" >&2
      exit 1
      ;;
  esac
}

main "$@"
