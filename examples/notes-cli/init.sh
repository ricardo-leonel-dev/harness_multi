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
echo "── 3. Running verification command ─────────────────────"

VERIFY_COMMAND="$(jq -r '.verify_command // empty' .harness.json)"
if [ -z "$VERIFY_COMMAND" ]; then
  warn "No verify_command configured in .harness.json — skipping"
else
  if bash -c "$VERIFY_COMMAND"; then
    ok "Verification command passed"
  else
    fail "Verification command failed"
    EXIT_CODE=1
  fi
fi

echo ""
echo "── 4. Regenerating markdown snapshot ───────────────────"

if bash "$SCRIPT_DIR/scripts/snapshot.sh"; then
  :
else
  fail "Snapshot regeneration failed"
  EXIT_CODE=1
fi

echo ""
echo "── 5. Syncing Postgres/Supabase mirror (best-effort) ───"

bash "$SCRIPT_DIR/scripts/sync_postgres.sh"
# Deliberately not gated on this command's exit code: the mirror is
# optional, and every failure path inside sync_postgres.sh already prints
# its own [WARN] rather than propagating as a session-blocking error.

echo ""
echo "── 6. Summary ───────────────────────────────────────────"

if [ $EXIT_CODE -eq 0 ]; then
  ok "Environment ready. You can start working."
else
  fail "Environment NOT ready. Resolve the errors above before continuing."
fi

exit $EXIT_CODE
