#!/usr/bin/env bash
# snapshot.sh — regenerate the human-readable/git-diffable markdown snapshot
# (state/) from harness.db. Always safe to wipe and rewrite wholesale: these
# files are generated only, never hand-edited, so there's nothing to lose.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

rm -rf "$SNAPSHOT_PATH"
mkdir -p "$SNAPSHOT_PATH/features" "$SNAPSHOT_PATH/sessions"

pid=$(db "SELECT id FROM projects WHERE slug='$(sql_escape "$PROJECT_SLUG")' AND deleted_at IS NULL LIMIT 1;")

sqlite3 -json "$DB_PATH" "SELECT id, feature_number, name, title, description, request, acceptance, status,
  superseded_by, created_at, updated_at FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL
  ORDER BY feature_number;" | jq -c '.[]' | while IFS= read -r row; do
  number=$(jq -r '.feature_number' <<<"$row")
  name=$(jq -r '.name' <<<"$row")
  title=$(jq -r '.title' <<<"$row")
  desc=$(jq -r '.description // ""' <<<"$row")
  request=$(jq -r '.request // ""' <<<"$row")
  status=$(jq -r '.status' <<<"$row")
  superseded_by=$(jq -r '.superseded_by // ""' <<<"$row")
  fid=$(jq -r '.id' <<<"$row")
  created=$(jq -r '.created_at' <<<"$row")
  updated=$(jq -r '.updated_at' <<<"$row")
  padded=$(printf '%03d' "$number")
  file="$SNAPSHOT_PATH/features/${padded}-${name}.md"

  {
    echo "---"
    echo "feature_number: $number"
    echo "name: $name"
    echo "title: $title"
    echo "status: $status"
    [ -n "$superseded_by" ] && echo "superseded_by: $superseded_by"
    echo "created_at: $created"
    echo "updated_at: $updated"
    echo "---"
    echo
    if [ -n "$request" ]; then
      echo "## Request (verbatim)"
      echo "$request"
      echo
    fi
    echo "## Description"
    echo "$desc"
    echo
    echo "## Acceptance"
    jq -r '(.acceptance | fromjson // [])[]' <<<"$row" | while IFS= read -r item; do
      echo "- [ ] $item"
    done
    notes=$(sqlite3 -json "$DB_PATH" "SELECT entry, created_at FROM feature_notes
      WHERE feature_id=$fid AND deleted_at IS NULL ORDER BY created_at, id;")
    if [ -n "$notes" ] && [ "$notes" != "[]" ]; then
      echo
      echo "## Notes"
      jq -r '.[] | "- \(.created_at) \(.entry)"' <<<"$notes"
    fi
    # Filled by `harness.sh record-usage`; numbers only. Summed durations are
    # agent effort, not wall time — `harness.sh stats` shows the full tree.
    runs=$(sqlite3 -json "$DB_PATH" "SELECT agent_role, label, runtime, model, spawn_depth, started_at,
      duration_seconds, input_tokens, cache_read_tokens, cache_write_tokens, output_tokens,
      reasoning_tokens, total_tokens FROM agent_runs
      WHERE feature_id=$fid AND deleted_at IS NULL ORDER BY started_at, id;")
    if [ -n "$runs" ] && [ "$runs" != "[]" ]; then
      echo
      echo "## Agent usage"
      echo
      echo "| agent | runtime | model | started_at | duration_s | input | cache_read | cache_write | output | reasoning | total |"
      echo "|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|"
      jq -r 'def n: if . == null then "-" else tostring end;
        def esc: tostring | gsub("\\|"; "/");
        (.[] | "| \(if (.spawn_depth // 0) > 0 then "&nbsp;&nbsp;" * .spawn_depth else "" end) \(.agent_role // "?" | esc)\(if .label then " (" + (.label | esc) + ")" else "" end) | \(.runtime) | \(.model // "-" | esc) | \(.started_at // "-") | \(.duration_seconds | n) | \(.input_tokens | n) | \(.cache_read_tokens | n) | \(.cache_write_tokens | n) | \(.output_tokens | n) | \(.reasoning_tokens | n) | \(.total_tokens | n) |"),
        "| **total** | | | | \(map(.duration_seconds // 0) | add * 1000 | round / 1000) | \(map(.input_tokens // 0) | add) | \(map(.cache_read_tokens // 0) | add) | \(map(.cache_write_tokens // 0) | add) | \(map(.output_tokens // 0) | add) | \(map(.reasoning_tokens // 0) | add) | \(map(.total_tokens // 0) | add) |"' <<<"$runs"
    fi
  } > "$file"
done

sqlite3 -json "$DB_PATH" "SELECT sl.id, sl.agent, sl.plan, sl.next_step, sl.changes, sl.verification,
  sl.closure, sl.started_at, sl.closed_at, sl.paused_at, f.name AS feature_name
  FROM session_log sl LEFT JOIN features f ON f.id = sl.feature_id
  WHERE sl.project_id='$(sql_escape "$pid")' AND sl.deleted_at IS NULL
  ORDER BY sl.started_at;" | jq -c '.[]' | while IFS= read -r row; do
  id=$(jq -r '.id' <<<"$row")
  agent=$(jq -r '.agent' <<<"$row")
  feature_name=$(jq -r '.feature_name // "bootstrap"' <<<"$row")
  started=$(jq -r '.started_at' <<<"$row")
  closed=$(jq -r '.closed_at // ""' <<<"$row")
  paused=$(jq -r '.paused_at // ""' <<<"$row")
  date_part=$(cut -c1-10 <<<"$started")
  file="$SNAPSHOT_PATH/sessions/${date_part}-${id}-${feature_name}.md"

  {
    echo "---"
    echo "session_id: $id"
    echo "feature: $feature_name"
    echo "agent: $agent"
    echo "started_at: $started"
    if [ -n "$closed" ]; then echo "closed_at: $closed"; else echo "closed_at:"; fi
    [ -z "$paused" ] || echo "paused_at: $paused"
    echo "---"
    echo
    echo "## Plan"
    jq -r 'if .plan then (.plan | fromjson) else [] end | .[]' <<<"$row" | while IFS= read -r item; do echo "- $item"; done
    echo
    echo "## Log"
    sqlite3 -json "$DB_PATH" "SELECT entry FROM session_log_entries WHERE session_id=$id AND deleted_at IS NULL ORDER BY created_at;" \
      | jq -r '.[].entry' | while IFS= read -r entry; do echo "- $entry"; done
    echo
    echo "## Next Step"
    jq -r 'if .next_step then (.next_step | fromjson) else [] end | .[]' <<<"$row" | while IFS= read -r item; do echo "- $item"; done
    if [ -n "$closed" ]; then
      echo
      echo "## Verification"
      jq -r '.verification // ""' <<<"$row"
      echo
      echo "## Closure"
      jq -r '.closure // ""' <<<"$row"
    fi
  } > "$file"
done

ok "snapshot regenerated at $SNAPSHOT_PATH"
