#!/usr/bin/env bash
# run.sh — the lean flow's steps, one sandboxed session each.
#
#   lean/run.sh brief     <name> [keyword...]   before planning: what the planner reads, in one call
#   lean/run.sh freeze    <name>   risk mode, after the plan is approved: hash the acceptance tests
#   lean/run.sh implement <name>   implementer session (MiniMax by default)
#   lean/run.sh review    <name>   normal: lean.reviewer(.normal) if set, else the implementer; one pass, may fix once
#                                  risk:   lean.reviewer(.risk), another model; report only
#   lean/run.sh fix       <name>   the failed checks (and, in risk mode, the review findings)
#   lean/run.sh gate      <name>   the closing checks (lean/gate.sh)
#   lean/run.sh chain     <name>   every step above, headless, in one call; a compact summary
#                                  (--step-minutes N caps each step; never logs out)
#   lean/run.sh usage     <name>   the feature's sessions: tool, model, turns, tokens, time, cost
#   lean/run.sh replan    <name>   the leader accepts a change to the plan's Files / Changed tests
#                                  (pinned once a session ran; --by <name> when the plan was approved)
#
# Options: --headless (claude -p / codex exec instead of an interactive session; the result JSON is
# kept under the project's lean state, lean/lib.sh), --base <rev> (gate base; default the
# open harness session's recorded BASE for this feature, else HEAD), --step-minutes <N>
# (chain only; default .harness.json::lean.step_minutes, else 30).
# Run from the project directory. A feature is in risk mode once it has been frozen.
# Every step first checks that docs/features/<name>.md exists (nothing is pinned otherwise),
# then checks the harness-owned files against the hashes pinned for the feature
# (lean/lib.sh lean_check_trusted) and refuses when one changed.
#
# Roles come from .harness.json::lean: implementer (default "claude-mini"), reviewer (a tool
# for both modes, or {"normal": <tool>, "risk": <tool>} with each key optional; risk review:
# default "claude:claude-haiku-5-5", must differ from the implementer; normal review: only
# when set, else the implementer; any other shape exits 2), risk_questions (default "backend"), acceptance_dir
# (default "acceptance"), acceptance_command (a string, {paths} placeholder; default verify_command
# with the paths appended; any other type exits 2), allowed_domains (default none), max_turns ({"implement","review","fix"}:
# a headless claude session's turn cap, default 120 / 40 / 60; anything but positive integers
# exits 2). A tool is "claude[:<model>]",
# "claude-mini", "codex[:<model>]" or "codex-m3" (lean/adapters/<tool>.sh). claude-mini and
# codex-m3 both run MiniMax: in risk mode they count as the same model.
set -euo pipefail

LEAN_DIR="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
step="${1:-}"; name="${2:-}"
[ -n "$step" ] && [ -n "$name" ] || usage
shift 2

