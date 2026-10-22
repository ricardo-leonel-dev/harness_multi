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
#                                              "sdd": true per item opts it into spec-driven development;
#                                              optional "depends_on": [name...] gates claim on those LOCAL
#                                              features — same project — being 'done' first)
#   add-feature --name <slug> --title <t> [--description <d>] [--request <text>] [--acceptance <item...>]
#               [--sdd] [--depends-on <name...>] [--size small|normal]
#                                              create a single pending feature directly (no seed file) — for
#                                              ad-hoc tasks the leader creates on the spot, no matching pending
#                                              feature existed; --sdd requires an approved spec before claim;
#                                              --depends-on names other LOCAL features (same project, must
#                                              already exist) that must be 'done' before this one is claimable;
#                                              --size small lets it close through log-out --quick (default normal);
#                                              --request keeps the user's request verbatim (the spec quotes it)
#   set-request <feature_number|name> <text>  store/replace a feature's verbatim user request
#   drop-sdd <feature_number|name> <reason>   turn a pending sdd=1 feature into sdd=0 before any spec exists
#                                              (only after the user accepted it in this conversation); the
#                                              reason is kept as a feature note
#   set-size <feature_number|name> <small|normal>
#                                              change a not-yet-done feature's size (leader's classification,
#                                              or back to normal when an escalation is approved)
#   set-depends-on <feature_number|name> [dep_name...]
#                                              replace a feature's local dependency list (each dep_name must
#                                              already exist as a feature in this project; call with no
#                                              dep_name to clear it) — for backfilling/correcting dependencies
#                                              after creation; works at any status, unlike claim/block/unblock
#   link-notion <feature_number|name> <notion_page_id>
#                                              stamp a feature's source_id so claim/log-out's existing best-effort
#                                              Notion push-back starts applying to it (pairs with notion-create-feature
#                                              for the ad-hoc-task-to-Notion flow — see AGENTS.md)
#   import-sessions <seed.json>               bulk-load historical (closed) sessions
#   notion-diff                               (stdin: JSON array of {source_id,...}) prints only entries not yet imported
#   notion-import <file.json>                 import entries as pending features, auto-numbered, source_id stored
#                                              (optional "sdd" checkbox property carried through if present;
#                                              optional "depends_on": [name...] also carried through — see
#                                              import-features above)
#   claim-spec [--agent NAME] [--agent-model MODEL] [TARGET]
#                                              claim an sdd=1 pending feature for spec drafting (spec_author only —
#                                              see docs/specs.md); moves it to spec_drafting and opens a session.
#                                              The session's stored agent is auto-formatted as
#                                              "Claude (<role> agent by <MODEL>)" when a model is known via
#                                              --agent-model > $HARNESS_AGENT_MODEL > $ANTHROPIC_MODEL; pass --agent
#                                              with a pre-formatted string (e.g. Codex's "leader -> spec_author
#                                              (GPT-5)") to take precedence.
#                                              An explicit TARGET that is spec_ready with a NOT-yet-approved spec
#                                              is re-opened for revision (back to spec_drafting, spec row back to
#                                              drafting so approve-spec can't approve it mid-revision); finish
#                                              with mark-spec-ready as usual. Approved specs are not re-openable.
#   mark-spec-ready                           close the current spec-drafting session: verifies
#                                              specs/<name>/{requirements,design,tasks}.md exist (requirements.md
#                                              with its "## Request (verbatim)" and "## Assumptions" sections), records
#                                              requirement/task counts, moves the feature to spec_ready
#                                              (best-effort: pushes notion_status_spec_ready if source_id is set).
#                                              Refuses a spec with more than .harness.json::spec_max_requirements
#                                              (default 15, 0 disables) requirements — split it (docs/specs.md);
#                                              approve-spec applies the same limit to its recount
#   approve-spec <TARGET> [--by NAME]         record human approval of a spec_ready feature's spec (leader-only,
#                                              run immediately after the user approves in conversation) — this is
#                                              the actual DB-enforced precondition claim checks for sdd=1 features.
#                                              Recounts R/T from the spec files at approval time (warns if they
#                                              changed since mark-spec-ready), so the recorded counts match what
#                                              the human actually approved.
#                                              --by resolution: explicit --by > $HARNESS_HUMAN_USER env >
#                                              .harness.json::human_user > legacy default "user". This is the ONLY
#                                              command that stores a literal human name (not an agent string);
#                                              record-review rejects bare human names for the opposite reason — see
#                                              the record-review doc comment for the full rationale.
#   claim [--agent NAME] [--agent-model MODEL] [TARGET]
#                                              claim TARGET (number or name), or lowest claimable if omitted.
#                                              For sdd=0 features: from pending. For sdd=1 features: only from
#                                              spec_ready with an approved spec (see approve-spec) and the 3 spec
#                                              files still present on disk. Either way, every name in the
#                                              feature's depends_on must already be a 'done' feature in this
#                                              project (see set-depends-on / --depends-on) — refuses otherwise.
#                                              The session's stored agent is auto-formatted as
#                                              "Claude (<role> agent by <MODEL>)" when a model is known via
#                                              --agent-model > $HARNESS_AGENT_MODEL > $ANTHROPIC_MODEL; pass --agent
#                                              with a pre-formatted string (e.g. Codex's "leader -> implementer
#                                              (GPT-5)") to take precedence.
#                                              (best-effort: also pushes notion_status_in_progress to the
#                                              feature's source Notion page, if it has a source_id)
#                                              Prints the feature's work folder, progress/<name>/: every handoff
#                                              (impl.md, quick.md, review.md, escalate.md, logs) goes there, and
#                                              log-out deletes it once the feature is done
#                                              An explicit TARGET that is in_progress/blocked with NO open session
#                                              (e.g. lost to cancel-session --force) is resumed instead: new session,
#                                              status in_progress, "RESUMED: previous session <id> was cancelled"
#                                              logged. Gates are not re-run; any review verdict stays on the old
#                                              session, so record-review must run again before log-out.
#   append-log <entry> [--feature TARGET] [--agent NAME] [--agent-model MODEL]
#                                              append a line to the current open session's log. By default
#                                              the entry is prefixed with the standardized agent attribution
#                                              ("Claude (<role> agent by <MODEL>)" when $ANTHROPIC_MODEL is
#                                              set, otherwise the session's stored agent). Pass --agent to
#                                              override the role for this entry; pass --agent-model to pin
#                                              the model when the auto-detected one is wrong (e.g. handing
#                                              the entry off between agents with different models).
#                                              --feature TARGET writes a feature-level note instead (no open
#                                              session needed); snapshot lists them under the feature's Notes.
#   set-plan <item> [item...]                 replace the current open session's plan
#   set-next-step <item> [item...]            replace the current open session's next_step
#   record-review <approved|changes-requested> [--by human:NAME] [--reviewer-model MODEL] [--notes TEXT]
#                                              record the reviewer's verdict on the current open session
#                                              (reviewer-only, run as the mechanical last step of its own
#                                              protocol) — log-out refuses to close a session whose latest
#                                              verdict isn't 'approved'; a later call overwrites the verdict,
#                                              so a re-review after CHANGES_REQUESTED just records over it.
#                                              --by policy (post feature-38 incident): for the canonical case
#                                              (subagent reviewer), OMIT --by entirely and let the harness
#                                              auto-format as "Claude (reviewer agent by <MODEL>)" or
#                                              "Codex (reviewer agent by <MODEL>)" from $ANTHROPIC_MODEL.
#                                              The ONLY accepted explicit value is the prefix "human:<name>"
#                                              — for the rare case where a literal human (not a subagent)
#                                              records the review. Any other --by value is rejected to
#                                              prevent confusing this subagent-review gate with the
#                                              human-spec-approval gate (approve-spec --by "Ricardo Aguilar",
#                                              which is the ONLY command that accepts a bare human name).
#   log-out --changes <item...> --verification <text> --closure <text>
#                                              close the open session and mark its feature done — refuses
#                                              unless record-review has recorded 'approved' on this session
#                                              (best-effort: also pushes notion_status_done to the
#                                              feature's source Notion page, if it has a source_id).
#                                              Also logs a "DIFF: code=N, tests=M" entry measured from
#                                              git for the --changes paths (lockfiles/generated/prose
#                                              excluded) and warns, never blocks, when code exceeds
#                                              .harness.json::review_budget_lines (default 400, 0 disables).
#                                              On success it deletes the feature's work folder progress/<name>/
#   log-out --quick --changes <item...> --verification <text> --closure <text>
#                                              small features only: close without a reviewer when the quick gate
#                                              passes — diff <= quick_max_diff_lines (80) and <= quick_max_files (4)
#                                              against the session base, no dependency file, every changed file
#                                              declared under "Archivos:" in progress/<name>/quick.md, "Risk: none"
#                                              there, and the last ./init.sh green on the current tree. Otherwise
#                                              refuses with the reasons (logged): launch the reviewer. A reviewer's
#                                              approval wins; requested changes are never bypassed
#   hold <reason...>                          stop the active session (rejected escalation): it keeps the slot,
#                                              so claim refuses other features and log-out refuses this one
#   unhold [reason...]                        the user releases a held session (block also releases it)
#   learn [--feature TARGET] <note...>        keep one lesson (<= 300 chars), linked to the active feature
#   recall [term...]                          at most 5 learnings matching the terms (newest 5 without terms)
#   forget <learning_id>                      soft-delete a learning that no longer applies
#   record-init <pass|fail|none>              (init.sh) log the verify result + tree fingerprint on the session
#   delete-feature <TARGET>                   soft-delete a feature and its specs (sets deleted_at) — refuses
#                                              while the feature has an open or paused session
#   status                                     print current project/feature/session state
#   mock-data-generate --version VERSION [--selection FILE] [--extends VERSION]
#   mock-data-check --version VERSION [--offline] [--database DB]
#   mock-data-load --version VERSION --target-database harness_mock_NAME
#                                              PostgreSQL profile: project-owned immutable test data
#   snapshot                                   regenerate state/*.md from harness.db
#   sync                                       best-effort push to the Postgres mirror
#   notion-check                               best-effort curl+jq query for new Notion tasks (prints notion-diff-ready JSON)
#   notion-create-feature --project <slug> --title <t> --description <d> [--acceptance <a>] [--status <s>] [--sdd]
#                                              create a new Notion page (feature card) in a project — for cross-
#                                              project dependency requests; fails loudly (not a [WARN]) since the
#                                              caller must not proceed to block a feature on a card that wasn't
#                                              actually created
#   block <TARGET> <reason...>                mark an in_progress feature blocked and pause its session (still
#                                              open, log/review intact, but no longer holding the project's
#                                              one-session slot — other features can be claimed meanwhile)
#   unblock <TARGET>                          mark a blocked feature in_progress again, resuming its paused
#                                              session; refuses if it has none (use claim TARGET) or if another
#                                              session is active
#   cancel-session [--force] <session_id> <reason...>
#                                              soft-delete an open session that never produced real work (e.g. a
#                                              claim interrupted before any plan/log/changes), freeing the project's
#                                              one-open-session slot without touching feature status. Refuses unless
#                                              the session's feature is missing/deleted, unless --force is passed —
#                                              this is not for abandoning genuine in-progress work (use block for that)
#   reopen <TARGET> <reason...>               mark a done feature in_progress again, opening a fresh session
#                                              (e.g. it was closed without meeting a checkpoint) — logs a
#                                              REOPENED: <reason> entry on the new session for the audit trail
#   supersede <TARGET> --by <TARGET> --reason <text>
#                                              close a pending/spec_drafting/spec_ready feature (no open session)
#                                              as absorbed by another one: status 'superseded', records --by and
#                                              the previous status, logs the reason as a feature note, warns about
#                                              features whose depends_on still names it (best-effort: pushes
#                                              notion_status_superseded, default "Done", if source_id is set)
#   unsupersede <TARGET> <reason...>          undo supersede: restores the recorded previous status (Notion card
#                                              is left as-is — fix it by hand)
#   check-blockers                            best-effort: for every blocked feature with a BLOCKED_ON note,
#                                              check the referenced sibling project's harness.db directly
#   record-usage [--transcript P...] [--runtime claude|codex|all] [--since T] [--dry-run] [--full]
#                [--max-seconds N]
#                                              best-effort, idempotent: read Claude Code transcripts / Codex CLI
#                                              rollouts for this project and upsert one agent_runs row per agent
#                                              invocation (leader, implementer, reviewer, spec_author, nested
#                                              spawns) with role, label, parent/depth, model, duration and token
#                                              usage — never transcript content. Runs are attributed to the harness
#                                              session whose window contains their start. --transcript reads only
#                                              that file; --since is an ISO
#                                              date/time or Nd/Nh. Incremental: files unchanged (mtime+size)
#                                              since last parsed are skipped; --full rescans them. --max-seconds
#                                              (default 20) bounds the run: at the limit it keeps partial
#                                              progress and warns. Any parse/IO problem is a [WARN]; exits 0.
#                                              When .harness.json sets token_quota, also warns once the active
#                                              feature's tokens reach token_warn_percent (default 15) of it.
#                                              Warns when a finished subagent was messaged again while carrying
#                                              >= reopen_warn_tokens (default 80000) of context.
#   stats [TARGET]                            agent invocation tree (parent -> children) per feature with per-run
#                                              duration/tokens, totals per feature and per project, plus agent effort
#                                              vs. union of agent intervals vs. session elapsed (see
#                                              harness/instructions/timing.md); TARGET limits it to one feature.
#                                              Runs record-usage first so the latest agents are included
#                                              (--no-refresh skips that)
#   link-worktree <worktree_project_dir>      run from the main checkout: give a git worktree of this repository
#                                              the harness without a second harness.db — symlinks what must be
#                                              shared (harness.db, scripts, agents, AGENTS.md, .harness.json, ...;
#                                              project files such as docs/ or specs/ only when the worktree lacks
#                                              them) and keeps progress/ a real local directory, so agents writing
#                                              handoffs never write outside the worktree. Lists the links in the
#                                              shared .git/info/exclude. Safe to re-run: existing files are kept
#   test [file...]                            run tests with output to progress/test_last.log, printing only
#                                              the result (and the log's tail on failure): with files and
#                                              .harness.json::test_targeted_command (its {files} placeholder
#                                              becomes the quoted paths; {files:FLAG} repeats FLAG before each
#                                              one, e.g. {files:--include}) only those; else verify_command.
#                                              Exits with the tests' status

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Mock-data tools are independent of SQLite feature/session bookkeeping.
case "${1:-}" in
  mock-data-generate|mock-data-check|mock-data-load)
    mock_command="${1#mock-data-}"
    shift
    if [ ! -f "$SCRIPT_DIR/mock_data.py" ]; then
      printf '[FAIL] mock-data tools require install.sh --profile postgres\n' >&2
      exit 1
    fi
    exec python3 "$SCRIPT_DIR/mock_data.py" "$mock_command" "$@"
    ;;
