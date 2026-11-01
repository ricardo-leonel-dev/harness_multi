#!/usr/bin/env bash
# init.sh — environment check, run at the start of every session and before
# declaring any task done. SQLite (harness.db) is the source of truth; the
# Postgres/Supabase mirror is optional and best-effort — its failure is a
# [WARN], never a reason to stop the session.
#
# Expected output: clear exit codes and [OK]/[WARN]/[FAIL] blocks.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ok() { printf "${GREEN}[OK]${NC}    %s\n" "$1"; }
warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
fail() { printf "${RED}[FAIL]${NC}  %s\n" "$1"; }

EXIT_CODE=0

echo "── 1. Checking prerequisites ───────────────────────────"

for tool in sqlite3 jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    fail "$tool is not installed (required)"
    EXIT_CODE=1
  else
    ok "$tool available"
  fi
done

if ! command -v curl >/dev/null 2>&1; then
  warn "curl not available — the Postgres/Supabase mirror sync will be skipped"
fi

if [ $EXIT_CODE -ne 0 ]; then
  fail "Missing required tools. Resolve before continuing."
  exit 1
fi

echo ""
echo "── 2. Checking harness state ───────────────────────────"

if [ ! -f ".harness.json" ]; then
  fail "Missing .harness.json — run install.sh first"
  exit 1
fi
ok ".harness.json found"

DB_PATH="$(jq -r '.db_path // "harness.db"' .harness.json)"
if [ ! -f "$DB_PATH" ]; then
  fail "Missing $DB_PATH — run install.sh first"
  exit 1
fi
ok "$DB_PATH found"

for f in docs/architecture.md docs/conventions.md docs/verification.md CHECKPOINTS.md; do
  if [ ! -f "$f" ]; then
    fail "Missing base file: $f"
    EXIT_CODE=1
  else
    ok "Found $f"
  fi
done

echo ""
echo "── 3. Checking SDD spec files ───────────────────────────"

# For every feature that requires spec-driven development (sdd=1) and has
# progressed past drafting, its 3 spec files must actually exist on disk —
# mirrors C6 of CHECKPOINTS.md, but enforced mechanically here so the check
# can't be skipped. Hard failure, not a [WARN]: same treatment as the base
# files checked in step 2. `readarray`/`mapfile` need bash 4+, which macOS's
# bundled /bin/bash (3.2) doesn't have — a `while read` fed via process
# substitution (`< <(...)`, not a piped `cmd | while read`) is portable to
# bash 3.2 and, unlike a pipe, doesn't fork the loop into a subshell, so
# EXIT_CODE set inside it is still visible below.
PROJECT_SLUG_FOR_SDD="$(jq -r '.project_slug // empty' .harness.json)"
SDD_MISSING=0
SDD_CHECKED=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  SDD_CHECKED=$((SDD_CHECKED + 1))
  fname=$(jq -r '.name' <<<"$row")
  fstatus=$(jq -r '.status' <<<"$row")
  for f in requirements.md design.md tasks.md; do
    if [ ! -f "specs/$fname/$f" ]; then
      fail "SDD feature '$fname' (status=$fstatus) is missing specs/$fname/$f"
      EXIT_CODE=1
      SDD_MISSING=1
    fi
  done
  # Unticked tasks on the feature being implemented: the reviewer rejects them
  # (C6), so say it now instead of spending a review round on it. Advisory.
  if [ "$fstatus" = in_progress ] && [ -f "specs/$fname/tasks.md" ]; then
    open_tasks=$(grep -oE '^- \[ \] T[0-9]+' "specs/$fname/tasks.md" | sed 's/^- \[ \] //' | tr '\n' ' ' | sed 's/ $//')
    [ -z "$open_tasks" ] || warn "specs/$fname/tasks.md still has unticked tasks: $open_tasks — tick them, or justify each in the handoff, before review"
  fi