# brief <name> [keyword...] — everything the planner reads before writing the plan, in one
# call: the feature, the planning rules, the risk questions, an earlier plan, the project's
# files and the lines matching each keyword. Read-only; runs before the document exists, so
# nothing is pinned. Long sections are capped: read further with sed -n on the paths shown.
if [ "$step" = brief ]; then
  case "$name" in *[!A-Za-z0-9_-]*) echo "feature name must be letters, digits, _ or -" >&2; exit 2 ;; esac
  [ -f .harness.json ] || { echo "run lean/run.sh from a project with a .harness.json" >&2; exit 2; }
  LEAN_DIR="$(cd "$(dirname "$0")" && pwd)"
  section() { printf '\n===== %s =====\n' "$1"; }
  cap() { awk -v n="$1" 'NR<=n {print} END {if (NR>n) printf "... (%d more lines)\n", NR-n}'; }
  section "feature"
  feat=$(ls state/features/*-"$name".md 2>/dev/null | head -1 || true)
  if [ -n "$feat" ]; then
    awk '/^## Agent usage/ {exit} {print}' "$feat"
  else
    echo "(no snapshot in state/features/ — run scripts/harness.sh status)"
  fi
  [ -f "docs/features/$name.md" ] && echo "(a plan already exists: docs/features/$name.md)"
  section "project"
  echo "dir: $(pwd)   git prefix: $(git rev-parse --show-prefix 2>/dev/null || true)"
  jq -r '"verify_command: \(.verify_command // "-")", "lean: \(.lean // {} | tojson)"' .harness.json
  section "planning rules ($LEAN_DIR/instructions/planning.md)"
  cat "$LEAN_DIR/instructions/planning.md"
  qlist=$(jq -r '.lean.risk_questions // "backend"' .harness.json)
  qfile="docs/risk-questions.md"; [ -f "$qfile" ] || qfile="$LEAN_DIR/risk-questions/$qlist.md"
  section "risk questions ($qfile)"
  cat "$qfile" 2>/dev/null || echo "(missing)"
  example=$(ls -t docs/features/*.md 2>/dev/null | grep -v '\.review\.md$' | grep -vxF "docs/features/$name.md" | head -1 || true)
  section "earlier plan (format example): ${example:-none}"
  [ -z "$example" ] || cap 70 < "$example"
  section "docs headings (read a section with sed -n '<from>,<to>p')"
  for f in docs/architecture.md docs/conventions.md docs/verification.md; do
    [ -f "$f" ] && { grep -n '^#' "$f" || true; } | sed "s|^|$f:|" | cap 40
  done
  section "files (tracked and untracked, project dir)"
  { git ls-files -co --exclude-standard -- . 2>/dev/null || true; } | { grep -vE '^(state|progress|harness|lean|scripts)/|(^|/)(AGENTS|CLAUDE)\.md$|^\.(claude|codex|agents)/' || true; } | cap 200
  # Untracked files are searched too (a feature's new files), but never a dotfile or anything
  # under a dot-folder (.env and the like hold secrets) nor a secret-looking file or folder
  # (lean/lib.sh LEAN_SECRET_NAMES, the list the sessions' sandbox denies).
  # shellcheck source=lib.sh
  . "$LEAN_DIR/lib.sh"
  secret_specs=()
  set -f
  for n in $LEAN_SECRET_NAMES; do secret_specs+=(":(exclude,glob,icase)**/$n" ":(exclude,glob,icase)**/$n/**"); done
  set +f
  for kw in "$@"; do
    section "matches: $kw"
    git grep --untracked -n -I -i -F -e "$kw" -- . ':!state' ':!progress' ':!harness' ':!lean' ':!scripts' \
      ':(exclude,glob)**/.*' ':(exclude,glob)**/.*/**' "${secret_specs[@]}" 2>/dev/null \
      | cut -c1-200 | cap 25 || true
  done
  exit 0
fi

# usage <name> — every session recorded for the feature (lean/lib.sh lean_usage_record), as a
# table. Read-only; needs no document and pins nothing.
if [ "$step" = usage ]; then
  case "$name" in *[!A-Za-z0-9_-]*) echo "feature name must be letters, digits, _ or -" >&2; exit 2 ;; esac
  [ -f .harness.json ] || { echo "run lean/run.sh from a project with a .harness.json" >&2; exit 2; }
  # shellcheck source=lib.sh
  . "$LEAN_DIR/lib.sh"
  file=$(lean_usage_file "$(pwd)" "$name")
  lean_usage_table "$(pwd)" "$name" || { echo "no usage recorded for $name ($file)"; exit 0; }
  echo "rows: $file"
  exit 0
fi

# replan <name> [--by <name>] — the leader accepts the plan's **Files** / **Changed tests** as
# the document now has them: they are pinned afresh (lean/lib.sh lean_plan_pin), and the gate
# checks against them. Refused inside a session. An approved plan (approve-plan, or a frozen
# risk-mode manifest) needs --by <the human who approved the change>, recorded with the lists.
if [ "$step" = replan ]; then
  case "$name" in *[!A-Za-z0-9_-]*) echo "feature name must be letters, digits, _ or -" >&2; exit 2 ;; esac
  [ -f .harness.json ] || { echo "run lean/run.sh from a project with a .harness.json" >&2; exit 2; }
  by=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) [ $# -ge 2 ] || usage; by="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; usage ;;
    esac
  done
  # shellcheck source=lib.sh
  . "$LEAN_DIR/lib.sh"
  project="$(pwd)"
  if lean_in_session "$project"; then
    echo "inside a lean session: replan is the leader's, outside any session (report the file the feature needs instead)" >&2; exit 2
  fi
  doc="docs/features/$name.md"
  [ -f "$doc" ] || { echo "no feature document: $doc" >&2; exit 2; }
  lean_adopt_legacy "$project"
  file=$(lean_plan_file "$project" "$name")
  approved=0
  { grep -q '^# approved' "$file" 2>/dev/null || [ -f "$(lean_state_dir "$project")/frozen/$name.sha" ]; } && approved=1
  if [ -f "$file" ]; then
    drift=$(lean_plan_drift "$project" "$name")
    [ -n "$drift" ] || { echo "[lean] nothing to accept: $doc lists what $file pins"; exit 0; }
    echo "[lean] $doc's lists against $file:"
    printf '%s\n' "$drift"
  else
    drift=$(lean_plan_lists "$doc" | awk -F'\t' '{ printf "  + %s: %s\n", $1, $2 }')
    echo "[lean] no lists pinned yet for $name: $doc lists"
    printf '%s\n' "${drift:-  (nothing)}"
  fi
  if [ "$approved" = 1 ]; then
    case "$(printf '%s' "$by" | tr '[:upper:]' '[:lower:]')" in
      ""|user) echo "the plan of $name was approved: a change to its **Files** / **Changed tests** needs the user's approval again. Show them the change above; after they approve it, run lean/run.sh replan $name --by \"<their name>\"" >&2; exit 1 ;;
    esac
    lean_plan_pin "$project" "$name" --approved "$by" || { echo "could not write $file" >&2; exit 2; }
  else
    lean_plan_pin "$project" "$name" --again || { echo "could not write $file" >&2; exit 2; }
  fi
  if [ -f scripts/harness.sh ]; then
    bash scripts/harness.sh append-log "lean replan $name: accepted $(printf '%s' "$drift" | sed 's/^ *//' | paste -sd ';' -)${by:+ (approved by $by)}" >/dev/null 2>&1 || true
  fi
  exit 0
fi

headless=0; base=""; step_minutes=""
while [ $# -gt 0 ]; do
  case "$1" in
    --headless) headless=1; shift ;;
    --base) [ $# -ge 2 ] || usage; base="$2"; shift 2 ;;
    --step-minutes) [ $# -ge 2 ] && [ "$step" = chain ] || usage; step_minutes="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done
case "$name" in *[!A-Za-z0-9_-]*) echo "feature name must be letters, digits, _ or -" >&2; exit 2 ;; esac

