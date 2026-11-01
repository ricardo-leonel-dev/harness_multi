#!/usr/bin/env bash
# run.sh — the lean flow's steps, one sandboxed session each.
#
#   lean/run.sh freeze    <name>   risk mode, after the plan is approved: hash the acceptance tests
#   lean/run.sh implement <name>   implementer session (MiniMax by default)
#   lean/run.sh review    <name>   normal: implementer's tool, one pass, may fix once
#                                  risk:   reviewer's tool (another model), report only
#   lean/run.sh fix       <name>   the failed checks (and, in risk mode, the review findings)
#   lean/run.sh gate      <name>   the closing checks (lean/gate.sh)
#
# Options: --headless (claude -p instead of an interactive session; the result JSON is
# kept under the project's lean state, lean/lib.sh), --base <rev> (gate base; default the
# open harness session's recorded BASE for this feature, else HEAD).
# Run from the project directory. A feature is in risk mode once it has been frozen.
# Every step first checks the harness-owned files against the hashes pinned for the feature
# (lean/lib.sh lean_check_trusted) and refuses when one changed.
#
# Roles come from .harness.json::lean: implementer (default "claude-mini"), reviewer
# (default "claude:claude-haiku-5-5"), risk_questions (default "backend"), acceptance_dir
# (default "acceptance"), allowed_domains (default none). A tool is "claude[:<model>]" or
# "claude-mini"; "codex" is designed (progress/design_lean_flow.md §10) but not built.
set -euo pipefail

LEAN_DIR="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
step="${1:-}"; name="${2:-}"
[ -n "$step" ] && [ -n "$name" ] || usage
shift 2
headless=0; base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --headless) headless=1; shift ;;
    --base) base="$2"; shift 2 ;;
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
lean_adopt_legacy "$project"
state=$(lean_state_dir "$project")
lean_check_trusted "$project" "$name" || exit 3
# Pin the trusted files' hashes before the feature's first session, unless `harness.sh claim`
# already did: later steps refuse to run once a trusted file changed. Sessions can't read or
# write the state.
lean_pin "$project" "$name" || { echo "could not pin the feature's hashes in $state/lean/$name" >&2; exit 2; }
conf() { jq -r "$1" .harness.json; }
implementer=$(conf '.lean.implementer // "claude-mini"')
reviewer=$(conf '.lean.reviewer // "claude:claude-haiku-5-5"')
questions=$(conf '.lean.risk_questions // "backend"')
acc_dir=$(conf '.lean.acceptance_dir // "acceptance"'); acc_dir="${acc_dir%/}"

frozen="$state/frozen/$name.sha"
runs="$state/lean"
doc="docs/features/$name.md"
review_file="docs/features/$name.review.md"
risk=0; [ -f "$frozen" ] && risk=1

# The risk-question file: the project's own (docs/risk-questions.md) wins over the list.
question_file="docs/risk-questions.md"
[ -f "$question_file" ] || question_file="$LEAN_DIR/risk-questions/$questions.md"
[ -f "$question_file" ] || { echo "no risk-question list: $question_file" >&2; exit 2; }

log() { echo "[lean] $*" >&2; }

# open_session <tool> <prompt> — one session on <tool>, with the working agreement (and
# the risk-mode rules) appended to its system prompt.
open_session() {
  local tool="$1" prompt="$2" adapter model system
  case "$tool" in
    claude) adapter=claude; model=- ;;
    claude:*) adapter=claude; model="${tool#claude:}" ;;
    claude-mini) adapter=claude-mini; model=- ;;
    codex*) echo "the codex adapter is designed but not built yet (progress/design_lean_flow.md §10)" >&2; exit 2 ;;
    *) echo "unknown tool: $tool" >&2; exit 2 ;;
  esac
  mkdir -p "$runs"
  system="$runs/$name.system.md"
  { cat "$LEAN_DIR/instructions/agreement.md"
    [ "$risk" = 1 ] && { echo; cat "$LEAN_DIR/instructions/risk.md"; }
    printf '\nFeature: %s. Document: %s. Risk questions: %s.\n' "$name" "$doc" "$question_file"
    [ "$risk" = 1 ] && printf 'Frozen acceptance tests: %s\n' "$(awk '{print $2}' "$frozen" | tr '\n' ' ')"
  } > "$system"
  if [ "$headless" = 1 ]; then
    local result; result="$runs/$name.$step.$(date +%Y%m%d%H%M%S).json"
    "$LEAN_DIR/adapters/$adapter.sh" "$project" headless "$model" "$system" "$prompt" "$result" || true
    log "result: $result"
    jq -c '{is_error, num_turns, duration_ms, total_cost_usd}' "$result" 2>/dev/null >&2 || true
  else
    "$LEAN_DIR/adapters/$adapter.sh" "$project" interactive "$model" "$system" "$prompt"
  fi
}