esac

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

project_id() {
  db "SELECT id FROM projects WHERE slug = '$(sql_escape "$PROJECT_SLUG")' AND deleted_at IS NULL LIMIT 1;"
}

# spec_counts <spec_dir> — prints "<requirements_count> <tasks_count>" parsed
# from <spec_dir>/{requirements,tasks}.md. Shared by mark-spec-ready and
# approve-spec so the counts recorded at approval time come from the exact
# same parse as the ones recorded when the spec was marked ready — the files
# can be revised in between, and what gets recorded as approved must match
# what the human actually read.
spec_counts() {
  local dir="$1" req task
  req=$(grep -cE '^## R[0-9]+' "$dir/requirements.md" 2>/dev/null)
  task=$(grep -cE '^- \[[ xX]\] T[0-9]+' "$dir/tasks.md" 2>/dev/null)
  printf '%s %s' "${req:-0}" "${task:-0}"
}

# check_spec_scope <spec_dir> <requirements_count> <name> <failure_prefix> —
# exits unless the count is within .harness.json::spec_max_requirements
# (default 15; 0 disables). Cost grows superlinearly with requirement count
# (every extra rule means more reads, edits and test runs in one context), so
# an oversized spec must be split before it can be marked ready or approved —
# see docs/specs.md "Scope limit". Shared by mark-spec-ready and approve-spec
# so a spec edited by hand after mark-spec-ready can't slip past the limit.
check_spec_scope() {
  local dir="$1" req="$2" name="$3" prefix="$4" max_req
  max_req="$(config '.spec_max_requirements' '15')"
  [[ "$max_req" =~ ^[0-9]+$ ]] || max_req=15
  if [ "$max_req" -gt 0 ] && [ "$req" -gt "$max_req" ]; then
    fail "$prefix: $dir has $req requirements (limit spec_max_requirements=$max_req) — merge clauses into one requirement per business rule, or write progress/$name/split.md and report split-proposed (docs/specs.md \"Scope limit\")"
    exit 1
  fi
}

cmd_import_features() {
  local seed_file="${1:?usage: import-features <seed.json>}"
  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }

  jq -c '.[]' "$seed_file" | while IFS= read -r item; do
    local number name title desc status accept sdd depends_on now
    number=$(jq -r '.feature_number' <<<"$item")
    name=$(jq -r '.name' <<<"$item")
    title=$(jq -r '.title' <<<"$item")
    desc=$(jq -r '.description // ""' <<<"$item")
    status=$(jq -r '.status // "pending"' <<<"$item")
    accept=$(jq -c '.acceptance // []' <<<"$item")
    sdd=$(jq -r 'if (.sdd == true or .sdd == 1) then 1 else 0 end' <<<"$item")
    depends_on=$(jq -c '.depends_on // []' <<<"$item")
    now="$(now_iso)"
    db_exec "INSERT INTO features (project_id, feature_number, name, title, description, acceptance, sdd, status, depends_on, created_at, updated_at)
VALUES ('$(sql_escape "$pid")', $number, '$(sql_escape "$name")', '$(sql_escape "$title")', '$(sql_escape "$desc")', '$(sql_escape "$accept")', $sdd, '$(sql_escape "$status")', '$(sql_escape "$depends_on")', '$now', '$now');"
  done
  ok "imported features from $seed_file"
}

cmd_add_feature() {
  local name="" title="" desc="" request="" accept_items=() sdd=0 depends_items=() size=normal
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --request) request="$2"; shift 2 ;;
      --size) size="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --description) desc="$2"; shift 2 ;;
      --sdd) sdd=1; shift ;;
      --acceptance)
        shift
        while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
          accept_items+=("$1"); shift
        done
        ;;
      --depends-on)
        shift
        while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
          depends_items+=("$1"); shift
        done
        ;;
      *) fail "unknown argument: $1"; exit 1 ;;
    esac
  done
  if [ -z "$name" ] || [ -z "$title" ]; then
    fail "usage: add-feature --name <slug> --title <text> [--description <text>] [--request <text>] [--acceptance <item...>] [--sdd] [--depends-on <name...>] [--size small|normal]"
    exit 1
  fi
  case "$size" in small|normal) ;; *) fail "--size must be 'small' or 'normal', got: $size"; exit 1 ;; esac

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }

  local dep
  for dep in "${depends_items[@]+"${depends_items[@]}"}"; do
    if [ "$dep" = "$name" ]; then
      fail "feature $name cannot depend on itself"
      exit 1
    fi
    local exists
    exists=$(db "SELECT 1 FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND name='$(sql_escape "$dep")';")
    [ -n "$exists" ] || { fail "unknown dependency '$dep' — no feature with that name exists yet in this project (add it first, or fix the typo)"; exit 1; }
  done

  local next_number
  next_number=$(db "SELECT COALESCE(MAX(feature_number), 0) + 1 FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL;")
  # NOTE: "${arr[@]:-}" on an EMPTY array expands to one empty-string word,
  # which made json_array emit [""] instead of [] (this pre-existing shape
  # bit accept_items too, fixed alongside depends_items here). A stray [""]
  # in depends_on isn't just cosmetic: cmd_claim's deps_gate treats "" as an
  # unmet dependency name, so it would refuse to claim a feature with no
  # declared dependencies at all. Bare "${arr[@]}" avoids that, but on
  # bash 3.2 (macOS's stock /bin/bash) an EMPTY array with no ':-' fallback
  # trips `set -u` itself ("unbound variable") — bash 3.2 predates the 4.4
  # fix that made this safe. "${arr[@]+"${arr[@]}"}" is the idiom that is
  # simultaneously bash-3.2-safe (empty array + `set -u`) and shape-safe
  # (never produces a stray [""]).
  local accept; accept="$(json_array "${accept_items[@]+"${accept_items[@]}"}")"
  local depends_on; depends_on="$(json_array "${depends_items[@]+"${depends_items[@]}"}")"
  local now; now="$(now_iso)"

  local request_sql=NULL; [ -n "$request" ] && request_sql="'$(sql_escape "$request")'"
  db_exec "INSERT INTO features (project_id, feature_number, name, title, description, acceptance, sdd, status, depends_on, size, request, created_at, updated_at)
VALUES ('$(sql_escape "$pid")', $next_number, '$(sql_escape "$name")', '$(sql_escape "$title")', '$(sql_escape "$desc")', '$(sql_escape "$accept")', $sdd, 'pending', '$(sql_escape "$depends_on")', '$size', $request_sql, '$now', '$now');"
  local sdd_note=""; [ "$sdd" = "1" ] && sdd_note=", sdd"
  [ "$size" = "small" ] && sdd_note="$sdd_note, small"
  local deps_note=""; [ "$depends_on" != "[]" ] && deps_note=", depends on: $depends_on"
  ok "added feature $next_number: $name (pending$sdd_note$deps_note)"
}

# set-size <TARGET> <small|normal> — a small feature may close through
# `log-out --quick` without a reviewer when the quick gate passes. The leader
# sets it when it classifies a task; switching back to normal (an approved
# escalation) restores the reviewer path. Done/superseded features are final.
cmd_set_size() {
  local target="${1:-}" size="${2:-}"
  case "$size" in small|normal) ;; *) fail "usage: set-size <feature_number|name> <small|normal>"; exit 1 ;; esac
  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local where
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    where="feature_number=$target"
  else
    where="name='$(sql_escape "$target")'"
  fi
  local updated
  updated=$(db "UPDATE features SET size='$size', updated_at='$(now_iso)'
WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND status NOT IN ('done','superseded') AND $where
RETURNING feature_number || ' ' || name;")
  [ -n "$updated" ] || { fail "no matching feature that is not done/superseded: $target"; exit 1; }
  ok "feature $updated is now $size"
}