project="$(pwd)"
[ -f .harness.json ] || { echo "run lean/run.sh from a project with a .harness.json" >&2; exit 2; }
# shellcheck source=lib.sh
. "$LEAN_DIR/lib.sh"
# The state is keyed by the project's resolved path (lean/lib.sh), not by anything in the
# project a session could edit: the trusted hashes and the risk-mode manifest are found the
# same way whatever .harness.json says.
# The feature must exist before anything is pinned under its name (a typo would pin hashes
# for a feature that isn't there).
doc="docs/features/$name.md"
[ -f "$doc" ] || { echo "no feature document: $doc (plan it first: lean/instructions/planning.md)" >&2; exit 2; }
lean_adopt_legacy "$project"
state=$(lean_state_dir "$project")
# Before chain.sh is sourced: the leader's shell runs it unsandboxed, so a trusted file
# changed since the pin must stop it here, not at its first step.
lean_check_trusted "$project" "$name" || exit 3
# lean.reviewer: a tool for both modes, or {"normal": <tool>, "risk": <tool>} (each key
# optional; an empty value counts as unset). Anything else stops every step here, the chain
# included, instead of guessing. The defaults are applied below.
reviewer_parsed=$(jq -r '.lean.reviewer as $r
  | if $r == null then "ok\n\n"
    elif ($r | type) == "string" then "ok\n\($r)\n\($r)"
    elif ($r | type) == "object" and (($r | keys) - ["normal", "risk"] | length) == 0
         and all($r[]; type == "string") then "ok\n\($r.normal // "")\n\($r.risk // "")"
    else "invalid" end' .harness.json 2>/dev/null) || reviewer_parsed=invalid
{ read -r reviewer_ok; read -r reviewer_normal_set; read -r reviewer_risk_set; } <<<"$reviewer_parsed" || true
[ "$reviewer_ok" = ok ] || {
  echo "invalid .harness.json::lean.reviewer: use a tool string (both modes) or an object with optional string keys \"normal\" and \"risk\" (got: $(jq -c '.lean.reviewer' .harness.json 2>/dev/null || echo unreadable))" >&2
  exit 2
}
# lean.max_turns: {"implement": n, "review": n, "fix": n}, each optional, an integer 1..10000:
# the turn cap of a headless session of that step (claude -p --max-turns; Codex has none).
# Anything else stops every step here, the chain included, before any session.
jq -e '.lean.max_turns as $m
  | $m == null or (($m | type) == "object" and (($m | keys) - ["implement", "review", "fix"] | length) == 0
      and all($m[]; type == "number" and . >= 1 and . <= 10000 and . == floor))' .harness.json >/dev/null 2>&1 || {
  echo "invalid .harness.json::lean.max_turns: use an object with optional keys \"implement\", \"review\", \"fix\", each an integer from 1 to 10000 (got: $(jq -c '.lean.max_turns' .harness.json 2>/dev/null || echo unreadable))" >&2
  exit 2
}
# lean.acceptance_command: a string (lean/lib.sh lean_acceptance_command); anything else stops
# every step here, the chain included, before any session.
lean_acceptance_valid "$project" || { echo "$LEAN_ACCEPTANCE_INVALID (got: $(jq -c '.lean.acceptance_command' .harness.json 2>/dev/null || echo unreadable))" >&2; exit 2; }
if [ "$step" = chain ]; then
  # shellcheck source=chain.sh
  . "$LEAN_DIR/chain.sh"
  set +e   # lean_chain checks every status itself and reports the failing step
  lean_chain
  exit $?
