#!/usr/bin/env bash
# harness.sh — the single entry point agents use to read/write harness state.
#
# SQLite (harness.db) is the primary source of truth. Every subcommand here
# operates on it directly; the generated markdown snapshot (state/) and the
# optional Postgres/Supabase mirror are downstream of it, never the other
# way around. Prerequisites: sqlite3, jq; curl only if a mirror is configured.
#
# Usage: scripts/harness.sh <subcommand> [args...]
#   import-features <seed.json>              bulk-load features (status defaults to pending; optional
#                                              "sdd": true per item opts it into spec-driven development)
#   add-feature --name <slug> --title <t> [--description <d>] [--acceptance <item...>] [--sdd]
#                                              create a single pending feature directly (no seed file) — for
#                                              ad-hoc tasks the leader creates on the spot, no matching pending
#                                              feature existed; --sdd requires an approved spec before claim
#   link-notion <feature_number|name> <notion_page_id>
#                                              stamp a feature's source_id so claim/log-out's existing best-effort
#                                              Notion push-back starts applying to it (pairs with notion-create-feature
#                                              for the ad-hoc-task-to-Notion flow — see AGENTS.md)
#   import-sessions <seed.json>               bulk-load historical (closed) sessions
#   notion-diff                               (stdin: JSON array of {source_id,...}) prints only entries not yet imported
#   notion-import <file.json>                 import entries as pending features, auto-numbered, source_id stored
#                                              (optional "sdd" checkbox property carried through if present)
#   claim-spec [--agent NAME] [TARGET]        claim an sdd=1 pending feature for spec drafting (spec_author only —
#                                              see docs/specs.md); moves it to spec_drafting and opens a session
#   mark-spec-ready                           close the current spec-drafting session: verifies
#                                              specs/<name>/{requirements,design,tasks}.md exist, records
#                                              requirement/task counts, moves the feature to spec_ready
#                                              (best-effort: pushes notion_status_spec_ready if source_id is set)
#   approve-spec <TARGET> [--by NAME]         record human approval of a spec_ready feature's spec (leader-only,
#                                              run immediately after the user approves in conversation) — this is
#                                              the actual DB-enforced precondition claim checks for sdd=1 features
#   claim [--agent NAME] [TARGET]             claim TARGET (number or name), or lowest claimable if omitted.
#                                              For sdd=0 features: from pending. For sdd=1 features: only from
#                                              spec_ready with an approved spec (see approve-spec) and the 3 spec
#                                              files still present on disk.
#                                              (best-effort: also pushes notion_status_in_progress to the
#                                              feature's source Notion page, if it has a source_id)
#   append-log <entry> [--agent NAME]         append a line to the current open session's log
#   set-plan <item> [item...]                 replace the current open session's plan
#   set-next-step <item> [item...]            replace the current open session's next_step
#   record-review <approved|changes-requested> [--by NAME] [--notes TEXT]
#                                              record the reviewer's verdict on the current open session
#                                              (reviewer-only, run as the mechanical last step of its own
#                                              protocol) — log-out refuses to close a session whose latest
#                                              verdict isn't 'approved'; a later call overwrites the verdict,
#                                              so a re-review after CHANGES_REQUESTED just records over it
#   log-out --changes <item...> --verification <text> --closure <text>
#                                              close the open session and mark its feature done — refuses
#                                              unless record-review has recorded 'approved' on this session
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
    local number name title desc status accept sdd now
    number=$(jq -r '.feature_number' <<<"$item")
    name=$(jq -r '.name' <<<"$item")
    title=$(jq -r '.title' <<<"$item")
    desc=$(jq -r '.description // ""' <<<"$item")
    status=$(jq -r '.status // "pending"' <<<"$item")
    accept=$(jq -c '.acceptance // []' <<<"$item")
    sdd=$(jq -r 'if (.sdd == true or .sdd == 1) then 1 else 0 end' <<<"$item")
    now="$(now_iso)"
    db_exec "INSERT INTO features (project_id, feature_number, name, title, description, acceptance, sdd, status, created_at, updated_at)
