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
  if bash -c "$VERIFY_COMMAND"; then
    ok "Verification command passed"
  else
    fail "Verification command failed"
    EXIT_CODE=1
  fi
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

echo ""
echo "── 7. Summary ───────────────────────────────────────────"

if [ $EXIT_CODE -eq 0 ]; then
  ok "Environment ready. You can start working."
else
  fail "Environment NOT ready. Resolve the errors above before continuing."
fi

exit $EXIT_CODE