done < <(sqlite3 -json "$DB_PATH" "
  SELECT f.name, f.status FROM features f
  JOIN projects p ON p.id = f.project_id
  WHERE p.slug = '$(printf '%s' "$PROJECT_SLUG_FOR_SDD" | sed "s/'/''/g")'
    AND f.sdd = 1 AND f.status IN ('spec_ready','in_progress','done') AND f.deleted_at IS NULL;" 2>/dev/null \
  | jq -c '.[]' 2>/dev/null)

if [ "$SDD_CHECKED" -eq 0 ]; then
  ok "no sdd=1 features past drafting — nothing to check"
elif [ "$SDD_MISSING" -eq 0 ]; then
  ok "all sdd=1 features have their spec files on disk"
fi

echo ""
echo "── 4. Running verification command ─────────────────────"

VERIFY_COMMAND="$(jq -r '.verify_command // empty' .harness.json)"
if [ -z "$VERIFY_COMMAND" ]; then
  warn "No verify_command configured in .harness.json — skipping"
else
  # Output goes to progress/test_last.log, not the terminal: a full suite's
  # output read on every run is one of the biggest token costs of a feature.
  # Agents grep the log instead of re-running the suite to read it.
  mkdir -p progress
  # While a lean-mode feature has an open session, paused (blocked) or not, the tree may hold
  # code its sandboxed sessions wrote: the suite runs under the same rules as their gate
  # (lean/gate.sh, lean/lib.sh lean_sandboxed). The active session's feature is preferred.
  run_verify() { bash -c "$VERIFY_COMMAND"; }
  LEAN_FEATURE=$(sqlite3 "$DB_PATH" "SELECT f.name FROM session_log s JOIN features f ON f.id = s.feature_id
    JOIN projects p ON p.id = s.project_id WHERE p.slug = '$(jq -r '.project_slug // empty' .harness.json | sed "s/'/''/g")'
    AND s.closed_at IS NULL AND s.deleted_at IS NULL AND f.mode IS NOT NULL AND f.deleted_at IS NULL
    ORDER BY s.paused_at IS NOT NULL, s.id DESC LIMIT 1;" 2>/dev/null || true)
  if [ -n "$LEAN_FEATURE" ] && [ ! -f lean/lib.sh ]; then
    warn "lean feature $LEAN_FEATURE is open, but lean/lib.sh is missing: the verification command runs UNSANDBOXED with your full permissions"
  elif [ -n "$LEAN_FEATURE" ]; then
    # shellcheck source=lean/lib.sh
    . lean/lib.sh
    lean_sandbox_prepare "$PWD"
    [ -z "$LEAN_SANDBOX_WARN" ] || while IFS= read -r w; do warn "${w#\[WARN\] }"; done <<<"$LEAN_SANDBOX_WARN"
    case "$LEAN_SANDBOX" in
      sandbox) ok "lean feature $LEAN_FEATURE is open: the verification command runs under its sessions' sandbox rules"
               run_verify() { lean_sandboxed "$PWD" "$VERIFY_COMMAND"; } ;;
      unsandboxed:*) warn "lean feature $LEAN_FEATURE is open, but the verification command runs UNSANDBOXED (${LEAN_SANDBOX#unsandboxed: })" ;;
      *) fail "lean feature $LEAN_FEATURE is open and its sandbox can't run here (${LEAN_SANDBOX#broken: }): run ./init.sh outside any sandbox, or set LEAN_GATE_UNSANDBOXED=1"
         run_verify() { echo "not run: ${LEAN_SANDBOX}"; return 1; } ;;
    esac
  fi
  if { printf '$ %s\n' "$VERIFY_COMMAND"; run_verify; } > progress/test_last.log 2>&1; then
    ok "Verification command passed (output: progress/test_last.log)"
  else
    tail -n 30 progress/test_last.log
    fail "Verification command failed — full output in progress/test_last.log"
    EXIT_CODE=1
  fi
fi

echo ""
echo "── 4a. Refreshing postgres test_helpers (best-effort) ──"

# Optional, gated on .harness.json::test_helpers.enabled. The bundle is
# always copied by install.sh into harness/test_helpers/ — this step
# only installs the PL/pgSQL functions into the project's DB when the
# project opts in. A missing install.sh means install.sh wasn't run yet
# (we add it then); a failure here is best-effort because the user may
# be in a sandbox where the DB isn't reachable.
if jq -e '.test_helpers.enabled == true' .harness.json >/dev/null 2>&1; then
  if [ -f harness/test_helpers/install.sh ]; then
    if bash harness/test_helpers/install.sh; then
      ok "test_helpers enabled (schema: $(jq -r '.test_helpers.schema // "harness_test_helpers"' .harness.json))"
    else
      warn "test_helpers install failed (continuing — verify_command still passed)"
    fi
  else
    warn "test_helpers.enabled is true but harness/test_helpers/install.sh is missing — re-run install.sh --profile postgres"
  fi
else
  ok "test_helpers disabled in .harness.json (skipping)"
fi

echo ""

echo ""
echo "── 4.5. Linting tests for byte-level fingerprints ─────────"