VALUES ('$(sql_escape "$pid")', $number, '$(sql_escape "$name")', '$(sql_escape "$title")', '$(sql_escape "$desc")', '$(sql_escape "$accept")', $sdd, '$(sql_escape "$status")', '$now', '$now');"
  done
  ok "imported features from $seed_file"
}

cmd_add_feature() {
  local name="" title="" desc="" accept_items=() sdd=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --description) desc="$2"; shift 2 ;;
      --sdd) sdd=1; shift ;;
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
    fail "usage: add-feature --name <slug> --title <text> [--description <text>] [--acceptance <item...>] [--sdd]"
    exit 1
  fi

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local next_number
  next_number=$(db "SELECT COALESCE(MAX(feature_number), 0) + 1 FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL;")
  local accept; accept="$(json_array "${accept_items[@]:-}")"
  local now; now="$(now_iso)"

  db_exec "INSERT INTO features (project_id, feature_number, name, title, description, acceptance, sdd, status, created_at, updated_at)
VALUES ('$(sql_escape "$pid")', $next_number, '$(sql_escape "$name")', '$(sql_escape "$title")', '$(sql_escape "$desc")', '$(sql_escape "$accept")', $sdd, 'pending', '$now', '$now');"
  local sdd_note=""; [ "$sdd" = "1" ] && sdd_note=", sdd"
  ok "added feature $next_number: $name (pending$sdd_note)"
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
    local name title desc accept sdd source_id now source_id_sql
    name=$(jq -r '.name' <<<"$item")
    title=$(jq -r '.title' <<<"$item")
    desc=$(jq -r '.description // ""' <<<"$item")
    accept=$(jq -c '.acceptance // []' <<<"$item")
    sdd=$(jq -r 'if (.sdd == true or .sdd == 1) then 1 else 0 end' <<<"$item")
    source_id=$(jq -r '.source_id // empty' <<<"$item")
    now="$(now_iso)"
    if [ -n "$source_id" ]; then
      source_id_sql="'$(sql_escape "$source_id")'"
    else
      source_id_sql="NULL"
    fi
    db_exec "INSERT INTO features (project_id, feature_number, name, title, description, acceptance, sdd, status, source_id, created_at, updated_at)
VALUES ('$(sql_escape "$pid")', $next_number, '$(sql_escape "$name")', '$(sql_escape "$title")', '$(sql_escape "$desc")', '$(sql_escape "$accept")', $sdd, 'pending', $source_id_sql, '$now', '$now');"
    next_number=$((next_number + 1))
  done
  ok "imported notion tasks from $seed_file"
}