# drop-sdd <TARGET> <reason> — the leader found the request already complete
# and the user accepted skipping the spec. Only a pending sdd=1 feature with no
# spec started; the reason stays as a feature note.
cmd_drop_sdd() {
  local target="${1:-}"; shift || true
  local reason="$*"
  if [ -z "$target" ] || [ -z "$reason" ]; then
    fail "usage: drop-sdd <feature_number|name> <reason>"; exit 1
  fi
  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local where
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    where="feature_number=$target"
  else
    where="name='$(sql_escape "$target")'"
  fi
  local now; now="$(now_iso)"
  local updated
  updated=$(db "UPDATE features SET sdd=0, updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND status='pending' AND sdd=1 AND $where
  AND NOT EXISTS (SELECT 1 FROM specs WHERE specs.feature_id=features.id AND specs.deleted_at IS NULL)
RETURNING id || ' ' || feature_number || ' ' || name;")
  [ -n "$updated" ] || { fail "no pending sdd=1 feature without a spec matches: $target"; exit 1; }
  db_exec "INSERT INTO feature_notes (feature_id, entry, created_at) VALUES (${updated%% *}, '$(sql_escape "SDD dropped: $reason")', '$now');"
  ok "feature ${updated#* } is now sdd=0"
}

# set-request <TARGET> <text> — the user's request verbatim, for a feature
# created without --request (seed, older install) or whose request changed
# before work started. The spec_author quotes it in requirements.md.
cmd_set_request() {
  local target="${1:-}"; shift || true
  local text="$*"
  if [ -z "$target" ] || [ -z "$text" ]; then
    fail "usage: set-request <feature_number|name> <text>"; exit 1
  fi
  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local where
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    where="feature_number=$target"
  else
    where="name='$(sql_escape "$target")'"
  fi
  local updated
  updated=$(db "UPDATE features SET request='$(sql_escape "$text")', updated_at='$(now_iso)'
WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND $where
RETURNING feature_number || ' ' || name;")
  [ -n "$updated" ] || { fail "no matching feature: $target"; exit 1; }
  ok "stored the verbatim request for feature $updated"
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

cmd_set_depends_on() {
  local target="${1:?usage: set-depends-on <feature_number|name> [dep_name...]}"; shift

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local now; now="$(now_iso)"

  local where
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    where="feature_number=$target"
  else
    where="name='$(sql_escape "$target")'"
  fi

  local target_name
  target_name=$(db "SELECT name FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND $where;")
  [ -n "$target_name" ] || { fail "not updatable: no matching feature $target"; exit 1; }

  local dep
  for dep in "$@"; do
    [ -n "$dep" ] || continue
    if [ "$dep" = "$target_name" ]; then
      fail "feature $target_name cannot depend on itself"
      exit 1
    fi
    local exists
    exists=$(db "SELECT 1 FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND name='$(sql_escape "$dep")';")
    [ -n "$exists" ] || { fail "unknown dependency '$dep' — no feature with that name exists in this project"; exit 1; }
  done

  # No status/session-state check here (unlike claim/block/unblock) —
  # dependencies are metadata correctable at any lifecycle stage; claim is
  # what actually enforces them.
  local depends_on; depends_on="$(json_array "$@")"
  db_exec "UPDATE features SET depends_on='$(sql_escape "$depends_on")', updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND $where;"
  ok "set depends_on for feature $target_name: $depends_on"
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
    local name title desc accept sdd depends_on source_id now source_id_sql
    name=$(jq -r '.name' <<<"$item")
    title=$(jq -r '.title' <<<"$item")
    desc=$(jq -r '.description // ""' <<<"$item")
    accept=$(jq -c '.acceptance // []' <<<"$item")
    sdd=$(jq -r 'if (.sdd == true or .sdd == 1) then 1 else 0 end' <<<"$item")
    depends_on=$(jq -c '.depends_on // []' <<<"$item")
    source_id=$(jq -r '.source_id // empty' <<<"$item")
    now="$(now_iso)"
    if [ -n "$source_id" ]; then
      source_id_sql="'$(sql_escape "$source_id")'"
    else
      source_id_sql="NULL"
    fi
    # The card's text is the user's own request: keep it verbatim too.
    db_exec "INSERT INTO features (project_id, feature_number, name, title, description, acceptance, sdd, status, depends_on, source_id, request, created_at, updated_at)
VALUES ('$(sql_escape "$pid")', $next_number, '$(sql_escape "$name")', '$(sql_escape "$title")', '$(sql_escape "$desc")', '$(sql_escape "$accept")', $sdd, 'pending', '$(sql_escape "$depends_on")', $source_id_sql, NULLIF('$(sql_escape "$desc")', ''), '$now', '$now');"
    next_number=$((next_number + 1))
  done
  ok "imported notion tasks from $seed_file"
}

cmd_claim_spec() {
  local agent="${HARNESS_AGENT:-unknown}"
  local agent_model=""
  local target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) agent="$2"; shift 2 ;;
      --agent-model) agent_model="$2"; shift 2 ;;
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
  #
  # An explicit TARGET may also be 'spec_ready' as long as its spec is NOT yet approved:
  # that's the revision path (the human asks for changes after mark-spec-ready). Without
  # it, a revised spec had no way back into the DB — the recorded R/T counts went stale
  # and the revision never appeared in any session log. It is deliberately explicit-only:
  # the no-TARGET default must never grab a spec that is sitting in review. Once
  # approved, the spec is frozen here; changing it then is a new decision for the human.
  local revisable="(status IN ('pending','spec_drafting') OR (status='spec_ready' AND id NOT IN (SELECT feature_id FROM specs WHERE status='approved' AND deleted_at IS NULL)))"
  local update_sql
  if [ -n "$target" ]; then
    if [[ "$target" =~ ^[0-9]+$ ]]; then
      update_sql="UPDATE features SET status='spec_drafting', updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND $revisable AND sdd=1 AND deleted_at IS NULL AND feature_number=$target"
    else
      update_sql="UPDATE features SET status='spec_drafting', updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND $revisable AND sdd=1 AND deleted_at IS NULL AND name='$(sql_escape "$target")'"
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
    fail "not claimable for spec drafting: no matching pending/spec_drafting sdd=1 feature (a spec_ready one is only re-claimable by explicit TARGET, and only while its spec is not yet approved; or sdd not set — see 'add-feature --sdd')"
    exit 1
  fi
  local feature_id; feature_id=$(jq -r '.[0].id' <<<"$updated")

  # See cmd_claim for the helper rationale.
  local agent_attribution
  agent_attribution="$(harness_agent_attribution "$agent" "" "$agent_model")"

  db_exec "INSERT INTO session_log (project_id, feature_id, agent, started_at)
VALUES ('$(sql_escape "$pid")', $feature_id, '$(sql_escape "$agent_attribution")', '$now');"

  # Revision of a spec that was already marked ready: pull its specs row back
  # to 'drafting' so approve-spec (which only matches status='ready') can't
  # approve it mid-revision, and log the counts it had so the revision is
  # visible in this session's history.
  local prev_spec
  prev_spec=$(sqlite3 -json "$DB_PATH" "UPDATE specs SET status='drafting', updated_at='$now'
WHERE feature_id=$feature_id AND status='ready' AND deleted_at IS NULL
RETURNING requirements_count, tasks_count;")
  if [ -n "$prev_spec" ] && [ "$prev_spec" != "[]" ]; then
    local sid; sid="$(current_session_id)"
    local prev_counts; prev_counts=$(jq -r '.[0] | "R=\(.requirements_count), T=\(.tasks_count)"' <<<"$prev_spec")
    db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "[$agent_attribution] SPEC REVISION: re-opened a spec_ready spec for revision (was $prev_counts)")', '$now');"
    ok "re-opened spec for revision: $(jq -r '.[0] | "\(.feature_number) \(.name) — \(.title)"' <<<"$updated") (was $prev_counts) — run 'mark-spec-ready' when done"
    return 0
  fi
  ok "claimed for spec drafting: $(jq -r '.[0] | "\(.feature_number) \(.name) — \(.title)"' <<<"$updated")"
}

cmd_mark_spec_ready() {
  local sid; sid="$(current_session_id)"
  [ -n "$sid" ] || { fail "no open session — run 'claim-spec' first"; exit 1; }

  local fid name fnum status_now
  fid=$(db "SELECT feature_id FROM session_log WHERE id=$sid;")
  [ -n "$fid" ] || { fail "open session has no associated feature"; exit 1; }
  name=$(db "SELECT name FROM features WHERE id=$fid;")
  fnum=$(db "SELECT feature_number FROM features WHERE id=$fid;")
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
  read -r req_count task_count <<<"$(spec_counts "$spec_dir")"
  agent_str=$(db "SELECT agent FROM session_log WHERE id=$sid;")

  check_spec_scope "$spec_dir" "$req_count" "$name" "cannot mark spec ready"
  # The user approves the spec against their own words: requirements.md opens
  # with the request verbatim and the assumptions made to fill its gaps.
  local section
  for section in "Request (verbatim)" "Assumptions"; do
    grep -qF "## $section" "$spec_dir/requirements.md" \
      || { fail "cannot mark spec ready: $spec_dir/requirements.md has no '## $section' section (docs/specs.md \"Request and assumptions\")"; exit 1; }
  done

  local now; now="$(now_iso)"
  local existing_spec_id
  existing_spec_id=$(db "SELECT id FROM specs WHERE feature_id=$fid AND deleted_at IS NULL;")

  local spec_write_sql revised_note=""
  if [ -n "$existing_spec_id" ]; then
    local prev_counts
    prev_counts=$(db "SELECT 'R=' || IFNULL(requirements_count, '?') || ', T=' || IFNULL(tasks_count, '?') FROM specs WHERE id=$existing_spec_id;")
    [ "$prev_counts" != "R=$req_count, T=$task_count" ] && revised_note=", was $prev_counts"
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
  ok "spec ready for review: $spec_dir (feature $fnum $name, R=$req_count, T=$task_count$revised_note)"

  local source_id; source_id=$(db "SELECT source_id FROM features WHERE id=$fid;")
  if [ -n "$source_id" ]; then
    bash "$SCRIPT_DIR/notion_set_status.sh" "$source_id" "$(config '.notion_status_spec_ready' 'Spec Ready')"
  fi
}

cmd_approve_spec() {
  local target="" by=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) by="$2"; shift 2 ;;
      *) target="$1"; shift ;;
    esac
  done
  [ -n "$target" ] || { fail "usage: approve-spec <feature_number|name> [--by <name>]"; exit 1; }

  # Resolution order for --by (post feature-38 audit): explicit --by always
  # wins; else $HARNESS_HUMAN_USER env var (CI/override); else
  # .harness.json::human_user (set by install.sh at install time); else the
  # legacy default "user" so old installs without the config keep working.
  # This is the ONLY command where a literal human name is the correct
  # attribution — subagents don't run it, only the leader does, on behalf
  # of the human who approved the spec in conversation.
  if [ -z "$by" ]; then
    if [ -n "${HARNESS_HUMAN_USER:-}" ]; then
      by="$HARNESS_HUMAN_USER"
    else
      by="$(config '.human_user' '')"
      if [ -z "$by" ]; then
        by="user"
      fi
    fi
  fi

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

  # Recount from the files as they are NOW, not as they were at
  # mark-spec-ready — they may have been edited since, and the counts stored
  # as approved must describe what the human actually read. A missing ready
  # spec falls through to the UPDATE below, which reports it.
  local spec_row count_sql="" counts_note=""
  spec_row=$(sqlite3 -json "$DB_PATH" "SELECT path, requirements_count, tasks_count FROM specs
WHERE feature_id=$fid AND status='ready' AND deleted_at IS NULL;")
  if [ -n "$spec_row" ] && [ "$spec_row" != "[]" ]; then
    local spec_dir prev_req prev_task req_count task_count
    spec_dir=$(jq -r '.[0].path' <<<"$spec_row")
    prev_req=$(jq -r '.[0].requirements_count // "?"' <<<"$spec_row")
    prev_task=$(jq -r '.[0].tasks_count // "?"' <<<"$spec_row")
    for f in requirements.md design.md tasks.md; do
      [ -f "$spec_dir/$f" ] || { fail "not approvable: $spec_dir/$f is missing on disk"; exit 1; }
    done
    read -r req_count task_count <<<"$(spec_counts "$spec_dir")"
    check_spec_scope "$spec_dir" "$req_count" "$(basename "$spec_dir")" "not approvable"
    count_sql=", requirements_count=$req_count, tasks_count=$task_count"
    counts_note="R=$req_count, T=$task_count"
    if [ "$prev_req" != "$req_count" ] || [ "$prev_task" != "$task_count" ]; then
      warn "spec counts changed since mark-spec-ready: R $prev_req→$req_count, T $prev_task→$task_count — recording the current ones"
    fi
  fi

  # UPDATE ... RETURNING against status='ready' is the actual gate here — a
  # second approve-spec, or one run before mark-spec-ready, matches nothing
  # and fails cleanly rather than silently re-stamping approved_at.
  local updated
  updated=$(sqlite3 -json "$DB_PATH" "UPDATE specs SET status='approved', approved_at='$now', approved_by='$(sql_escape "$by")', updated_at='$now'$count_sql
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
  ok "approved spec for feature $target (by: $by${counts_note:+, $counts_note})"
}

cmd_claim() {
  local agent="${HARNESS_AGENT:-unknown}"
  local agent_model=""
  local target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) agent="$2"; shift 2 ;;
      --agent-model) agent_model="$2"; shift 2 ;;
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
  check_row=$(sqlite3 -json "$DB_PATH" "SELECT f.id, f.name, f.sdd, f.status, f.depends_on, s.status AS spec_status
FROM features f LEFT JOIN specs s ON s.feature_id = f.id AND s.deleted_at IS NULL
WHERE $target_where;")

  if [ -n "$check_row" ] && [ "$check_row" != "[]" ]; then
    local sdd_flag status_now name_now spec_status depends_on_now
    sdd_flag=$(jq -r '.[0].sdd' <<<"$check_row")
    status_now=$(jq -r '.[0].status' <<<"$check_row")
    name_now=$(jq -r '.[0].name' <<<"$check_row")
    spec_status=$(jq -r '.[0].spec_status // "none"' <<<"$check_row")
    depends_on_now=$(jq -r '.[0].depends_on // "[]"' <<<"$check_row")

    if [ "$status_now" = "superseded" ]; then
      fail "feature $name_now is superseded — run 'unsupersede $name_now <reason>' first if it really needs its own work"
      exit 1
    fi

    if [ -n "$target" ] && { [ "$status_now" = "in_progress" ] || [ "$status_now" = "blocked" ]; }; then
      claim_resume "$(jq -r '.[0].id' <<<"$check_row")" "$agent" "$agent_model"
      return
    fi

    # Local (same-project) dependency gate: every name listed in depends_on
    # must belong to a feature that is already 'done'. This is what would
    # have caught claiming admin_institutions_cuaderno_seal before
    # cuaderno_foundation_chapter_header_seal_breakpoint had even started —
    # nothing previously checked a feature's own textual "Depende de X"
    # against real feature state. Checked before the sdd checks below since
    # it applies regardless of sdd.
    local unmet=() dep_name dep_status
    while IFS= read -r dep_name; do
      [ -n "$dep_name" ] || continue
      dep_status=$(db "SELECT status FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND name='$(sql_escape "$dep_name")';")
      [ "$dep_status" = "done" ] || unmet+=("$dep_name (${dep_status:-not found})")
    done < <(jq -r '.[]?' <<<"$depends_on_now" 2>/dev/null)
    if [ "${#unmet[@]}" -gt 0 ]; then
      local unmet_list; unmet_list=$(IFS=', '; echo "${unmet[*]}")
      fail "feature $name_now depends on local feature(s) not yet done: $unmet_list — claim/finish those first, or fix depends_on with 'set-depends-on' if it's stale"
      exit 1
    fi

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

  # Same posture for the local dependency gate as sdd_gate above: the real
  # enforcement is this WHERE condition, not the friendlier precheck earlier
  # in the function. depends_on defaults to '[]', so json_each yields no
  # rows and the NOT EXISTS is vacuously true for features with no
  # dependencies declared.
  local deps_gate="NOT EXISTS (SELECT 1 FROM json_each(f.depends_on) dep WHERE dep.value NOT IN (SELECT name FROM features d2 WHERE d2.project_id = f.project_id AND d2.status = 'done' AND d2.deleted_at IS NULL))"

  # Checked before the feature UPDATE: otherwise a claim while another session
  # is active (e.g. a spec_drafting one) flips the feature to in_progress and
  # only then fails on the session INSERT, leaving it in_progress sessionless.
  local active_sid; active_sid="$(current_session_id)"
  if [ -n "$active_sid" ]; then
    if [ -n "$(db "SELECT held_at FROM session_log WHERE id=$active_sid;")" ]; then
      fail "session $active_sid is on hold (see its HOLD entry) — the user decides: 'unhold' to resume it, or 'block' its feature to set it aside, before claiming another"
    else
      fail "session $active_sid is already open — log it out or block its feature before claiming another"
    fi
    exit 1
  fi

  local update_sql
  if [ -n "$target" ]; then
    if [[ "$target" =~ ^[0-9]+$ ]]; then
      update_sql="UPDATE features SET status='in_progress', updated_at='$now'
WHERE id = (SELECT f.id FROM features f WHERE f.project_id='$(sql_escape "$pid")' AND f.deleted_at IS NULL AND f.feature_number=$target AND ($sdd_gate) AND ($deps_gate))"
    else
      update_sql="UPDATE features SET status='in_progress', updated_at='$now'
WHERE id = (SELECT f.id FROM features f WHERE f.project_id='$(sql_escape "$pid")' AND f.deleted_at IS NULL AND f.name='$(sql_escape "$target")' AND ($sdd_gate) AND ($deps_gate))"
    fi
  else
    update_sql="UPDATE features SET status='in_progress', updated_at='$now'
WHERE id = (SELECT f.id FROM features f WHERE f.project_id='$(sql_escape "$pid")' AND f.deleted_at IS NULL AND ($sdd_gate) AND ($deps_gate) ORDER BY f.feature_number LIMIT 1)"
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

  # Resolve the stored agent attribution via the shared helper: explicit
  # --agent (backward compat, e.g. Codex's "leader -> implementer (<model>)"
  # chain string) wins, else auto-format "Claude (<role> agent by <MODEL>)"
  # when a model is known via --agent-model > $HARNESS_AGENT_MODEL >
  # $ANTHROPIC_MODEL, else fall back to $HARNESS_AGENT or "unknown".
  local agent_attribution
  agent_attribution="$(harness_agent_attribution "$agent" "" "$agent_model")"

  db_exec "INSERT INTO session_log (project_id, feature_id, agent, started_at)
VALUES ('$(sql_escape "$pid")', $feature_id, '$(sql_escape "$agent_attribution")', '$now');"
  record_session_base "$(current_session_id)"
  ok "claimed: $(jq -r '.[0] | "\(.feature_number) \(.name) — \(.title)"' <<<"$updated")"
  ok "work folder: $(feature_dir "$(jq -r '.[0].name' <<<"$updated")")/ (handoffs and logs; deleted at log-out)"

  local source_id; source_id=$(jq -r '.[0].source_id // empty' <<<"$updated")
  if [ -n "$source_id" ]; then
    bash "$SCRIPT_DIR/notion_set_status.sh" "$source_id" "$(config '.notion_status_in_progress' 'In Progress')"
  fi
}