fi
# Pin the trusted files' hashes before the feature's first session, unless `harness.sh claim`
# already did: later steps refuse to run once a trusted file changed. Sessions can't read or
# write the state.
lean_pin "$project" "$name" || { echo "could not pin the feature's hashes in $state/lean/$name" >&2; exit 2; }
conf() { jq -r "$1" .harness.json; }
implementer=$(conf '.lean.implementer // "claude-mini"')
# The reviewers (lean.reviewer, parsed above): risk mode always has one (default below);
# normal mode only when it is set, else the implementer reviews.
reviewer_normal="${reviewer_normal_set:-$implementer}"
reviewer="${reviewer_risk_set:-claude:claude-haiku-5-5}"
questions=$(conf '.lean.risk_questions // "backend"')
acc_dir=$(conf '.lean.acceptance_dir // "acceptance"'); acc_dir="${acc_dir%/}"

frozen="$state/frozen/$name.sha"
runs="$state/lean"
review_file="docs/features/$name.review.md"
risk=0; [ -f "$frozen" ] && risk=1

# The risk-question file: the project's own (docs/risk-questions.md) wins over the list.
question_file="docs/risk-questions.md"
[ -f "$question_file" ] || question_file="$LEAN_DIR/risk-questions/$questions.md"
[ -f "$question_file" ] || { echo "no risk-question list: $question_file" >&2; exit 2; }

log() { echo "[lean] $*" >&2; }
# max_turns_default <step> — the turn cap of a headless step when lean.max_turns has no key for it.
max_turns_default() { case "$1" in implement) echo 120 ;; fix) echo 60 ;; *) echo 40 ;; esac; }