cmd_claim_spec() {
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

  # There is no unique index guarding open sessions (features' one_in_progress_per_project
  # only covers status='in_progress', not 'spec_drafting'), so the "one feature at a time"
  # rule has to be enforced here — otherwise accepting 'spec_drafting' below would let a
  # re-claim stack a second open session on the same feature.
  local open_sid; open_sid="$(current_session_id)"
  if [ -n "$open_sid" ]; then
    fail "a session is already open (id=$open_sid) — close it before claiming a spec"
    exit 1
  fi

  # 'spec_drafting' is accepted alongside 'pending' so an interrupted drafting session is
  # resumable: if the session was lost before mark-spec-ready ran, the feature is stranded
  # in spec_drafting and no other command can move it (claim-spec used to require 'pending',
  # mark-spec-ready needs an open session, reopen only takes 'done', unblock only 'blocked').
  # Re-claiming is idempotent — the status is already spec_drafting, and mark-spec-ready
  # already UPDATEs an existing spec row instead of inserting a duplicate.
  local update_sql
  if [ -n "$target" ]; then
    if [[ "$target" =~ ^[0-9]+$ ]]; then
      update_sql="UPDATE features SET status='spec_drafting', updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND status IN ('pending','spec_drafting') AND sdd=1 AND deleted_at IS NULL AND feature_number=$target"
    else
      update_sql="UPDATE features SET status='spec_drafting', updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND status IN ('pending','spec_drafting') AND sdd=1 AND deleted_at IS NULL AND name='$(sql_escape "$target")'"
    fi
  else
    update_sql="UPDATE features SET status='spec_drafting', updated_at='$now'
WHERE id = (SELECT id FROM features WHERE project_id='$(sql_escape "$pid")' AND status IN ('pending','spec_drafting') AND sdd=1 AND deleted_at IS NULL ORDER BY feature_number LIMIT 1)"
  fi

  local updated
  updated=$(sqlite3 -json "$DB_PATH" "$update_sql RETURNING id, feature_number, name, title;" 2>&1)
  if [ $? -ne 0 ]; then
    fail "claim-spec failed: $updated"
    exit 1
  fi
  if [ "$updated" = "[]" ] || [ -z "$updated" ]; then
    fail "not claimable for spec drafting: no matching pending/spec_drafting sdd=1 feature (already spec_ready or approved? or sdd not set — see 'add-feature --sdd')"
    exit 1
  fi
  local feature_id; feature_id=$(jq -r '.[0].id' <<<"$updated")

  db_exec "INSERT INTO session_log (project_id, feature_id, agent, started_at)
VALUES ('$(sql_escape "$pid")', $feature_id, '$(sql_escape "$agent")', '$now');"
  ok "claimed for spec drafting: $(jq -r '.[0] | "\(.feature_number) \(.name) — \(.title)"' <<<"$updated")"
}

cmd_mark_spec_ready() {
  local sid; sid="$(current_session_id)"
  [ -n "$sid" ] || { fail "no open session — run 'claim-spec' first"; exit 1; }

  local fid name status_now
  fid=$(db "SELECT feature_id FROM session_log WHERE id=$sid;")
  [ -n "$fid" ] || { fail "open session has no associated feature"; exit 1; }
  name=$(db "SELECT name FROM features WHERE id=$fid;")
  status_now=$(db "SELECT status FROM features WHERE id=$fid;")
  if [ "$status_now" != "spec_drafting" ]; then
    fail "feature $name is not in spec_drafting (status=$status_now) — mark-spec-ready only applies right after claim-spec"
    exit 1
  fi

  local spec_dir="specs/$name"
  for f in requirements.md design.md tasks.md; do
    [ -f "$spec_dir/$f" ] || { fail "cannot mark spec ready: missing $spec_dir/$f"; exit 1; }
  done

  local req_count task_count agent_str
  req_count=$(grep -cE '^## R[0-9]+' "$spec_dir/requirements.md" 2>/dev/null)
  task_count=$(grep -cE '^- \[[ xX]\] T[0-9]+' "$spec_dir/tasks.md" 2>/dev/null)
  agent_str=$(db "SELECT agent FROM session_log WHERE id=$sid;")

  local now; now="$(now_iso)"
  local existing_spec_id
  existing_spec_id=$(db "SELECT id FROM specs WHERE feature_id=$fid AND deleted_at IS NULL;")

  local spec_write_sql
  if [ -n "$existing_spec_id" ]; then
    spec_write_sql="UPDATE specs SET status='ready', requirements_count=$req_count, tasks_count=$task_count,
  drafted_by='$(sql_escape "$agent_str")', ready_at='$now', updated_at='$now' WHERE id=$existing_spec_id;"
  else
    spec_write_sql="INSERT INTO specs (feature_id, path, status, requirements_count, tasks_count, drafted_by, ready_at, created_at, updated_at)
VALUES ($fid, '$(sql_escape "$spec_dir")', 'ready', $req_count, $task_count, '$(sql_escape "$agent_str")', '$now', '$now', '$now');"
  fi

  sqlite3 "$DB_PATH" <<SQL
.bail on
BEGIN;
UPDATE session_log SET closed_at='$now' WHERE id=$sid;
UPDATE features SET status='spec_ready', updated_at='$now' WHERE id=$fid;
$spec_write_sql
COMMIT;
SQL
  ok "spec ready for review: $spec_dir (feature $fid, R=$req_count, T=$task_count)"

  local source_id; source_id=$(db "SELECT source_id FROM features WHERE id=$fid;")
  if [ -n "$source_id" ]; then
    bash "$SCRIPT_DIR/notion_set_status.sh" "$source_id" "$(config '.notion_status_spec_ready' 'Spec Ready')"
  fi
}