# The project's active session. A paused session (its feature is blocked) is
# still open but not current: nothing but unblock/cancel-session acts on it.
current_session_id() {
  local pid; pid="$(project_id)"
  db "SELECT id FROM session_log WHERE project_id='$(sql_escape "$pid")' AND closed_at IS NULL AND deleted_at IS NULL AND paused_at IS NULL LIMIT 1;"
}

# claim_resume <feature_id> <agent> <agent_model> — the explicit-claim path for
# an in_progress/blocked feature that has lost its session (e.g. to
# `cancel-session --force`). Without it nothing could reopen such a feature:
# claim only took pending/spec_ready, reopen only done, unblock never opened a
# session, and log-out needs one. The dependency/spec gates are not re-run —
# the feature already passed them when it was first claimed.
claim_resume() {
  local fid="$1" agent="$2" agent_model="$3"
  local pid; pid="$(project_id)"
  local now; now="$(now_iso)"

  local open_row
  open_row=$(sqlite3 -json "$DB_PATH" "SELECT id, paused_at FROM session_log
WHERE feature_id=$fid AND closed_at IS NULL AND deleted_at IS NULL LIMIT 1;")
  if [ -n "$open_row" ] && [ "$open_row" != "[]" ]; then
    local open_sid; open_sid=$(jq -r '.[0].id' <<<"$open_row")
    if [ -n "$(jq -r '.[0].paused_at // empty' <<<"$open_row")" ]; then
      fail "feature still has paused session $open_sid — run 'unblock <feature>' to resume it instead of claiming"
    else
      fail "feature is already in progress with open session $open_sid — nothing to claim"
    fi
    exit 1
  fi
  local active_sid; active_sid="$(current_session_id)"
  if [ -n "$active_sid" ]; then
    fail "session $active_sid is already open — log it out, block its feature, or cancel it before resuming this one"
    exit 1
  fi

  local prev_sid prev_note resumed
  prev_sid=$(db "SELECT id FROM session_log WHERE feature_id=$fid AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 1;")
  if [ -n "$prev_sid" ]; then
    prev_note=$(db "SELECT entry FROM session_log_entries WHERE session_id=$prev_sid AND entry LIKE 'CANCELLED:%' ORDER BY id DESC LIMIT 1;")
    resumed="RESUMED: previous session $prev_sid was cancelled${prev_note:+ ($prev_note)}"
  else
    resumed="RESUMED: feature had no open session and no cancelled session on record"
  fi

  local agent_attribution
  agent_attribution="$(harness_agent_attribution "$agent" "" "$agent_model")"

  # changes() gates each INSERT on the previous statement having matched, so
  # a feature whose status or sessions changed since the checks above gets no
  # session instead of a stray one; .bail rolls back on an index conflict.
  local out
  out=$(sqlite3 "$DB_PATH" <<SQL 2>&1
.bail on
BEGIN;
UPDATE features SET status='in_progress', updated_at='$now'
  WHERE id=$fid AND status IN ('in_progress','blocked') AND deleted_at IS NULL
    AND NOT EXISTS (SELECT 1 FROM session_log WHERE feature_id=$fid AND closed_at IS NULL AND deleted_at IS NULL);
INSERT INTO session_log (project_id, feature_id, agent, started_at)
  SELECT '$(sql_escape "$pid")', $fid, '$(sql_escape "$agent_attribution")', '$now' WHERE changes() = 1;
INSERT INTO session_log_entries (session_id, entry, created_at)
  SELECT last_insert_rowid(), '$(sql_escape "$resumed")', '$now' WHERE changes() = 1;
COMMIT;
SQL
)
  if [ $? -ne 0 ]; then
    fail "resume failed (is another feature already in_progress?): $out"
    exit 1
  fi
  local new_sid
  new_sid=$(db "SELECT id FROM session_log WHERE feature_id=$fid AND started_at='$now' AND closed_at IS NULL AND deleted_at IS NULL LIMIT 1;")
  if [ -z "$new_sid" ]; then
    fail "resume failed — feature state changed between the check and the claim; re-run 'status' and try again"
    exit 1
  fi

  record_session_base "$new_sid" "$prev_sid"
  local row
  row=$(sqlite3 -json "$DB_PATH" "SELECT feature_number, name, title, source_id FROM features WHERE id=$fid;")
  ok "resumed: $(jq -r '.[0] | "\(.feature_number) \(.name) — \(.title)"' <<<"$row") (new session $new_sid; ${resumed#RESUMED: })"
  warn "any review verdict stayed on the old session — record-review must run again on session $new_sid before log-out"

  local source_id; source_id=$(jq -r '.[0].source_id // empty' <<<"$row")
  if [ -n "$source_id" ]; then
    bash "$SCRIPT_DIR/notion_set_status.sh" "$source_id" "$(config '.notion_status_in_progress' 'In Progress')"
  fi
}

cmd_append_log() {
  local usage="usage: append-log <entry> [--feature TARGET] [--agent NAME] [--agent-model MODEL]"
  local entry="" feature_target="" explicit_agent="" agent_model=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) explicit_agent="$2"; shift 2 ;;
      --agent-model) agent_model="$2"; shift 2 ;;
      --feature) feature_target="$2"; shift 2 ;;
      *)
        [ -z "$entry" ] || { fail "unknown argument: $1"; exit 1; }
        entry="$1"; shift
        ;;
    esac
  done
  [ -n "$entry" ] || { fail "$usage"; exit 1; }

  # --feature writes a feature-level note instead of a session entry, so it
  # works with no open session (e.g. "spec revised per the user's answers"
  # after mark-spec-ready, or a note on a feature that never had a session).
  if [ -n "$feature_target" ]; then
    local pid; pid="$(project_id)"
    [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
    local where
    if [[ "$feature_target" =~ ^[0-9]+$ ]]; then
      where="feature_number=$feature_target"
    else
      where="name='$(sql_escape "$feature_target")'"
    fi
    local frow
    frow=$(sqlite3 -json "$DB_PATH" "SELECT id, feature_number, name FROM features
WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND $where;")
    if [ -z "$frow" ] || [ "$frow" = "[]" ]; then
      fail "no matching feature $feature_target"
      exit 1
    fi
    local attribution
    attribution="$(harness_agent_attribution "${explicit_agent:-leader}" "" "$agent_model")"
    db_exec "INSERT INTO feature_notes (feature_id, entry, created_at)
VALUES ($(jq -r '.[0].id' <<<"$frow"), '$(sql_escape "[$attribution] $entry")', '$(now_iso)');"
    ok "appended note to feature $(jq -r '.[0] | "\(.feature_number) \(.name)"' <<<"$frow") (by: $attribution)"
    return 0
  fi

  local sid; sid="$(current_session_id)"
  [ -n "$sid" ] || { fail "no open session — run 'claim' first, or pass --feature <target> to write a feature-level note"; exit 1; }

  # Determine the role for attribution: explicit --agent wins, else fall back to
  # the session's stored agent (set when claim/claim-spec opened the session),
  # else "unknown". Then build the standardized attribution via the shared
  # helper and prefix the entry so every log line carries agent + model info.
  local role="$explicit_agent"
  if [ -z "$role" ]; then
    role=$(db "SELECT agent FROM session_log WHERE id=$sid;")
  fi
  local attribution
  attribution="$(harness_agent_attribution "$role" "" "$agent_model")"
  local prefixed_entry="[$attribution] $entry"

  db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "$prefixed_entry")', '$(now_iso)');"
  ok "appended log entry to session $sid (by: $attribution)"
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
  local verdict_raw="${1:?usage: record-review <approved|changes-requested> [--by NAME] [--reviewer-model MODEL] [--notes TEXT]}"; shift
  local verdict
  case "$verdict_raw" in
    approved) verdict="approved" ;;
    changes-requested) verdict="changes_requested" ;;
    *) fail "verdict must be 'approved' or 'changes-requested', got: $verdict_raw"; exit 1 ;;
  esac

  local by_explicit="" reviewer_model="" notes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) by_explicit="$2"; shift 2 ;;
      --reviewer-model) reviewer_model="$2"; shift 2 ;;
      --notes) notes="$2"; shift 2 ;;
      *) fail "unknown argument: $1"; exit 1 ;;
    esac
  done

  # --by validation: only the literal prefix "human:<name>" is accepted when a
  # human (not a subagent) records the review. Subagent reviewers must omit
  # --by and let the harness auto-format via $ANTHROPIC_MODEL/$HARNESS_AGENT_MODEL.
  # Bare names like "Ricardo Aguilar" are rejected — that's the spec gate's
  # pattern (approve-spec), not the review gate's. See the doc comment at the
  # top of harness.sh for the full rationale.
  if [ -n "$by_explicit" ]; then
    case "$by_explicit" in
      human:*)
        by_explicit="${by_explicit#human:}"
        # Trim leading whitespace (e.g. "human:  Name" → "Name") using pure POSIX
        by_explicit="${by_explicit#"${by_explicit%%[![:space:]]*}"}"
        [ -n "$by_explicit" ] || { fail "--by 'human:' requires a non-empty name after the prefix"; exit 1; }
        ;;
      *)
        fail "record-review --by must be omitted (auto-attributes as 'Claude/Codex (reviewer agent by <MODEL>)' from \$ANTHROPIC_MODEL) or use the prefix 'human:<name>' when a literal human is the reviewer (e.g. --by 'human:Ricardo Aguilar'). Got: --by '$by_explicit'. If a subagent recorded this review, omit --by entirely."
        exit 1
        ;;
    esac
  fi

  # Resolve --by via the shared helper: explicit --by (backward compat) wins,
  # else auto-format "Claude (reviewer agent by <MODEL>)" when a model is known
  # via --reviewer-model > $HARNESS_AGENT_MODEL > $ANTHROPIC_MODEL, else fall back
  # to $HARNESS_AGENT or "unknown".
  local by
  by="$(harness_agent_attribution reviewer "$by_explicit" "$reviewer_model")"

  local sid; sid="$(current_session_id)"
  [ -n "$sid" ] || { fail "no open session — nothing to review"; exit 1; }
  local now; now="$(now_iso)"

  db_exec "UPDATE session_log SET review_status='$(sql_escape "$verdict")', reviewed_by='$(sql_escape "$by")', reviewed_at='$now' WHERE id=$sid;"
  # The approval covers the code as it is now: log-out refuses it once that
  # code changes (review_verdict).
  local fp; fp="$(tree_fingerprint)" || fp=none
  db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '[harness] REVIEW: $verdict_raw fp=$fp', '$now');"
  if [ -n "$notes" ]; then
    db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "REVIEW ($verdict_raw): $notes")', '$now');"
  fi
  ok "recorded review verdict '$verdict_raw' on session $sid (by: $by)"
}

# is_review_excluded <path> — lockfiles, generated/build output and prose are
# not code a person reviews line by line, so they don't count toward the
# review budget.
# feature_dir <name> — the feature's work folder. Every handoff and log an
# agent writes for one feature lives there, so log-out can delete it as a unit.
feature_dir() {
  printf 'progress/%s' "$1"
}

