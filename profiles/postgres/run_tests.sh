#!/usr/bin/env bash
# run_tests.sh — Level 2 functional test runner (see docs/verification.md).
#
# Runs tests/*_acceptance.sql against the shared Postgres instance. Each test
# file already wraps itself in BEGIN;...ROLLBACK; (never COMMIT — this
# instance is shared across the whole team), so this script just feeds each
# file to psql and checks its exit code.
#
# Two scopes:
#   --changed   only test files touched since $BASE_REF (fast, for the
#               implementer's own dev-loop iterations)
#   --all       every tests/*.sql file (the mandatory gate before log-out /
#               reviewer approval — see docs/verification.md)
# Default (no flag): --all, so forgetting the flag never silently narrows
# the safety net.
#
# Baseline cache (DB-schema projects with stale tests are common; this avoids
# making every implementer re-investigate the same pre-existing failures):
#   --baseline <path>        load pre-existing failures from <path>; failures
#                            in the baseline are reported as [STALE] instead
#                            of [FAIL]. Tests that fail but were NOT in the
#                            baseline are [REGRESSION] (non-zero exit).
#   --baseline-write <path>  after the run, write the list of currently
#                            failing test files to <path> (one basename per
#                            line, # comments). Combined with --baseline,
#                            this lets a human periodically refresh the
#                            known-stale set.
#   --no-baseline            skip auto-loading progress/.test_baseline even
#                            if it exists (the harness auto-loads it when no
#                            --baseline flag is passed, so this is the
#                            explicit override for callers that want every
#                            failure to be a hard [FAIL]).
#
# Auto-load: when no --baseline flag is passed AND --no-baseline is not set,
# the harness auto-loads progress/.test_baseline if the file exists. This
# makes the baseline cache the default behavior in DB-schema projects once a
# baseline has been captured - implementers no longer need to remember a flag
# to avoid getting stuck on pre-existing test failures.
#
# Token-saving design (see Anti-Telephone Rule, AGENTS.md §0): psql's own
# chatter (DO/BEGIN/ROLLBACK command tags, NOTICEs) is suppressed and the
# full transcript of each test file goes to a log file under
# progress/test_runs/, not to stdout. Only a one-line-per-file summary is
# printed — that summary is what actually reaches an agent's context.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PSQL_BIN="${PSQL_BIN:-/opt/homebrew/Cellar/postgresql@16/16.11_1/bin/psql}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5439}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-Berlin2020}"
PGDATABASE="${PGDATABASE:-web-display}"
export PGPASSWORD

MODE="all"
BASE_OVERRIDE=""
BASELINE_FILE=""
BASELINE_WRITE_FILE=""
BASELINE_FAILS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --changed) MODE="changed" ;;
    --all) MODE="all" ;;
    --base) shift; BASE_OVERRIDE="${1:-}" ;;
    --baseline) shift; BASELINE_FILE="${1:-}" ;;
    --baseline-write) shift; BASELINE_WRITE_FILE="${1:-}" ;;
    --no-baseline) BASELINE_FILE="__disabled__" ;;
    -h|--help)
      echo "Usage: $0 [--changed [--base <git-ref>] | --all] [--baseline <path>] [--baseline-write <path>] [--no-baseline]"
      echo ""
      echo "  --baseline <path>        load pre-existing failures from <path>; failures in the"
      echo "                           baseline are reported as [STALE] (informational) instead"
      echo "                           of [FAIL] (blocker). Tests failing that were NOT in the"
      echo "                           baseline are reported as [REGRESSION] and cause a"
      echo "                           non-zero exit. See docs/verification.md."
      echo "                           Auto-loaded from progress/.test_baseline when no flag"
      echo "                           is passed and the file exists."
      echo "  --baseline-write <path>  after the run, write the list of currently failing test"
      echo "                           files to <path> (one basename per line, # comments)."
      echo "  --no-baseline            skip the auto-load of progress/.test_baseline; treat"
      echo "                           every failure as a hard [FAIL] (non-zero exit)."
      exit 0
      ;;
    *)
      echo "[FAIL]  unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

if [ ! -x "$PSQL_BIN" ]; then
  echo "[FAIL]  psql binary not found/executable at $PSQL_BIN (set \$PSQL_BIN to override)" >&2
  exit 1
fi

# Auto-load baseline: if the caller did not pass --baseline or --no-baseline,
# and progress/.test_baseline exists in the project, treat it as the baseline.
# This is the default behavior for DB-schema projects once a baseline has
# been captured (see header doc comment).
if [ "$BASELINE_FILE" = "" ] && [ -f "progress/.test_baseline" ]; then
  BASELINE_FILE="progress/.test_baseline"
  echo "[INFO]  auto-loading baseline: progress/.test_baseline (use --no-baseline to skip)"
elif [ "$BASELINE_FILE" = "__disabled__" ]; then
  BASELINE_FILE=""
  echo "[INFO]  --no-baseline set; skipping auto-load of progress/.test_baseline"
fi