cmd_approve_spec() {
  local target="" by="user"
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) by="$2"; shift 2 ;;
      *) target="$1"; shift ;;
    esac
  done
  [ -n "$target" ] || { fail "usage: approve-spec <feature_number|name> [--by <name>]"; exit 1; }

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local now; now="$(now_iso)"

  local where
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    where="feature_number=$target"
  else
    where="name='$(sql_escape "$target")'"
  fi

  local fid
  fid=$(db "SELECT id FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND $where;")
  [ -n "$fid" ] || { fail "not approvable: no matching feature $target"; exit 1; }

  # UPDATE ... RETURNING against status='ready' is the actual gate here — a
  # second approve-spec, or one run before mark-spec-ready, matches nothing
  # and fails cleanly rather than silently re-stamping approved_at.
  local updated
  updated=$(sqlite3 -json "$DB_PATH" "UPDATE specs SET status='approved', approved_at='$now', approved_by='$(sql_escape "$by")', updated_at='$now'
WHERE feature_id=$fid AND status='ready' AND deleted_at IS NULL
RETURNING id, feature_id;" 2>&1)
  if [ $? -ne 0 ]; then
    fail "approve-spec failed: $updated"
    exit 1
  fi
  if [ "$updated" = "[]" ] || [ -z "$updated" ]; then
    fail "not approvable: no 'ready' spec found for feature $target (already approved, or not yet marked ready — see 'mark-spec-ready')"
    exit 1
  fi
  ok "approved spec for feature $target (by: $by)"
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

  # Resolve the row that would be targeted (by number/name, or lowest
  # pending/spec_ready) BEFORE attempting the UPDATE, purely to produce an
  # actionable error for sdd=1 features instead of a generic "not
  # claimable" — the actual enforcement lives in update_sql's WHERE below,
  # not here.
  local target_where
  if [ -n "$target" ]; then
    if [[ "$target" =~ ^[0-9]+$ ]]; then
      target_where="f.project_id='$(sql_escape "$pid")' AND f.deleted_at IS NULL AND f.feature_number=$target"
    else
      target_where="f.project_id='$(sql_escape "$pid")' AND f.deleted_at IS NULL AND f.name='$(sql_escape "$target")'"
    fi
  else
    target_where="f.project_id='$(sql_escape "$pid")' AND f.deleted_at IS NULL AND f.status IN ('pending','spec_ready') ORDER BY f.feature_number LIMIT 1"
  fi

  local check_row
  check_row=$(sqlite3 -json "$DB_PATH" "SELECT f.id, f.name, f.sdd, f.status, s.status AS spec_status
FROM features f LEFT JOIN specs s ON s.feature_id = f.id AND s.deleted_at IS NULL
WHERE $target_where;")

  if [ -n "$check_row" ] && [ "$check_row" != "[]" ]; then
    local sdd_flag status_now name_now spec_status
    sdd_flag=$(jq -r '.[0].sdd' <<<"$check_row")
    status_now=$(jq -r '.[0].status' <<<"$check_row")
    name_now=$(jq -r '.[0].name' <<<"$check_row")
    spec_status=$(jq -r '.[0].spec_status // "none"' <<<"$check_row")
    if [ "$sdd_flag" = "1" ]; then
      if [ "$status_now" = "pending" ] || [ "$status_now" = "spec_drafting" ]; then
        fail "feature $name_now requires an approved spec first (status=$status_now) — run 'claim-spec' then 'mark-spec-ready', get human approval, then 'approve-spec', then 'claim' (see docs/specs.md)"
        exit 1
      fi
      if [ "$status_now" = "spec_ready" ] && [ "$spec_status" != "approved" ]; then
        fail "feature $name_now has a drafted spec but it is not yet approved (spec status=$spec_status) — after the user approves it, run 'scripts/harness.sh approve-spec $name_now --by <name>', then claim"
        exit 1
      fi
      if [ "$status_now" = "spec_ready" ] && [ "$spec_status" = "approved" ]; then
        for f in requirements.md design.md tasks.md; do
          [ -f "specs/$name_now/$f" ] || { fail "feature $name_now's spec is approved but specs/$name_now/$f is missing on disk — cannot claim"; exit 1; }
        done
      fi
    fi
  fi

  # The real enforcement: sdd=0 rows can only come from 'pending'; sdd=1 rows
  # additionally require a specs row already flipped to 'approved' by
  # approve-spec — encoded directly in the WHERE of the atomic UPDATE, not
  # just in the check_row precheck above, so this can't be bypassed by a
  # stale/missing precheck.
  local sdd_gate="(f.sdd = 0 AND f.status = 'pending') OR (f.sdd = 1 AND f.status = 'spec_ready' AND f.id IN (SELECT feature_id FROM specs WHERE status = 'approved' AND deleted_at IS NULL))"

  local update_sql
  if [ -n "$target" ]; then
    if [[ "$target" =~ ^[0-9]+$ ]]; then
      update_sql="UPDATE features SET status='in_progress', updated_at='$now'
WHERE id = (SELECT f.id FROM features f WHERE f.project_id='$(sql_escape "$pid")' AND f.deleted_at IS NULL AND f.feature_number=$target AND ($sdd_gate))"
    else
      update_sql="UPDATE features SET status='in_progress', updated_at='$now'
WHERE id = (SELECT f.id FROM features f WHERE f.project_id='$(sql_escape "$pid")' AND f.deleted_at IS NULL AND f.name='$(sql_escape "$target")' AND ($sdd_gate))"
    fi
  else
    update_sql="UPDATE features SET status='in_progress', updated_at='$now'
WHERE id = (SELECT f.id FROM features f WHERE f.project_id='$(sql_escape "$pid")' AND f.deleted_at IS NULL AND ($sdd_gate) ORDER BY f.feature_number LIMIT 1)"
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
    fail "not claimable: no matching pending feature (or an sdd=1 feature awaiting an approved spec — see the message above)"
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

cmd_record_review() {
  local verdict_raw="${1:?usage: record-review <approved|changes-requested> [--by NAME] [--notes TEXT]}"; shift
  local verdict
  case "$verdict_raw" in
    approved) verdict="approved" ;;
    changes-requested) verdict="changes_requested" ;;
    *) fail "verdict must be 'approved' or 'changes-requested', got: $verdict_raw"; exit 1 ;;
  esac

  local by="${HARNESS_AGENT:-unknown}" notes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) by="$2"; shift 2 ;;
      --notes) notes="$2"; shift 2 ;;
      *) fail "unknown argument: $1"; exit 1 ;;
    esac
  done

  local sid; sid="$(current_session_id)"
  [ -n "$sid" ] || { fail "no open session — nothing to review"; exit 1; }
  local now; now="$(now_iso)"

  db_exec "UPDATE session_log SET review_status='$(sql_escape "$verdict")', reviewed_by='$(sql_escape "$by")', reviewed_at='$now' WHERE id=$sid;"
  if [ -n "$notes" ]; then
    db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "REVIEW ($verdict_raw): $notes")', '$now');"
  fi
  ok "recorded review verdict '$verdict_raw' on session $sid (by: $by)"
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
      *) fail "unknown argument: $1"; exit 1 ;;
    esac
  done

  local sid; sid="$(current_session_id)"
  [ -n "$sid" ] || { fail "no open session to log out"; exit 1; }

  # Friendly precheck for an actionable error message — the real enforcement
  # is the WHERE clause on the UPDATE below (same "precheck for the message,
  # WHERE clause for the gate" split cmd_claim uses for the sdd approval
  # check), so a stale/missing precheck can't be used to bypass this.
  local review_status; review_status=$(db "SELECT review_status FROM session_log WHERE id=$sid;")
  if [ "$review_status" != "approved" ]; then
    fail "cannot log out session $sid: no recorded reviewer approval (review_status=${review_status:-none}) — the reviewer must run 'scripts/harness.sh record-review approved --by <name>' first; only the implementer runs log-out, and only after that approval is recorded"
    exit 1
  fi

  local changes_json; changes_json=$(json_array "${changes[@]:-}")
  local now; now="$(now_iso)"

  sqlite3 "$DB_PATH" <<SQL