# clean_feature_dir <name> — deletes progress/<name>/ once the feature no
# longer needs it (done or superseded). harness.db keeps what matters: plan,
# log, verification, closure and the review verdict. Only plain slugs are
# accepted, so a malformed name can never reach outside progress/.
clean_feature_dir() {
  local name="$1" dir
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 0
  dir="$(feature_dir "$name")"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  rm -rf -- "$dir" && ok "removed work folder $dir/"
}

# quick_handoff <name> <number> — the quick handoff that exists, preferring
# progress/<name>/quick.md; the number-named folder and the older flat
# progress/quick_<name|number>.md files are accepted too, since agents have
# used both. Prints the preferred path when none exists.
quick_handoff() {
  local f
  for f in "progress/$1/quick.md" "progress/$2/quick.md" "progress/quick_$1.md" "progress/quick_$2.md"; do
    [ -f "$f" ] && { printf '%s' "$f"; return; }
  done
  printf 'progress/%s/quick.md' "$1"
}

is_review_excluded() {
  case "$1" in
    *.lock|*.lockb|*-lock.json|*-lock.yaml|*.lock.json|go.sum|*.min.js|*.min.css|*.map|*.snap) return 0 ;;
    dist/*|*/dist/*|build/*|*/build/*|*.generated.*|*/generated/*) return 0 ;;
    *.md|progress/*|specs/*|state/*) return 0 ;;
  esac
  return 1
}

# is_test_path <path> — test files are reported separately from production code.
is_test_path() {
  case "$1" in
    tests/*|*/tests/*|test/*|*/test/*|*/__tests__/*|*.spec.*|*.test.*|*_test.*|test_*|*/test_*) return 0 ;;
  esac
  return 1
}

# record_session_base <session_id> — logs the git HEAD a session starts from,
# so record_diff_size still sees work the implementer commits before log-out,
# plus a DIRTY entry with the files already uncommitted at that point, so the
# quick gate doesn't count them as this session's work. No-op outside git or
# before the first commit. Given the cancelled session a resume replaces, it
# copies that session's entries instead: the feature's own work so far counts.
record_session_base() {
  local sid="$1" prev="${2:-}" sha dirty
  [ -n "$sid" ] || return 0
  if [ -n "$prev" ] && [ -n "$(db "SELECT 1 FROM session_log_entries WHERE session_id=$prev AND entry LIKE '[harness] BASE: %' LIMIT 1;")" ]; then
    db_exec "INSERT INTO session_log_entries (session_id, entry, created_at)
      SELECT $sid, entry, '$(now_iso)' FROM session_log_entries
      WHERE session_id=$prev AND (entry LIKE '[harness] BASE: %' OR entry LIKE '[harness] DIRTY:%') ORDER BY id;"
    return 0
  fi
  sha=$(git rev-parse --verify --quiet HEAD 2>/dev/null) || return 0
  db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '[harness] BASE: $sha', '$(now_iso)');"
  dirty=$(dirty_listing HEAD -w)
  [ -z "$dirty" ] || db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "[harness] DIRTY:
$dirty")', '$(now_iso)');"
}

# dirty_listing <base> — one "<blob hash> <path>" line per file under this
# project that differs from <base> or is untracked ("deleted" for a removed
# file), skipping progress/ and the snapshot, which the harness rewrites.
# With -w the contents are also stored in git's object database, so the
# session can later measure its own changes against them (session_file_lines).
dirty_listing() {
  local file write="${2:-}"
  { git diff --name-only --relative "$1" -- . 2>/dev/null; git ls-files --others --exclude-standard -- . 2>/dev/null; } \
    | while IFS= read -r file; do
        case "$file" in ""|progress/*|"$SNAPSHOT_PATH"/*) continue ;; esac
        if [ -f "$file" ]; then printf '%s %s\n' "$(git hash-object $write -- "$file" 2>/dev/null || git hash-object -- "$file")" "$file"; else printf 'deleted %s\n' "$file"; fi
      done
}

# session_file_lines <base> <claim listing> <file> — lines this session
# changed in <file>. A file already uncommitted at claim is measured against
# its contents then (kept by record_session_base), not against <base>, so work
# left uncommitted by an earlier feature doesn't count; 0 if untouched since.
# Otherwise: the diff against <base>, or the whole file when it is new.
# Binary files count 0.
session_file_lines() {
  local base="$1" before="$2" file="$3" old new added deleted _ n=0
  old=$(while IFS= read -r line; do [ "${line#* }" = "$file" ] && { echo "${line%% *}"; break; }; done <<<"$before")
  if [ -n "$old" ] && [ "$old" != deleted ] && git cat-file -e "$old" 2>/dev/null; then
    if [ -f "$file" ]; then new=$(git hash-object -w -- "$file"); else new=$(git hash-object -w /dev/null); fi
    [ "$new" != "$old" ] || { echo 0; return; }
    read -r added deleted _ < <(git diff --numstat "$old" "$new" 2>/dev/null)
  elif [ "$old" != deleted ] && { git cat-file -e "$base:./$file" 2>/dev/null || git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; }; then
    read -r added deleted _ < <(git diff --numstat --relative "$base" -- "$file" 2>/dev/null)
  elif [ -f "$file" ]; then
    added=$(wc -l < "$file" | tr -d ' '); deleted=0
  fi
  [[ "${added:-}" =~ ^[0-9]+$ && "${deleted:-}" =~ ^[0-9]+$ ]] && n=$((added + deleted))
  echo "$n"
}

# session_claim_listing <session_id> — the DIRTY listing logged at claim
# (empty when the tree was clean then).
session_claim_listing() {
  db "SELECT substr(entry, 18) FROM session_log_entries WHERE session_id=$1 AND entry LIKE '[harness] DIRTY:%' ORDER BY id LIMIT 1;"
}

# session_diff_base <session_id> — prints "<base>\t<scope note>": the
# session's BASE commit, or HEAD without one. A base outside HEAD's history
# (branch switched or rebased mid-feature) would count unrelated differences
# between branches, so HEAD is used and the note says only uncommitted changes
# are measured.
session_diff_base() {
  local base scope=""
  base=$(db "SELECT substr(entry, 17) FROM session_log_entries WHERE session_id=$1 AND entry LIKE '[harness] BASE: %' ORDER BY id LIMIT 1;")
  if ! git cat-file -e "${base:-none}^{commit}" 2>/dev/null; then
    base=HEAD
  elif ! git merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
    base=HEAD; scope=", uncommitted only: session base not in this branch's history"
  fi
  printf '%s\t%s\n' "$base" "$scope"
}

# record_diff_size <session_id> <path...> — advisory review budget: counts
# the lines this session changed (session_file_lines) in the paths log-out was
# given, split into production code and tests,
# logs a DIFF entry on the session (data for calibrating future splits) and
# warns when code exceeds .harness.json::review_budget_lines (default 400; 0
# disables the warning). Never blocks: outside git or with no paths it's a no-op.
record_diff_size() {
  local sid="$1"; shift
  [ $# -gt 0 ] || return 0
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  local code=0 tests=0 files=0 path file n base scope before
  IFS=$'\t' read -r base scope < <(session_diff_base "$sid")
  before=$(session_claim_listing "$sid")
  for path in "$@"; do
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      is_review_excluded "$file" && continue
      n=$(session_file_lines "$base" "$before" "$file")
      [ "$n" -gt 0 ] || continue  # binary, or uncommitted at claim and untouched since
      files=$((files + 1))
      if is_test_path "$file"; then tests=$((tests + n)); else code=$((code + n)); fi
    done < <(git diff --name-only --relative "$base" -- "$path" 2>/dev/null; git ls-files --others --exclude-standard -- "$path" 2>/dev/null)
  done
  [ "$files" -gt 0 ] || return 0

  local budget; budget="$(config '.review_budget_lines' '400')"
  [[ "$budget" =~ ^[0-9]+$ ]] || budget=400
  # Some projects keep their tests out of git on purpose (.git/info/exclude):
  # git can't see them, so 0 would read as "no tests were written".
  local tests_note="$tests lines" d
  if [ "$tests" = 0 ]; then
    for d in tests test spec __tests__; do
      if [ -d "$d" ] && git check-ignore -q -- "$d/" 2>/dev/null; then tests_note="n/a ($d/ is ignored by git)"; break; fi
    done
  fi
  local entry="DIFF: code=$code lines, tests=$tests_note, files=$files (review_budget_lines=$budget$scope)"
  db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "[harness] $entry")', '$(now_iso)');"
  ok "$entry"
  if [ "$budget" -gt 0 ] && [ "$code" -gt "$budget" ]; then
    warn "production diff ($code lines) exceeds review_budget_lines=$budget — hard to review in one pass; split similar features smaller next time (advisory, not blocking)"
  fi
}

# is_dependency_file <path> — manifests and lockfiles: a change there affects
# the whole project, so it always needs a reviewer.
is_dependency_file() {
  case "${1##*/}" in
    package.json|*.lock|*.lockb|*-lock.json|*-lock.yaml|requirements*.txt|pyproject.toml|Pipfile|setup.py|setup.cfg) return 0 ;;
    go.mod|go.sum|Cargo.toml|Gemfile|*.gemspec|composer.json|pom.xml|build.gradle|build.gradle.kts|*.csproj|packages.config) return 0 ;;
  esac
  return 1
}

# tree_fingerprint — git tree hash of this project's files as they are on
# disk, tracked and untracked (progress/, the snapshot and harness.db
# excluded: the harness itself rewrites them), so log-out can tell whether the
# last ./init.sh and the reviewer's approval saw the code it closes. It hashes
# contents only, so committing them, or a commit elsewhere in the repository,
# doesn't change it. Built in a throwaway copy of the index and a throwaway
# object directory (the real objects are only read, as alternates), so it gives
# the same answer where .git is read-only, as in the Codex sandbox.
tree_fingerprint() {
  git rev-parse --git-dir >/dev/null 2>&1 || return 1
  local tmp objects prefix tree
  tmp=$(mktemp -d) && mkdir "$tmp/objects" || return 1
  objects=$(cd "$(git rev-parse --git-path objects)" && pwd -P) || { rm -rf "$tmp"; return 1; }
  cp "$(git rev-parse --git-path index)" "$tmp/index" 2>/dev/null
  prefix=$(git rev-parse --show-prefix 2>/dev/null)
  # add exits 1 when an exclude names an ignored path (harness.db, progress/)
  # though it staged everything else, so its status is not checked.
  GIT_INDEX_FILE="$tmp/index" GIT_OBJECT_DIRECTORY="$tmp/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects" \
    git add -A -- . ":(exclude)progress" ":(exclude)$SNAPSHOT_PATH" ":(exclude)$DB_PATH*" >/dev/null 2>&1
  tree=$(GIT_INDEX_FILE="$tmp/index" GIT_OBJECT_DIRECTORY="$tmp/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects" \
    git write-tree ${prefix:+--prefix="$prefix"} 2>/dev/null)
  rm -rf "$tmp"
  [ -n "$tree" ] || return 1
  printf '%s\n' "$tree"
}

# record-init <pass|fail|none> — init.sh calls this after its verify step: logs
# the result (none = green but no verify_command) with the tree fingerprint on
# the active session (no-op without one).
cmd_record_init() {
  case "${1:-}" in pass|fail|none) ;; *) fail "usage: record-init <pass|fail|none>"; exit 1 ;; esac
  local sid; sid="$(current_session_id)"
  [ -n "$sid" ] || return 0
  local fp; fp="$(tree_fingerprint)" || fp=none
  db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '[harness] INIT: $1 fp=$fp', '$(now_iso)');"
}

# init_verdict <session_id> — the last ./init.sh recorded on the session,
# checked against the tree now: pass | none | missing | failed | stale. Outside
# git there is no fingerprint, so a pass can't go stale.
init_verdict() {
  local last fp
  last=$(db "SELECT entry FROM session_log_entries WHERE session_id=$1 AND entry LIKE '[harness] INIT: %' ORDER BY id DESC LIMIT 1;")
  case "$last" in
    "") echo missing ;;
    "[harness] INIT: pass"*)
      fp="$(tree_fingerprint)" || fp=none
      if [ "$fp" = none ] || [ "$last" = "[harness] INIT: pass fp=$fp" ]; then echo pass; else echo stale; fi ;;
    "[harness] INIT: none"*) echo none ;;
    *) echo failed ;;
  esac
}

# review_verdict <session_id> — whether the recorded approval covers the tree
# now: current | stale | legacy (approved before approvals carried a
# fingerprint). Outside git there is no fingerprint, so it can't go stale.
review_verdict() {
  local last fp
  last=$(db "SELECT entry FROM session_log_entries WHERE session_id=$1 AND entry LIKE '[harness] REVIEW: approved fp=%' ORDER BY id DESC LIMIT 1;")
  [ -n "$last" ] || { echo legacy; return; }
  fp="$(tree_fingerprint)" || fp=none
  if [ "$fp" = none ] || [ "$last" = "[harness] REVIEW: approved fp=none" ] || [ "$last" = "[harness] REVIEW: approved fp=$fp" ]; then
    echo current
  else
    echo stale
  fi
}