# Collect the list of test files to run into $TEST_FILES.
TEST_FILES=""

if [ "$MODE" = "all" ]; then
  TEST_FILES="$(ls tests/*.sql 2>/dev/null)"
else
  if [ -n "$BASE_OVERRIDE" ]; then
    base="$BASE_OVERRIDE"
  elif git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    base="$(git merge-base origin/main HEAD 2>/dev/null || echo HEAD~1)"
  else
    base="HEAD~1"
  fi
  echo "[INFO]  --changed mode: diffing tests/ against $base (includes uncommitted + untracked new files)"
  TEST_FILES="$( { git diff --name-only --diff-filter=ACM "$base" -- tests/*.sql 2>/dev/null; \
                   git ls-files --others --exclude-standard -- tests/*.sql 2>/dev/null; } | sort -u)"
fi

if [ -z "$TEST_FILES" ]; then
  echo "[OK]    no test files to run (mode=$MODE)"
  exit 0
fi

# Load baseline (if --baseline). Files listed here will be reported as
# [STALE] (informational) on failure rather than [FAIL] (blocker). Anything
# that fails and is NOT in the baseline is a [REGRESSION] and exits non-zero.
if [ -n "$BASELINE_FILE" ]; then
    if [ -f "$BASELINE_FILE" ]; then
        BASELINE_FAILS="$(grep -v '^[[:space:]]*#' "$BASELINE_FILE" | grep -v '^[[:space:]]*$' || true)"
        stale_count="$(printf '%s\n' "$BASELINE_FAILS" | grep -c . || echo 0)"
        echo "[INFO]  --baseline $BASELINE_FILE: $stale_count pre-existing failures marked STALE"
    else
        echo "[WARN]  --baseline $BASELINE_FILE not found; treating as empty (all failures are regressions)"
    fi
fi

RUN_DIR="progress/test_runs/$(date -u +%Y%m%dT%H%M%SZ)_${MODE}"
mkdir -p "$RUN_DIR"

PASS_COUNT=0
FAIL_COUNT=0
STALE_COUNT=0
FAILED_FILES=""

while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ ! -f "$f" ]; then
    echo "[WARN]  $f no longer exists on disk — skipping"
    continue
  fi

  base_name="$(basename "$f")"
  log_file="$RUN_DIR/${base_name}.log"

  if "$PSQL_BIN" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
      -q -v ON_ERROR_STOP=1 -f "$f" >"$log_file" 2>&1; then
    assertions="$(grep -c '^ *PASS *|' "$log_file" 2>/dev/null || echo 0)"
    echo "[PASS]  $base_name ($assertions assertion(s))"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    tail_lines="$(tail -n 5 "$log_file" 2>/dev/null | sed 's/^/        | /')"
    if [ -n "$BASELINE_FILE" ] && printf '%s\n' "$BASELINE_FAILS" | grep -Fxq "$base_name"; then
      echo "[STALE] $base_name (pre-existing failure per --baseline; see $log_file)"
      printf '%s\n' "$tail_lines"
      STALE_COUNT=$((STALE_COUNT + 1))
    else
      echo "[FAIL]  $base_name — see $log_file"
      printf '%s\n' "$tail_lines"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_FILES="$FAILED_FILES $base_name"
    fi
  fi
done <<EOF
$TEST_FILES
EOF

echo ""
echo "── Summary (mode=$MODE) ──────────────────────────────"
if [ -n "$BASELINE_FILE" ]; then
  echo "  passed: $PASS_COUNT   stale: $STALE_COUNT   regressions: $FAIL_COUNT"
else
  echo "  passed: $PASS_COUNT   failed: $FAIL_COUNT"
fi
echo "  full logs: $RUN_DIR/"

# --baseline-write: capture the current set of failing files (raw FAILs, not
# STALEs — so the next --baseline run only suppresses tests that are STILL
# broken; a test that was fixed between captures no longer shows up).
if [ -n "$BASELINE_WRITE_FILE" ] && [ -n "$FAILED_FILES" ]; then
    mkdir -p "$(dirname "$BASELINE_WRITE_FILE")"
    {
        echo "# test baseline captured $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# format: one basename per line; lines starting with # are comments"
        for f in $FAILED_FILES; do echo "$f"; done
    } > "$BASELINE_WRITE_FILE"
    captured="$(echo $FAILED_FILES | wc -w | tr -d ' ')"
    echo "[OK]    baseline written: $BASELINE_WRITE_FILE ($captured failing test(s))"
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  if [ -n "$BASELINE_FILE" ]; then
    echo "[FAIL]  regression(s) detected (not in baseline):$FAILED_FILES"
  else
    echo "[FAIL]  failing test files:$FAILED_FILES"
  fi
  exit 1
fi

if [ -n "$BASELINE_FILE" ] && [ "$STALE_COUNT" -gt 0 ]; then
  echo "[OK]    no regressions; $STALE_COUNT pre-existing failures remain STALE per --baseline $BASELINE_FILE"
else
  echo "[OK]    all selected tests passed"
fi
exit 0