# open_session <tool> <prompt> — one session on <tool>, with the working agreement (and
# the risk-mode rules) appended to its system prompt.
open_session() {
  local tool="$1" prompt="$2" adapter model system
  case "$tool" in
    claude) adapter=claude; model=- ;;
    claude:*) adapter=claude; model="${tool#claude:}" ;;
    claude-mini) adapter=claude-mini; model=- ;;
    codex) adapter=codex; model=- ;;
    codex-m3) adapter=codex-m3; model=- ;;
    codex:?*) adapter=codex; model="${tool#codex:}" ;;
    *) echo "unknown tool: $tool" >&2; exit 2 ;;
  esac
  mkdir -p "$runs"
  system="$runs/$name.system.md"
  { cat "$LEAN_DIR/instructions/agreement.md"
    [ "$risk" = 1 ] && { echo; cat "$LEAN_DIR/instructions/risk.md"; }
    printf '\nFeature: %s. Document: %s. Risk questions: %s.\n' "$name" "$doc" "$question_file"
    [ "$risk" = 1 ] && printf 'Frozen acceptance tests: %s\n' "$(lean_manifest_paths "$frozen" | while IFS= read -r f; do printf '%q ' "$f"; done)"
  } > "$system"
  # One usage row per session (lean/lib.sh lean_usage_record; best-effort).
  local t0=$SECONDS rc=0 mode_name=normal
  [ "$risk" = 0 ] || mode_name=risk
  # What the chain reads: a claude-mini step's line shows no cost, and a session it stops at
  # its step cap gets its usage row from it (lean/chain.sh).
  log "session: $adapter $model $mode_name"
  if [ "$headless" = 1 ]; then
    local result max_turns; result="$runs/$name.$step.$(date +%Y%m%d%H%M%S).json"
    # The step's turn cap (lean.max_turns, validated above): claude -p --max-turns; the codex
    # adapter has no such flag and ignores it (the chain's step minutes still apply).
    max_turns=$(jq -r --arg s "$step" --argjson d "$(max_turns_default "$step")" '.lean.max_turns[$s] // $d' .harness.json)
    log "max turns: $max_turns"
    LEAN_MAX_TURNS="$max_turns" "$LEAN_DIR/adapters/$adapter.sh" "$project" headless "$model" "$system" "$prompt" "$result" || true
    lean_usage_record "$project" "$name" "$step" "$mode_name" "$adapter" "$model" "$((SECONDS - t0))" "$result" || true
    log "result: $result"
    jq -c '{is_error, subtype, num_turns, duration_ms, total_cost_usd}' "$result" 2>/dev/null >&2 || true
    if [ "$(jq -r '.subtype // empty' "$result" 2>/dev/null)" = error_max_turns ]; then
      log "max turns ($max_turns) reached: the session stopped before finishing"
    fi
  else
    "$LEAN_DIR/adapters/$adapter.sh" "$project" interactive "$model" "$system" "$prompt" || rc=$?
    lean_usage_record "$project" "$name" "$step" "$mode_name" "$adapter" "$model" "$((SECONDS - t0))" - || true
    [ "$rc" = 0 ] || exit "$rc"
  fi
}

# resolve_base — the gate's base: --base, else what log-out --lean checks against
# (scripts/harness.sh session-base, write-denied to sessions and hash-checked above), else HEAD.
resolve_base() {
  if [ -z "$base" ] && [ -f scripts/harness.sh ]; then
    base=$(bash scripts/harness.sh session-base "$name" 2>/dev/null || true)
  fi
  base="${base:-HEAD}"
}

run_gate() {
  resolve_base
  local args=(--base "$base")
  [ "$risk" = 1 ] && args+=(--frozen "$frozen")
  "$LEAN_DIR/gate.sh" "$project" "$name" "${args[@]}"
}