# quick_gate <session_id> <feature_name> <feature_number> — the signals
# log-out --quick checks itself instead of trusting the agent. Fills
# QUICK_REASONS (empty = pass), QUICK_LINES and QUICK_FILES. Size, files and
# dependencies come from git against the session base; Risk and the declared
# files from the handoff (see quick_handoff); the init result from
# record-init's fingerprint.
quick_gate() {
  local sid="$1" handoff; handoff="$(quick_handoff "$2" "$3")"
  QUICK_REASONS=(); QUICK_LINES=0; QUICK_FILES=0
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    QUICK_REASONS+=("not a git repository: the change can't be measured"); return
  fi
  local max_lines max_files
  max_lines="$(config '.quick_max_diff_lines' '80')"; [[ "$max_lines" =~ ^[0-9]+$ ]] || max_lines=80
  max_files="$(config '.quick_max_files' '4')"; [[ "$max_files" =~ ^[0-9]+$ ]] || max_files=4

  # Files already uncommitted at claim and untouched since (same blob) are not
  # this session's work; one touched further counts only what changed since.
  local base scope file changed=() before line
  IFS=$'\t' read -r base scope < <(session_diff_base "$sid")
  [ -z "$scope" ] || QUICK_REASONS+=("the session base is not in this branch's history: the change can't be measured")
  before=$(session_claim_listing "$sid")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF -- "$line" <<<"$before" || changed+=("${line#* }")
  done < <(dirty_listing "$base")
  for file in "${changed[@]+"${changed[@]}"}"; do
    QUICK_LINES=$((QUICK_LINES + $(session_file_lines "$base" "$before" "$file")))
  done
  QUICK_FILES=${#changed[@]}

  [ "$QUICK_LINES" -le "$max_lines" ] || QUICK_REASONS+=("$QUICK_LINES changed lines > quick_max_diff_lines=$max_lines")
  [ "$QUICK_FILES" -le "$max_files" ] || QUICK_REASONS+=("$QUICK_FILES changed files > quick_max_files=$max_files")
  for file in "${changed[@]+"${changed[@]}"}"; do
    is_dependency_file "$file" && QUICK_REASONS+=("dependency file changed: $file")
  done

  if [ ! -f "$handoff" ]; then
    QUICK_REASONS+=("handoff $handoff is missing")
  else
    local risk declared
    risk=$(sed -n 's/^Risk:[[:space:]]*//p' "$handoff" | head -n 1 | tr -d '\r`' | sed 's/[[:space:]]*$//')
    [ "$(tr '[:upper:]' '[:lower:]' <<<"$risk")" = none ] || QUICK_REASONS+=("Risk: ${risk:-missing} (only 'none' closes without a reviewer)")
    declared=" $(grep -E '^(Archivos|Files):' "$handoff" | sed -E 's/^[^:]+:[[:space:]]*//' | tr ',`' '  ' | tr -s '[:space:]' ' ') "
    for file in "${changed[@]+"${changed[@]}"}"; do
      [[ "$declared" == *" $file "* ]] || QUICK_REASONS+=("changed but not declared in $handoff: $file")
    done
  fi

  case "$(init_verdict "$sid")" in
    pass) ;;
    missing) QUICK_REASONS+=("./init.sh has not passed in this session") ;;
    stale) QUICK_REASONS+=("files changed after the last passing ./init.sh") ;;
    none) QUICK_REASONS+=("./init.sh ran without a verify_command") ;;
    *) QUICK_REASONS+=("the last ./init.sh failed") ;;
  esac
}

cmd_log_out() {
  local changes=() verification="" closure="" quick=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --quick) quick=1; shift ;;
      --changes)
        shift
        while [ $# -gt 0 ] && [ "$1" != "--verification" ] && [ "$1" != "--closure" ] && [ "$1" != "--quick" ]; do
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
  if [ -n "$(db "SELECT held_at FROM session_log WHERE id=$sid;")" ]; then
    fail "cannot log out session $sid: it is on hold (see its HOLD entry) — only the user can release it with 'unhold'"
    exit 1
  fi
  local review_status; review_status=$(db "SELECT review_status FROM session_log WHERE id=$sid;")

  # --quick: a small feature closes without a reviewer only when every signal
  # in quick_gate is clean. A refusal is logged and means "launch the
  # reviewer", never "work around it". A reviewer's approval, if one already
  # exists, simply wins; their requested changes are never bypassed.
  if [ "$quick" = 1 ] && [ "$review_status" != "approved" ]; then
    local fname fsize fnum
    IFS='|' read -r fname fsize fnum < <(db "SELECT f.name, f.size, f.feature_number FROM features f JOIN session_log sl ON sl.feature_id=f.id WHERE sl.id=$sid;")
    if [ "$fsize" != "small" ]; then
      fail "log-out --quick is only for features marked small (feature $fname is ${fsize:-unknown}) — use the reviewer path"
      exit 1
    fi
    if [ "$review_status" = "changes_requested" ]; then
      fail "log-out --quick refused: a reviewer already requested changes on session $sid — it needs their approval"
      exit 1
    fi
    quick_gate "$sid" "$fname" "$fnum"
    if [ "${#QUICK_REASONS[@]}" -gt 0 ]; then
      local joined; joined=$(printf '%s; ' "${QUICK_REASONS[@]}"); joined="${joined%; }"
      db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "[harness] QUICK: refused — $joined")', '$(now_iso)');"
      fail "log-out --quick refused — reviewer required:"
      printf '  - %s\n' "${QUICK_REASONS[@]}" >&2
      exit 1
    fi
    db_exec "UPDATE session_log SET review_status='quick', reviewed_by='harness (quick gate)', reviewed_at='$(now_iso)' WHERE id=$sid;
INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '[harness] QUICK: passed (lines=$QUICK_LINES, files=$QUICK_FILES)', '$(now_iso)');"
    ok "quick gate passed: $QUICK_LINES lines, $QUICK_FILES files, Risk: none, ./init.sh green"
    review_status=quick
  fi

  if [ "$review_status" != "approved" ] && [ "$review_status" != "quick" ]; then
    fail "cannot log out session $sid: no recorded reviewer approval (review_status=${review_status:-none}) — the reviewer must run 'scripts/harness.sh record-review approved' first (do NOT pass --by; the harness auto-attributes from \$ANTHROPIC_MODEL); only the implementer runs log-out, and only after that approval is recorded"
    exit 1
  fi

  # The reviewer approved a specific state of the code: a change after it
  # (a fix nobody reviewed) needs the reviewer again.
  if [ "$review_status" = "approved" ]; then
    case "$(review_verdict "$sid")" in
      current) ;;
      legacy) warn "the approval on session $sid predates review fingerprints: it can't be checked against the code being closed" ;;
      *) fail "cannot log out session $sid: files changed after the reviewer approved them — the reviewer must review the change and record its verdict again"; exit 1 ;;
    esac
  fi

  # Whoever ran it, the full suite must have passed on exactly the code being
  # closed: a change after the reviewer's ./init.sh needs another run.
  case "$(init_verdict "$sid")" in
    pass) ;;
    none) warn "no verify_command in .harness.json: closing without a test suite" ;;
    missing) fail "cannot log out session $sid: ./init.sh has not run in this session — run it and log out once it is green"; exit 1 ;;
    stale) fail "cannot log out session $sid: files changed after the last passing ./init.sh — run it again and log out once it is green"; exit 1 ;;
    *) fail "cannot log out session $sid: the last ./init.sh failed — fix it (a reviewer approval doesn't cover a red suite) and re-run it"; exit 1 ;;
  esac

  # "${arr[@]+"${arr[@]}"}" rather than "${arr[@]:-}": same reason as in
  # cmd_add_feature — ':-' turns an empty array into [""], bare "${arr[@]}"
  # trips `set -u` on bash 3.2.
  local changes_json; changes_json=$(json_array "${changes[@]+"${changes[@]}"}")
  record_diff_size "$sid" "${changes[@]+"${changes[@]}"}"
  local now; now="$(now_iso)"

  sqlite3 "$DB_PATH" <<SQL
.bail on
BEGIN;
UPDATE session_log SET changes='$(sql_escape "$changes_json")', verification='$(sql_escape "$verification")',
  closure='$(sql_escape "$closure")', closed_at='$now' WHERE id=$sid AND review_status IN ('approved','quick') AND held_at IS NULL;
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
  clean_feature_dir "$(db "SELECT name FROM features WHERE id = (SELECT feature_id FROM session_log WHERE id=$sid);")"

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
  # claimed).
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
  local fid; fid=$(jq -r '.[0].id' <<<"$updated")

  # The feature's own session is paused, not closed: it stays open (log, plan
  # and review verdict intact) for unblock to resume, but frees the project's
  # one-session slot so other work can be claimed meanwhile. The reason goes
  # on that session — not on whatever session happens to be current — so
  # check-blockers finds its BLOCKED_ON note.
  local sid
  sid=$(db "SELECT id FROM session_log WHERE feature_id=$fid AND closed_at IS NULL AND deleted_at IS NULL AND paused_at IS NULL LIMIT 1;")
  if [ -n "$sid" ]; then
    db_exec "UPDATE session_log SET paused_at='$now', held_at=NULL WHERE id=$sid;
INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "$reason")', '$now');"
    ok "blocked: $(jq -r '.[0] | "\(.feature_number) \(.name) — \(.title)"' <<<"$updated") (session $sid paused)"
  else
    db_exec "INSERT INTO feature_notes (feature_id, entry, created_at) VALUES ($fid, '$(sql_escape "$reason")', '$now');"
    ok "blocked: $(jq -r '.[0] | "\(.feature_number) \(.name) — \(.title)"' <<<"$updated")"
    warn "feature had no open session — reason saved as a feature note; after unblocking, 'claim <feature>' opens a new session"
  fi
}

# hold <reason...> — stop the active session when the user rejects an
# escalation. Unlike block it keeps the project's slot: claim refuses other
# features and log-out refuses this one until the user decides (unhold).
cmd_hold() {
  local reason="$*"
  [ -n "$reason" ] || { fail "usage: hold <reason...>"; exit 1; }
  local sid; sid="$(current_session_id)"
  [ -n "$sid" ] || { fail "no active session to hold"; exit 1; }
  local now; now="$(now_iso)"
  db_exec "UPDATE session_log SET held_at='$now' WHERE id=$sid;
INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "HOLD: $reason")', '$now');"
  ok "session $sid on hold — no other feature is claimable until the user runs 'unhold' (resume) or blocks it"
}

# unhold [reason...] — the user resumes a held session.
cmd_unhold() {
  local reason="${*:-resumed}"
  local sid; sid="$(current_session_id)"
  [ -n "$sid" ] && [ -n "$(db "SELECT held_at FROM session_log WHERE id=$sid;")" ] \
    || { fail "no held session to release"; exit 1; }
  local now; now="$(now_iso)"
  db_exec "UPDATE session_log SET held_at=NULL WHERE id=$sid;
INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "UNHOLD: $reason")', '$now');"
  ok "session $sid released from hold"
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

  local row
  row=$(sqlite3 -json "$DB_PATH" "SELECT id, feature_number, name, title FROM features
WHERE project_id='$(sql_escape "$pid")' AND status='blocked' AND deleted_at IS NULL AND $where;")
  if [ "$row" = "[]" ] || [ -z "$row" ]; then
    fail "not unblockable: no matching blocked feature"
    exit 1
  fi
  local fid fname; fid=$(jq -r '.[0].id' <<<"$row"); fname=$(jq -r '.[0].name' <<<"$row")

  # unblock resumes the feature's session; it never opens one. Flipping a
  # sessionless feature to in_progress (as it used to) leaves it stranded:
  # nothing can log it out. Point at claim, which opens a fresh session.
  local sid
  sid=$(db "SELECT id FROM session_log WHERE feature_id=$fid AND closed_at IS NULL AND deleted_at IS NULL LIMIT 1;")
  if [ -z "$sid" ]; then
    fail "feature $fname has no open session to resume (was it cancelled?) — run 'scripts/harness.sh claim $fname' instead: it opens a new session and logs RESUMED"
    exit 1
  fi

  local active_sid; active_sid="$(current_session_id)"
  if [ -n "$active_sid" ] && [ "$active_sid" != "$sid" ]; then
    fail "session $active_sid is already open — log it out or block its feature before unblocking $fname"
    exit 1
  fi

  # Respects the same unique indexes cmd_claim does (one in_progress feature,
  # one active session); .bail rolls both statements back together.
  local out
  out=$(sqlite3 "$DB_PATH" <<SQL 2>&1
.bail on
BEGIN;
UPDATE features SET status='in_progress', updated_at='$now' WHERE id=$fid AND status='blocked';
UPDATE session_log SET paused_at=NULL WHERE id=$sid;
INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, 'UNBLOCKED: session resumed', '$now');
COMMIT;
SQL
)
  if [ $? -ne 0 ]; then
    fail "unblock failed (is another feature already in_progress?): $out"
    exit 1
  fi
  ok "unblocked: $(jq -r '.[0] | "\(.feature_number) \(.name) — \(.title)"' <<<"$row") (session $sid resumed)"
}

