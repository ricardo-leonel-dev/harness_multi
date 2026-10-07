#!/usr/bin/env bash
# uninstall.sh — drops the harness_test_helpers schema. Idempotent.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok()   { printf '[OK]    %s\n' "$1"; }
fail() { printf '[FAIL]  %s\n' "$1" >&2; }

PSQL_BIN=""
for candidate in /opt/homebrew/Cellar/postgresql@16/*/bin/psql /opt/homebrew/Cellar/postgresql@15/*/bin/psql /usr/bin/psql; do
    if [ -x "$candidate" ]; then PSQL_BIN="$candidate"; break; fi
done
if [ -z "$PSQL_BIN" ] && command -v psql >/dev/null 2>&1; then PSQL_BIN="$(command -v psql)"; fi
if [ -z "$PSQL_BIN" ]; then fail "psql not found"; exit 1; fi

PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd 2>/dev/null)}"
PSQL_ARGS=""
if [ -f "$PROJECT_DIR/.harness.json" ]; then
    verify_cmd="$(jq -r '.verify_command // empty' "$PROJECT_DIR/.harness.json")"
    for flag in h p U d; do
        v=$(printf '%s\n' "$verify_cmd" | sed -nE "s/.*[[:space:]]-$flag[[:space:]]+([^[:space:]]+).*/\1/p" | head -n1)
        if [ -n "$v" ]; then PSQL_ARGS="$PSQL_ARGS -$flag $v"; fi
    done
    pwd_val=$(printf '%s\n' "$verify_cmd" | sed -nE "s/.*PGPASSWORD=([^[:space:]]+).*/\1/p" | head -n1)
    if [ -n "$pwd_val" ]; then export PGPASSWORD="$pwd_val"; fi
fi
if [ -z "$PSQL_ARGS" ]; then
    PSQL_ARGS="-h ${PSQL_HOST:-localhost} -p ${PSQL_PORT:-5432} -U ${PSQL_USER:-postgres} -d ${PSQL_DB:-postgres}"
fi

if ! PGPASSWORD="${PGPASSWORD:-}" $PSQL_BIN $PSQL_ARGS -v ON_ERROR_STOP=1 -f "$SCRIPT_DIR/uninstall.sql" >/dev/null 2>&1; then
    fail "uninstall.sql failed"
    exit 1
fi
ok "dropped schema harness_test_helpers"