run_gate() {
  # The default base: what log-out --lean checks against (scripts/harness.sh session-base,
  # write-denied to sessions and hash-checked above).
  if [ -z "$base" ] && [ -f scripts/harness.sh ]; then
    base=$(bash scripts/harness.sh session-base "$name" 2>/dev/null || true)
  fi
  base="${base:-HEAD}"
  local args=(--base "$base")
  [ "$risk" = 1 ] && args+=(--frozen "$frozen")
  "$LEAN_DIR/gate.sh" "$project" "$name" "${args[@]}"
}

# tree_fingerprint — hash of every tracked and untracked (not ignored) file but the review
# file: tells whether the risk-mode reviewer changed anything.
tree_fingerprint() {
  git ls-files -co --exclude-standard | sort -u | { grep -vxF "$review_file" || true; } \
    | while IFS= read -r f; do [ -f "$f" ] && shasum "$f"; done | shasum | cut -d' ' -f1
}

no_human="No human is available during this step: do not ask questions; decide, note it in the document, and finish. Do not commit or push."

[ -f "$doc" ] || [ "$step" = gate ] || { echo "no feature document: $doc (plan it first: lean/instructions/planning.md)" >&2; exit 2; }

case "$step" in
  freeze)
    # With the harness, approve-plan already froze them: only the red-before-green check is left.
    if [ "$risk" = 1 ]; then
      log "already frozen: $frozen"
      files=$(awk '{print $2}' "$frozen")
    else
      files=$(find "$acc_dir" -type f -name "$name.*" 2>/dev/null | sort)
      [ -n "$files" ] || { echo "no acceptance tests for $name in $acc_dir/ (risk mode needs them)" >&2; exit 2; }
      mkdir -p "$(dirname "$frozen")"
      # shellcheck disable=SC2086
      shasum -a 256 $files > "$frozen"
      log "frozen $(wc -l < "$frozen" | tr -d ' ') file(s) into $frozen"
    fi
    # Red before green: acceptance tests that already pass check nothing. They run under the
    # sessions' sandbox rules, like the gate (lean/lib.sh lean_sandboxed).
    verify=$(conf '.verify_command')
    lean_sandbox_prepare "$project"
    [ -z "$LEAN_SANDBOX_WARN" ] || printf '%s\n' "$LEAN_SANDBOX_WARN" | while IFS= read -r w; do log "$w"; done
    case "$LEAN_SANDBOX" in
      unsandboxed:*) log "[WARN] the acceptance tests run UNSANDBOXED (${LEAN_SANDBOX#unsandboxed: })" ;;
      broken:*) echo "${LEAN_SANDBOX#broken: }: the acceptance tests did not run (LEAN_GATE_UNSANDBOXED=1 runs them unsandboxed)" >&2; exit 2 ;;
    esac
    # shellcheck disable=SC2086
    out=$(lean_sandboxed "$project" "$verify $(echo $files)" 2>&1 || true)
    log "before implementing: $(grep -Eo '^ *[0-9]+ (pass|fail)' <<<"$out" | tr -s ' ' | tr '\n' ' ')"
    ;;
  implement)
    prompt="Implement the feature documented in $doc, as the working agreement in your instructions describes."
    [ "$risk" = 1 ] && prompt+=" Its acceptance tests are frozen."
    [ "$headless" = 1 ] && prompt+=" $no_human"
    open_session "$implementer" "$prompt"
    ;;
  review)
    report=$(run_gate || true)
    if [ "$risk" = 0 ]; then
      prompt="Review the uncommitted changes for the feature documented in $doc, as the working agreement in your instructions describes (\"Reviewing\"). Results of the automatic checks:

$report"
      [ "$headless" = 1 ] && prompt+=$'\n\n'"$no_human"
      open_session "$implementer" "$prompt"
    else
      [ "$reviewer" != "$implementer" ] || { echo "risk mode: the reviewer must be another model than the implementer ($reviewer)" >&2; exit 2; }
      before=$(tree_fingerprint)
      prompt="Review the uncommitted changes for the feature documented in $doc, as the risk-mode rules in your instructions describe (\"Reviewing (risk mode)\"): report only, in $review_file, ending with the VERDICT line. Results of the automatic checks:

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
    [ "$headless" = 1 ] && prompt+=$'\n\n'"$no_human"
    open_session "$implementer" "$prompt"
    ;;
  gate)
    run_gate
    ;;
  *) usage ;;
esac