.bail on
BEGIN;
UPDATE session_log SET changes='$(sql_escape "$changes_json")', verification='$(sql_escape "$verification")',
  closure='$(sql_escape "$closure")', closed_at='$now' WHERE id=$sid AND review_status='approved';
UPDATE features SET status='done', updated_at='$now'
  WHERE id = (SELECT feature_id FROM session_log WHERE id=$sid AND closed_at='$now');
COMMIT;
SQL

  local closed_check; closed_check=$(db "SELECT closed_at FROM session_log WHERE id=$sid;")
  if [ "$closed_check" != "$now" ]; then
    fail "log out failed for session $sid — review approval was revoked or changed between the check and the close; re-run 'status' and try again"
    exit 1
  fi
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
  db -header -column "SELECT f.feature_number, f.name, f.status, f.sdd,
  s.status AS spec_status, s.requirements_count AS reqs, s.tasks_count AS tasks, s.approved_by
FROM features f LEFT JOIN specs s ON s.feature_id = f.id AND s.deleted_at IS NULL
WHERE f.project_id='$(sql_escape "$pid")' AND f.deleted_at IS NULL ORDER BY f.feature_number;"
  echo "--- open session ---"
  db -header -column "SELECT id, agent, started_at, review_status, reviewed_by FROM session_log WHERE project_id='$(sql_escape "$pid")' AND closed_at IS NULL AND deleted_at IS NULL;"
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