if [ -f "$SCRIPT_DIR/scripts/lint_test_fingerprints.sh" ]; then
    bash "$SCRIPT_DIR/scripts/lint_test_fingerprints.sh" "$SCRIPT_DIR/tests"
    LINT_EXIT=$?
    if [ "$LINT_EXIT" -eq 0 ]; then
        ok "No byte-level fingerprints in tests/"
    elif [ "$LINT_EXIT" -eq 2 ]; then
        warn "No tests/ directory; fingerprint lint skipped"
    else
        fail "Byte-level fingerprint detected in tests/ — see docs/conventions.md#anti-patterns"
        EXIT_CODE=1
    fi
else
    warn "Linter script not found; skipping"
fi

echo ""
echo "── 4.6. Recording agent usage (best-effort) ────────────"

# Runs before the snapshot and the mirror sync so both see fresh agent_runs,
# for Claude Code and Codex CLI alike. Cheap per run: the --since window plus skipping transcripts
# unchanged since they were last parsed. Bounded: --max-seconds is the primary
# limit (macOS has no timeout(1)); timeout/gtimeout, when present, is only an
# outer guard. Never affects EXIT_CODE; per-file warnings collapse into one line.
# Opt out with "record_agent_usage": false in .harness.json.
if jq -e '.record_agent_usage == false' .harness.json >/dev/null 2>&1; then
  ok "record_agent_usage is false in .harness.json (skipping)"
else
  USAGE_GUARD=()
  if command -v timeout >/dev/null 2>&1; then USAGE_GUARD=(timeout 30)
  elif command -v gtimeout >/dev/null 2>&1; then USAGE_GUARD=(gtimeout 30); fi
  USAGE_OUT="$(${USAGE_GUARD[@]+"${USAGE_GUARD[@]}"} bash "$SCRIPT_DIR/scripts/harness.sh" record-usage \
    --max-seconds 15 2>&1 | sed $'s/\033\\[[0-9;]*m//g')" || true
  USAGE_RECORDED="$(printf '%s\n' "$USAGE_OUT" | grep -o 'recorded [0-9]* agent run(s).*' | tail -n 1)"
  USAGE_BUDGET="$(printf '%s\n' "$USAGE_OUT" | grep -E 'token budget:|reopened with' | sed 's/^\[WARN\][[:space:]]*//')"
  USAGE_WARNS="$(printf '%s\n' "$USAGE_OUT" | grep '\[WARN\]' | grep -vcE 'token budget:|reopened with')"
  if [ -n "$USAGE_RECORDED" ] && [ "${USAGE_WARNS:-0}" -eq 0 ]; then
    ok "agent usage: $USAGE_RECORDED"
  elif [ -n "$USAGE_RECORDED" ]; then
    warn "agent usage: $USAGE_RECORDED; $USAGE_WARNS warning(s) — run scripts/harness.sh record-usage for details"
  else
    warn "agent usage not recorded — run scripts/harness.sh record-usage for details (continuing)"
  fi
  while IFS= read -r line; do
    [ -z "$line" ] || warn "$line"
  done <<<"$USAGE_BUDGET"
fi

echo ""
echo "── 5. Regenerating markdown snapshot ───────────────────"

if bash "$SCRIPT_DIR/scripts/snapshot.sh"; then
  :
else
  fail "Snapshot regeneration failed"
  EXIT_CODE=1
fi

echo ""
echo "── 6. Syncing Postgres/Supabase mirror (best-effort) ───"

bash "$SCRIPT_DIR/scripts/sync_postgres.sh"
# Deliberately not gated on this command's exit code: the mirror is
# optional, and every failure path inside sync_postgres.sh already prints
# its own [WARN] rather than propagating as a session-blocking error.

# log-out reads this from the active session: the overall result (a run
# without verify_command is "none", never a pass) plus a fingerprint of the
# tree it ran on.
INIT_RESULT=fail
if [ $EXIT_CODE -eq 0 ]; then
  if [ -n "$VERIFY_COMMAND" ]; then INIT_RESULT=pass; else INIT_RESULT=none; fi
fi
bash "$SCRIPT_DIR/scripts/harness.sh" record-init "$INIT_RESULT" >/dev/null 2>&1 || true

echo ""
echo "── 7. Summary ───────────────────────────────────────────"

if [ $EXIT_CODE -eq 0 ]; then
  ok "Environment ready. You can start working."
else
  fail "Environment NOT ready. Resolve the errors above before continuing."
fi

exit $EXIT_CODE