# model_of <tool> — what the risk-mode rule compares: the MiniMax tools (claude-mini, codex-m3) are
# one model whatever runs them; any other tool is itself.
model_of() { case "$1" in claude-mini|codex-m3) echo minimax ;; *) echo "$1" ;; esac; }

# tree_fingerprint — hash of every tracked and untracked (not ignored) file but the review
# file: tells whether the risk-mode reviewer changed anything.
tree_fingerprint() {
  git ls-files -co --exclude-standard | sort -u | { grep -vxF "$review_file" || true; } \
    | while IFS= read -r f; do [ -f "$f" ] && shasum "$f"; done | shasum | cut -d' ' -f1
}

no_human="No human is available during this step: do not ask questions; decide, note it in the document, and finish. Do not commit or push."
# What every session stays out of (the working agreement's "Boundaries", repeated in the prompt).
bounds="Boundaries: do not read lean/, harness/, the harness's own scripts (scripts/harness.sh, scripts/lib.sh, scripts/snapshot.sh, scripts/sync_postgres.sh, scripts/notion_*.sh), init.sh, .harness.json, progress/, state/, ~/.cache, other features' documents or specs/; the files under **Files**, the code and tests they touch and any file this prompt names are always fine to read; do not run ./init.sh, lean/gate.sh, scripts/harness.sh or the full test suite (the gate runs them after this session, outside it; LEAN_GATE_UNSANDBOXED has no effect here). Run the feature's own tests and targeted checks; the project's docs/ are fine to read."

case "$step" in
  freeze)
    # With the harness, approve-plan already froze them: only the red-before-green check is left.
    if [ "$risk" = 1 ]; then
      log "already frozen: $frozen"
      files=$(lean_manifest_paths "$frozen")
    else
      files=$(find "$acc_dir" -type f -name "$name.*" 2>/dev/null | sort)
      [ -n "$files" ] || { echo "no acceptance tests for $name in $acc_dir/ (risk mode needs them)" >&2; exit 2; }
    fi
    # One path per line, spaces kept (never word-split).
    acc_paths=()
    while IFS= read -r f; do [ -z "$f" ] || acc_paths+=("$f"); done <<<"$files"
    if [ "$risk" = 0 ]; then
      mkdir -p "$(dirname "$frozen")"
      shasum -a 256 "${acc_paths[@]}" > "$frozen"
      log "frozen $(wc -l < "$frozen" | tr -d ' ') file(s) into $frozen"
      # Freezing by hand is the approval without the harness: the plan's lists are pinned with it
      # (lean/lib.sh lean_plan_mark_approved: from the document only while no session ran).
      lean_plan_mark_approved "$project" "$name" "run.sh freeze" || { echo "could not pin the plan's lists" >&2; exit 2; }
      plan_drift=$(lean_plan_drift "$project" "$name")
      [ -z "$plan_drift" ] || log "$doc's **Files** / **Changed tests** differ from the lists pinned before its sessions ran (approved as pinned; the gate fails on these until the user approves them and you run lean/run.sh replan $name --by <name>):"$'\n'"$plan_drift"
    fi
    # Red before green: acceptance tests that already pass check nothing. They run under the
    # sessions' sandbox rules, like the gate (lean/lib.sh lean_sandboxed).
    # lean.acceptance_command when set, else verify_command with the paths appended (lean/lib.sh
    # lean_acceptance_command, shell-quoted), as the gate runs them.
    lean_acceptance_command "$project" ${acc_paths[@]+"${acc_paths[@]}"}
    [ -z "$LEAN_ACCEPTANCE_WARN" ] || log "$LEAN_ACCEPTANCE_WARN"
    lean_sandbox_prepare "$project"
    [ -z "$LEAN_SANDBOX_WARN" ] || printf '%s\n' "$LEAN_SANDBOX_WARN" | while IFS= read -r w; do log "$w"; done
    case "$LEAN_SANDBOX" in
      unsandboxed:*) log "[WARN] the acceptance tests run UNSANDBOXED (${LEAN_SANDBOX#unsandboxed: })" ;;
      broken:*) echo "${LEAN_SANDBOX#broken: }: the acceptance tests did not run (LEAN_GATE_UNSANDBOXED=1 runs them unsandboxed)" >&2; exit 2 ;;
      session:*) echo "${LEAN_SANDBOX#session: }: the acceptance tests did not run" >&2; exit 2 ;;
    esac
    out=$(lean_sandboxed "$project" "$LEAN_ACCEPTANCE_CMD" 2>&1 || true)
    log "before implementing: $(grep -Eo '^ *[0-9]+ (pass|fail)' <<<"$out" | tr -s ' ' | tr '\n' ' ')"
    ;;
  implement)
    prompt="Implement the feature documented in $doc, as the working agreement in your instructions describes."
    [ "$risk" = 1 ] && prompt+=" Its acceptance tests are frozen."
    prompt+=$'\n\n'"$bounds"
    [ "$headless" = 1 ] && prompt+=" $no_human"
    open_session "$implementer" "$prompt"
    ;;
  review)
    resolve_base
    report=$(run_gate || true)
    base_rev=$(git rev-parse --verify -q "$base^{commit}" 2>/dev/null || echo "$base")
    # The review's whole scope; the boundaries keep it from auditing the harness.
    scope="Review only: the change (git diff $base_rev, plus the untracked files git status --short lists), the files under **Files** in $doc, and $doc itself"
    [ "$risk" = 0 ] || scope+=", and the risk questions in $question_file"
    scope+=". $bounds The checks below already ran the full suite; the gate runs again after you."
    if [ "$risk" = 0 ]; then
      prompt="Review the uncommitted changes for the feature documented in $doc, as the working agreement in your instructions describes (\"Reviewing\"). $scope Results of the automatic checks:

$report"
      [ "$headless" = 1 ] && prompt+=$'\n\n'"$no_human"
      open_session "$reviewer_normal" "$prompt"
    else
      if [ "$(model_of "$reviewer")" = "$(model_of "$implementer")" ]; then
        same="$reviewer"; [ "$reviewer" = "$implementer" ] || same="$reviewer and $implementer both run MiniMax"
        echo "risk mode: the reviewer must be another model than the implementer ($same)" >&2; exit 2
      fi
      before=$(tree_fingerprint)
      prompt="Review the uncommitted changes for the feature documented in $doc, as the risk-mode rules in your instructions describe (\"Reviewing (risk mode)\"): report only, in $review_file, ending with the VERDICT line. $scope Results of the automatic checks:

$report"
      [ "$headless" = 1 ] && prompt+=$'\n\n'"$no_human"
      open_session "$reviewer" "$prompt"
      after=$(tree_fingerprint)
      verdict=$(grep -Eo '^VERDICT: (approve|changes)' "$review_file" 2>/dev/null | tail -1 | cut -d' ' -f2 || true)
      mkdir -p "$runs"
      jq -nc --arg v "${verdict:-none}" --argjson t "$([ "$before" = "$after" ] && echo false || echo true)" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{verdict: $v, reviewer_changed_files: $t, at: $at}' \
        > "$runs/$name.review.json"
      [ "$before" = "$after" ] || log "WARNING: the reviewer changed files (it must only report)"
      log "verdict: ${verdict:-none}"
    fi
    ;;
  fix)
    report=$(run_gate || true)
    if [ "$risk" = 1 ]; then
      prompt="Fix the feature documented in $doc, as the risk-mode rules in your instructions describe (\"Fixing\"). The review is in $review_file. Results of the automatic checks:

$report"
    else
      prompt="Fix the feature documented in $doc, as the working agreement in your instructions describes, so that the automatic checks pass. Their results:

$report"
    fi
    prompt+=$'\n\n'"$bounds Rerun the tests the report names as failing, not the whole suite."
    [ "$headless" = 1 ] && prompt+=$'\n\n'"$no_human"
    open_session "$implementer" "$prompt"
    ;;
  gate)
    run_gate
    ;;
  *) usage ;;
esac