# Prints the "# Usage:" comment block at the top of this file verbatim (minus
# the leading "# " marker) so `help`/`-h`/`--help` never drifts out of sync
# with the actual subcommand list — there is exactly one copy of this text.
print_usage() {
  sed -n '/^# Usage:/,/^$/p' "$SCRIPT_DIR/harness.sh" | sed 's/^# \{0,1\}//'
}

main() {
  local sub="${1:-}"
  case "$sub" in
    ""|help|-h|--help) print_usage; exit 0 ;;
  esac
  shift || true

  # A `-h`/`--help` anywhere after the subcommand short-circuits straight to
  # the usage block instead of reaching a subcommand's own arg parser — this
  # is what makes e.g. `log-out --help` safe: it used to fall into
  # cmd_log_out's catch-all, which silently discarded the unrecognized flag
  # and ran the destructive close anyway.
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help) print_usage; exit 0 ;;
    esac
  done

  case "$sub" in
    import-features) cmd_import_features "$@" ;;
    add-feature) cmd_add_feature "$@" ;;
    link-notion) cmd_link_notion "$@" ;;
    import-sessions) cmd_import_sessions "$@" ;;
    notion-diff) cmd_notion_diff "$@" ;;
    notion-import) cmd_notion_import "$@" ;;
    claim-spec) cmd_claim_spec "$@" ;;
    mark-spec-ready) cmd_mark_spec_ready ;;
    approve-spec) cmd_approve_spec "$@" ;;
    claim) cmd_claim "$@" ;;
    record-review) cmd_record_review "$@" ;;
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
      fail "unknown subcommand: $sub"
      print_usage >&2
      exit 1
      ;;
  esac
}

main "$@"