cmd_cancel_session() {
  local force=0
  if [ "${1:-}" = "--force" ]; then force=1; shift; fi
  local sid="${1:?usage: cancel-session [--force] <session_id> <reason...>}"; shift || true
  local reason="$*"
  [ -n "$reason" ] || { fail "usage: cancel-session [--force] <session_id> <reason...>"; exit 1; }
  [[ "$sid" =~ ^[0-9]+$ ]] || { fail "session_id must be numeric"; exit 1; }

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local now; now="$(now_iso)"

  # cancel-session discards a session that never produced real work (e.g. a
  # claim killed mid-flight before any plan/log/changes) — it soft-deletes the
  # session_log row (deleted_at, not closed_at: closed_at means "a completed
  # history entry", which this never was) so the one_open_session_per_project
  # unique index frees up again without ever touching feature status. Unlike
  # `block`, it is NOT for abandoning genuine in-flight work — by default it
  # refuses unless the session's feature is missing or itself soft-deleted;
  # --force overrides that for any other confirmed case.
  local row
  row=$(sqlite3 -json "$DB_PATH" "SELECT sl.id, sl.feature_id, f.deleted_at AS feature_deleted_at
FROM session_log sl LEFT JOIN features f ON f.id = sl.feature_id
WHERE sl.id=$sid AND sl.project_id='$(sql_escape "$pid")' AND sl.closed_at IS NULL AND sl.deleted_at IS NULL;")
  if [ "$row" = "[]" ] || [ -z "$row" ]; then
    fail "not cancelable: no open session $sid in this project"
    exit 1
  fi
  local feature_id feature_deleted_at
  feature_id=$(jq -r '.[0].feature_id // empty' <<<"$row")
  feature_deleted_at=$(jq -r '.[0].feature_deleted_at // empty' <<<"$row")
  if [ "$force" != "1" ] && [ -n "$feature_id" ] && [ -z "$feature_deleted_at" ]; then
    fail "session $sid is linked to a feature that still exists — refusing to cancel without --force; if you mean to abandon in-progress work use 'block' instead, or pass --force if you're sure"
    exit 1
  fi

  db_exec "INSERT INTO session_log_entries (session_id, entry, created_at) VALUES ($sid, '$(sql_escape "CANCELLED: $reason")', '$now');"

  local updated
  updated=$(sqlite3 -json "$DB_PATH" "UPDATE session_log SET deleted_at='$now'
WHERE id=$sid AND project_id='$(sql_escape "$pid")' AND closed_at IS NULL AND deleted_at IS NULL
RETURNING id;" 2>&1)
  if [ $? -ne 0 ]; then
    fail "cancel-session failed: $updated"
    exit 1
  fi
  if [ "$updated" = "[]" ] || [ -z "$updated" ]; then
    fail "cancel-session failed for session $sid — state changed between check and cancel; re-run 'status' and try again"
    exit 1
  fi
  ok "cancelled session $sid"
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
  # closed_at-stamped) — mirrors cmd_claim's session INSERT. Use the same
  # auto-format helper so the stored `agent` matches claim/claim-spec's format
  # (post feature-38 audit: previously this stored the bare role/env var
  # instead of "Claude (<role> agent by <MODEL>)").
  local agent="${HARNESS_AGENT:-leader}"
  local agent_model=""
  agent="$(harness_agent_attribution "$agent" "" "$agent_model")"
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

cmd_supersede() {
  local usage="usage: supersede <feature_number|name> --by <feature_number|name> --reason <text>"
  local target="" by_target="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) by_target="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      *)
        [ -z "$target" ] || { fail "unknown argument: $1"; exit 1; }
        target="$1"; shift
        ;;
    esac
  done
  if [ -z "$target" ] || [ -z "$by_target" ] || [ -z "$reason" ]; then
    fail "$usage"
    exit 1
  fi

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local now; now="$(now_iso)"

  local where by_where
  if [[ "$target" =~ ^[0-9]+$ ]]; then where="feature_number=$target"; else where="name='$(sql_escape "$target")'"; fi
  if [[ "$by_target" =~ ^[0-9]+$ ]]; then by_where="feature_number=$by_target"; else by_where="name='$(sql_escape "$by_target")'"; fi

  local row by_row
  row=$(sqlite3 -json "$DB_PATH" "SELECT id, feature_number, name, status, source_id FROM features
WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND $where;")
  [ -n "$row" ] && [ "$row" != "[]" ] || { fail "not supersedable: no matching feature $target"; exit 1; }
  by_row=$(sqlite3 -json "$DB_PATH" "SELECT id, feature_number, name, status FROM features
WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND $by_where;")
  [ -n "$by_row" ] && [ "$by_row" != "[]" ] || { fail "no matching feature $by_target for --by"; exit 1; }

  local fid fnum fname status_now by_fid by_label
  fid=$(jq -r '.[0].id' <<<"$row")
  fnum=$(jq -r '.[0].feature_number' <<<"$row")
  fname=$(jq -r '.[0].name' <<<"$row")
  status_now=$(jq -r '.[0].status' <<<"$row")
  by_fid=$(jq -r '.[0].id' <<<"$by_row")
  by_label=$(jq -r '.[0] | "\(.feature_number) \(.name)"' <<<"$by_row")
  [ "$fid" != "$by_fid" ] || { fail "feature $fname cannot supersede itself"; exit 1; }
  if [ "$(jq -r '.[0].status' <<<"$by_row")" = "superseded" ]; then
    fail "feature $by_label is itself superseded — pass the feature that actually carries the work"
    exit 1
  fi

  # Only features with no work in flight: in_progress/blocked always hold the
  # project's open session, and a spec_drafting one might. done is final.
  # Anything with an open session must be closed through its own lifecycle
  # (log-out, or block + a later decision) before it can be superseded.
  case "$status_now" in
    pending|spec_drafting|spec_ready) ;;
    *) fail "not supersedable: feature $fnum $fname is '$status_now' (only pending/spec_drafting/spec_ready)"; exit 1 ;;
  esac
  local open_on_it
  open_on_it=$(db "SELECT id FROM session_log WHERE feature_id=$fid AND closed_at IS NULL AND deleted_at IS NULL LIMIT 1;")
  [ -z "$open_on_it" ] || { fail "not supersedable: session $open_on_it is still open on feature $fnum $fname — close it first"; exit 1; }

  local updated
  updated=$(sqlite3 -json "$DB_PATH" "UPDATE features SET status='superseded', superseded_by='$(sql_escape "$(jq -r '.[0].name' <<<"$by_row")")',
  superseded_from=status, updated_at='$now'
WHERE id=$fid AND status='$(sql_escape "$status_now")' AND deleted_at IS NULL
RETURNING id;" 2>&1)
  if [ $? -ne 0 ]; then
    fail "supersede failed: $updated"
    exit 1
  fi
  if [ "$updated" = "[]" ] || [ -z "$updated" ]; then
    fail "supersede failed for feature $fnum $fname — state changed between check and update; re-run 'status' and try again"
    exit 1
  fi

  local attribution; attribution="$(harness_agent_attribution "${HARNESS_AGENT:-leader}" "" "")"
  db_exec "INSERT INTO feature_notes (feature_id, entry, created_at)
VALUES ($fid, '$(sql_escape "[$attribution] SUPERSEDED by $by_label (was $status_now): $reason")', '$now');"
  ok "superseded: $fnum $fname → $by_label (was $status_now)"
  clean_feature_dir "$fname"

  # A dependent can never be claimed while its depends_on names a feature
  # that will never be 'done' — don't rewrite it silently, just say so.
  local dependents
  dependents=$(db "SELECT f.feature_number || ' ' || f.name FROM features f, json_each(f.depends_on) dep
WHERE f.project_id='$(sql_escape "$pid")' AND f.deleted_at IS NULL AND f.status <> 'done' AND dep.value='$(sql_escape "$fname")';")
  if [ -n "$dependents" ]; then
    warn "these features depend on $fname and can't be claimed until their depends_on is fixed (e.g. point them at $(jq -r '.[0].name' <<<"$by_row") with 'set-depends-on'): $(tr '\n' ',' <<<"$dependents" | sed 's/,$//; s/,/, /g')"
  fi

  local source_id; source_id=$(jq -r '.[0].source_id // empty' <<<"$row")
  if [ -n "$source_id" ]; then
    bash "$SCRIPT_DIR/notion_set_status.sh" "$source_id" "$(config '.notion_status_superseded' 'Done')"
  fi
}

cmd_unsupersede() {
  local target="${1:?usage: unsupersede <feature_number|name> <reason...>}"; shift
  local reason="$*"
  [ -n "$reason" ] || { fail "usage: unsupersede <feature_number|name> <reason...>"; exit 1; }

  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local now; now="$(now_iso)"

  local where
  if [[ "$target" =~ ^[0-9]+$ ]]; then where="feature_number=$target"; else where="name='$(sql_escape "$target")'"; fi

  # Restores the exact status supersede recorded (pending/spec_drafting/
  # spec_ready — none of which hold a session, so no index can conflict).
  local updated
  updated=$(sqlite3 -json "$DB_PATH" "UPDATE features SET status=COALESCE(superseded_from, 'pending'),
  superseded_by=NULL, superseded_from=NULL, updated_at='$now'
WHERE project_id='$(sql_escape "$pid")' AND status='superseded' AND deleted_at IS NULL AND $where
RETURNING id, feature_number, name, status, source_id;" 2>&1)
  if [ $? -ne 0 ]; then
    fail "unsupersede failed: $updated"
    exit 1
  fi
  if [ "$updated" = "[]" ] || [ -z "$updated" ]; then
    fail "not unsupersedable: no matching superseded feature"
    exit 1
  fi

  local fid status_back
  fid=$(jq -r '.[0].id' <<<"$updated")
  status_back=$(jq -r '.[0].status' <<<"$updated")
  local attribution; attribution="$(harness_agent_attribution "${HARNESS_AGENT:-leader}" "" "")"
  db_exec "INSERT INTO feature_notes (feature_id, entry, created_at)
VALUES ($fid, '$(sql_escape "[$attribution] UNSUPERSEDED (back to $status_back): $reason")', '$now');"
  ok "unsuperseded: $(jq -r '.[0] | "\(.feature_number) \(.name)"' <<<"$updated") (back to $status_back)"

  if [ -n "$(jq -r '.[0].source_id // empty' <<<"$updated")" ]; then
    warn "its Notion card was not changed — move it back to the right column by hand"
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
    # block writes it as a feature note instead when the feature had no session.
    note=$(sqlite3 "$DB_PATH" "SELECT entry FROM (
  SELECT sle.entry, sle.created_at FROM session_log_entries sle
  JOIN session_log sl ON sl.id = sle.session_id
  WHERE sl.feature_id=$fid AND sle.deleted_at IS NULL AND sle.entry LIKE '%BLOCKED_ON:%'
  UNION ALL
  SELECT entry, created_at FROM feature_notes
  WHERE feature_id=$fid AND deleted_at IS NULL AND entry LIKE '%BLOCKED_ON:%'
) ORDER BY created_at DESC LIMIT 1;")

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

# learn [--feature TARGET] <note...> — keep one short lesson for later
# features (at most 300 characters). Linked to the active session's feature
# unless --feature names another.
cmd_learn() {
  local target=""
  if [ "${1:-}" = "--feature" ]; then target="${2:-}"; shift 2 || true; fi
  local note="$*"
  [ -n "$note" ] || { fail "usage: learn [--feature TARGET] <note...>"; exit 1; }
  [ "${#note}" -le 300 ] || { fail "a learning is at most 300 characters (got ${#note}) — keep one lesson per note"; exit 1; }
  local pid; pid="$(project_id)"
  [ -n "$pid" ] || { fail "unknown project slug: $PROJECT_SLUG"; exit 1; }
  local fid=""
  if [ -n "$target" ]; then
    if [[ "$target" =~ ^[0-9]+$ ]]; then
      fid=$(db "SELECT id FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND feature_number=$target;")
    else
      fid=$(db "SELECT id FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND name='$(sql_escape "$target")';")
    fi
    [ -n "$fid" ] || { fail "unknown feature: $target"; exit 1; }
  else
    local sid; sid="$(current_session_id)"
    [ -z "$sid" ] || fid=$(db "SELECT feature_id FROM session_log WHERE id=$sid;")
  fi
  local id
  id=$(db "INSERT INTO learnings (project_id, feature_id, note, created_at) VALUES ('$(sql_escape "$pid")', ${fid:-NULL}, '$(sql_escape "$note")', '$(now_iso)') RETURNING id;")
  ok "learned #$id"
}

# recall [term...] — at most 5 notes, ranked by how many terms they match
# (note text or feature name, case-insensitive), newest first on ties; with
# no terms, the 5 newest. Output stays around 500 tokens however many exist.
cmd_recall() {
  local pid; pid="$(project_id)"
  local score="1" term
  if [ $# -gt 0 ]; then
    score="0"
    for term in "$@"; do
      score="$score + (instr(lower(l.note || ' ' || COALESCE(f.name, '')), lower('$(sql_escape "$term")')) > 0)"
    done
  fi
  db -separator ' ' "SELECT '#' || l.id, CASE WHEN f.name IS NULL THEN '' ELSE '[' || f.name || ']' END, l.note
FROM learnings l LEFT JOIN features f ON f.id = l.feature_id
WHERE l.project_id='$(sql_escape "$pid")' AND l.deleted_at IS NULL AND ($score) > 0
ORDER BY ($score) DESC, l.id DESC LIMIT 5;" | sed 's/  */ /'
}

# forget <id> — soft-delete a learning that no longer applies.
cmd_forget() {
  local id="${1:-}"
  [[ "$id" =~ ^[0-9]+$ ]] || { fail "usage: forget <learning_id>"; exit 1; }
  local pid; pid="$(project_id)"
  local done_id
  done_id=$(db "UPDATE learnings SET deleted_at='$(now_iso)' WHERE id=$id AND project_id='$(sql_escape "$pid")' AND deleted_at IS NULL RETURNING id;")
  [ -n "$done_id" ] || { fail "no active learning #$id"; exit 1; }
  ok "forgot #$id"
}

cmd_status() {
  local pid; pid="$(project_id)"
  echo "project: $PROJECT_SLUG ($pid)"
  echo "--- features ---"
  db -header -column "SELECT f.feature_number, f.name, f.status, f.sdd,
  s.status AS spec_status, s.requirements_count AS reqs, s.tasks_count AS tasks, s.approved_by,
  f.size, f.superseded_by
FROM features f LEFT JOIN specs s ON s.feature_id = f.id AND s.deleted_at IS NULL
WHERE f.project_id='$(sql_escape "$pid")' AND f.deleted_at IS NULL ORDER BY f.feature_number;"
  echo "--- open session ---"
  db -header -column "SELECT id, agent, started_at, review_status, reviewed_by, held_at FROM session_log WHERE project_id='$(sql_escape "$pid")' AND closed_at IS NULL AND deleted_at IS NULL AND paused_at IS NULL;"
  local paused
  paused=$(db -header -column "SELECT sl.id, f.feature_number, f.name AS feature, sl.paused_at, sl.review_status FROM session_log sl LEFT JOIN features f ON f.id = sl.feature_id WHERE sl.project_id='$(sql_escape "$pid")' AND sl.closed_at IS NULL AND sl.deleted_at IS NULL AND sl.paused_at IS NOT NULL;")
  if [ -n "$paused" ]; then
    echo "--- paused sessions (blocked features; resume with unblock) ---"
    echo "$paused"
  fi
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
  local fid
  fid=$(db "SELECT id FROM features WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND $where LIMIT 1;")
  if [ -z "$fid" ]; then
    fail "no active feature matches: $target"
    exit 1
  fi
  # An open (or paused) session would be left pointing at a deleted feature,
  # and nothing in the harness could close it cleanly afterwards.
  local open_sid
  open_sid=$(db "SELECT id FROM session_log WHERE feature_id=$fid AND closed_at IS NULL AND deleted_at IS NULL LIMIT 1;")
  if [ -n "$open_sid" ]; then
    fail "feature $target still has open session $open_sid — finish it with log-out, or run 'cancel-session --force $open_sid <reason>' first"
    exit 1
  fi
  # Soft-delete its specs with it: a live spec on a deleted feature keeps the
  # mirror's one-active-spec-per-feature slot taken if the name is reused.
  db_exec "BEGIN;
UPDATE features SET deleted_at='$now', updated_at='$now' WHERE id=$fid;
UPDATE specs SET deleted_at='$now', updated_at='$now' WHERE feature_id=$fid AND deleted_at IS NULL;
COMMIT;"
  ok "soft-deleted feature $target (and its specs)"
}

# record-usage/stats live in scripts/agent_usage.py (python3 stdlib only).
# record-usage must never block the caller (init.sh, stats, leader): a
# missing python3/script is a [WARN] and exit 0, same as every parse problem.
# .harness.json::reopen_warn_tokens (default 80000, 0 disables): record-usage
# warns when a finished subagent gets a follow-up carrying that much context.
reopen_warn_tokens() {
  local n; n="$(config '.reopen_warn_tokens' '80000')"
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf '80000'
}

cmd_record_usage() {
  if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$SCRIPT_DIR/agent_usage.py" ]; then
    warn "record-usage needs python3 and scripts/agent_usage.py (re-run install.sh) — skipping"
    return 0
  fi
  python3 "$SCRIPT_DIR/agent_usage.py" --db "$DB_PATH" --project-slug "$PROJECT_SLUG" \
    collect --project-root "$(pwd)" --reopen-warn-tokens "$(reopen_warn_tokens)" "$@" || true
  warn_token_budget
}

# warn_token_budget — best-effort: when .harness.json sets token_quota (the
# tokens a full quota allows), warns if the active feature (open session's,
# else the most recent session's) has used at least token_warn_percent
# (default 15) of it, so the leader can tell the user before the quota runs out.
warn_token_budget() {
  local quota pct
  quota="$(config '.token_quota' '')"
  [[ "$quota" =~ ^[0-9]+$ ]] && [ "$quota" -gt 0 ] || return 0
  pct="$(config '.token_warn_percent' '15')"
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=15
  local pid; pid="$(project_id)"
  [ -n "$pid" ] || return 0
  local row
  row=$(db "SELECT f.feature_number, f.name, IFNULL((SELECT SUM(total_tokens) FROM agent_runs r
  WHERE r.feature_id = f.id AND r.deleted_at IS NULL), 0)
FROM features f WHERE f.id = (SELECT feature_id FROM session_log
  WHERE project_id='$(sql_escape "$pid")' AND deleted_at IS NULL AND feature_id IS NOT NULL
  ORDER BY (closed_at IS NULL) DESC, id DESC LIMIT 1);" 2>/dev/null) || return 0
  [ -n "$row" ] || return 0
  local fnum fname used
  IFS='|' read -r fnum fname used <<<"$row"
  [[ "$used" =~ ^[0-9]+$ ]] || return 0
  if [ $((used * 100)) -ge $((quota * pct)) ]; then
    warn "token budget: feature $fnum $fname has used $used tokens = $((used * 100 / quota))% of token_quota=$quota (warn at ${pct}%) — tell the user before launching more agents on it"
  fi
}

# cmd_test [file...] — run tests with the output kept out of the agent's
# context: everything goes to progress/test_last.log and only a one-line
# result (plus the log's tail on failure) is printed; grep the log instead of
# re-running. With files and .harness.json::test_targeted_command set, runs
# only those (its {files} placeholder is replaced with the shell-quoted paths,
# {files:FLAG} with "FLAG path" per file, or they're appended if it has
# neither); otherwise runs verify_command.
cmd_test() {
  local targeted verify cmd quoted="" f
  targeted="$(config '.test_targeted_command' '')"
  verify="$(config '.verify_command' '')"
  if [ $# -gt 0 ] && [ -n "$targeted" ]; then
    for f in "$@"; do quoted="$quoted $(printf '%q' "$f")"; done
    quoted="${quoted# }"
    if [[ "$targeted" =~ \{files:([^}]+)\} ]]; then
      # {files:FLAG} repeats FLAG before each file, for CLIs whose option
      # takes one value per occurrence (ng test --include a --include b).
      local token="${BASH_REMATCH[0]}" flag="${BASH_REMATCH[1]}" each=""
      for f in "$@"; do each="$each $flag $(printf '%q' "$f")"; done
      cmd="${targeted//"$token"/${each# }}"
    elif [[ "$targeted" == *"{files}"* ]]; then
      cmd="${targeted//\{files\}/$quoted}"
    else
      cmd="$targeted $quoted"
    fi
  elif [ -n "$verify" ]; then
    [ $# -gt 0 ] && warn "no test_targeted_command in .harness.json — running the full verify_command"
    cmd="$verify"
  else
    fail "no verify_command or test_targeted_command configured in .harness.json"
    exit 1
  fi

  local log="progress/test_last.log" rc
  mkdir -p progress
  { printf '$ %s\n' "$cmd"; bash -c "$cmd"; } > "$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "tests passed: $cmd (log: $log)"
  else
    tail -n 30 "$log"
    fail "tests failed (exit $rc): $cmd — full output in $log (grep it, don't re-run to read it)"
  fi
  return "$rc"
}

# link-worktree <dir> — see the usage comment. Items are relative to the
# project directory (the same subdirectory inside the worktree).
cmd_link_worktree() {
  local wt="${1:-}"
  [ -n "$wt" ] || { fail "usage: link-worktree <worktree_project_dir> (run from the main checkout)"; exit 1; }
  [ -d "$wt" ] || { fail "not a directory: $wt"; exit 1; }
  wt="$(cd "$wt" && pwd)"
  local main; main="$(pwd)"
  [ "$wt" != "$main" ] || { fail "link-worktree takes the worktree's project directory, not this checkout"; exit 1; }
  local common_main common_wt
  common_main="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
  common_wt="$(cd "$wt" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
  if [ -z "$common_main" ] || [ "$common_main" != "$common_wt" ]; then
    fail "$wt is not a worktree of this repository"; exit 1
  fi

  # Harness-owned: always shared. Project-owned: only when the worktree has no
  # copy of its own (e.g. excluded from git); a tracked one is the branch's.
  local shared="AGENTS.md CLAUDE.md init.sh harness.db harness scripts .harness.json .claude/agents .codex mock-data"
  local fallback="docs CHECKPOINTS.md specs features.seed.json"
  local item child linked=() kept=()
  for item in $shared $fallback; do
    [ -e "$main/$item" ] || continue
    if [ -L "$wt/$item" ] || [ -e "$wt/$item" ]; then
      # A real directory in the worktree (e.g. tracked project scripts next to
      # the harness ones): link only the harness children it is missing.
      if [ -d "$wt/$item" ] && [ ! -L "$wt/$item" ] && [ -d "$main/$item" ] && [[ " $shared " == *" $item "* ]]; then
        for child in "$main/$item"/*; do
          [ -e "$child" ] || continue
          if [ ! -e "$wt/$item/${child##*/}" ] && [ ! -L "$wt/$item/${child##*/}" ]; then
            ln -s "$child" "$wt/$item/${child##*/}" && linked+=("$item/${child##*/}")
          fi
        done
      else
        kept+=("$item")
      fi
      continue
    fi
    mkdir -p "$(dirname "$wt/$item")"
    ln -s "$main/$item" "$wt/$item" && linked+=("$item")
  done

  # progress/ holds each agent's handoffs: a symlink there sends every write
  # outside the worktree, which agent sandboxes and permission prompts treat
  # as an external path. The main checkout's progress/ is left as it is.
  if [ -L "$wt/progress" ]; then
    rm -f "$wt/progress" && ok "progress/ was a symlink to another checkout — replaced by a local directory"
  fi
  mkdir -p "$wt/progress"

  local prefix exclude_file begin end
  prefix="$(cd "$wt" && git rev-parse --show-prefix)"
  exclude_file="$common_main/info/exclude"
  begin="# >>> harness-worktree-links: /$prefix (written by harness.sh link-worktree)"
  end="# <<< harness-worktree-links: /$prefix"
  mkdir -p "$(dirname "$exclude_file")"; touch "$exclude_file"
  {
    awk -v begin="$begin" -v end="$end" '$0 == begin { skip = 1; next } $0 == end { skip = 0; next } !skip' "$exclude_file"
    printf '%s\n' "$begin"
    # No trailing slash: git matches a symlink as a file, never as a directory.
    for item in $shared $fallback progress; do printf '/%s%s\n' "$prefix" "$item" | sed 's/[][*?\\]/\\&/g'; done
    printf '%s\n' "$end"
  } > "$exclude_file.tmp" && mv "$exclude_file.tmp" "$exclude_file"

  ok "worktree $wt: linked ${#linked[@]} item(s)${linked[0]+: ${linked[*]}}; progress/ is local"
  [ "${#kept[@]}" -eq 0 ] || ok "already present, left as they are: ${kept[*]}"
}

cmd_stats() {
  if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$SCRIPT_DIR/agent_usage.py" ]; then
    fail "stats needs python3 and scripts/agent_usage.py (re-run install.sh)"
    exit 1
  fi
  # Refresh first so agents that finished after the last ./init.sh show up;
  # record-usage is best-effort and bounded, so a slow scan never blocks this.
  local args=() a refresh=1
  for a in "$@"; do
    if [ "$a" = "--no-refresh" ]; then refresh=0; else args+=("$a"); fi
  done
  [ "$refresh" = 0 ] || cmd_record_usage --max-seconds 10 >/dev/null 2>&1 || true
  python3 "$SCRIPT_DIR/agent_usage.py" --db "$DB_PATH" --project-slug "$PROJECT_SLUG" stats "${args[@]+"${args[@]}"}"
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
    set-depends-on) cmd_set_depends_on "$@" ;;
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
    hold) cmd_hold "$@" ;;
    unhold) cmd_unhold "$@" ;;
    set-size) cmd_set_size "$@" ;;
    drop-sdd) cmd_drop_sdd "$@" ;;
    set-request) cmd_set_request "$@" ;;
    learn) cmd_learn "$@" ;;
    recall) cmd_recall "$@" ;;
    forget) cmd_forget "$@" ;;
    record-init) cmd_record_init "$@" ;;
    cancel-session) cmd_cancel_session "$@" ;;
    reopen) cmd_reopen "$@" ;;
    supersede) cmd_supersede "$@" ;;
    unsupersede) cmd_unsupersede "$@" ;;
    check-blockers) cmd_check_blockers ;;
    record-usage) cmd_record_usage "$@" ;;
    stats) cmd_stats "$@" ;;
    link-worktree) cmd_link_worktree "$@" ;;
    test) cmd_test "$@" ;;
    *)
      fail "unknown subcommand: $sub"
      print_usage >&2
      exit 1
      ;;
  esac
}

main "$@"
