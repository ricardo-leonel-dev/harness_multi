#!/usr/bin/env bash
# uninstall.sh — drops the harness_test_helpers schema. Idempotent.
# Resolves the connection exactly like install.sh (via lib_conn.sh), so it
# always drops from the same database install.sh installed into.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_conn.sh
. "$SCRIPT_DIR/lib_conn.sh"

ok()   { printf '[OK]    %s\n' "$1"; }
fail() { printf '[FAIL]  %s\n' "$1" >&2; }

if ! resolve_psql_bin; then fail "psql not found"; exit 1; fi
resolve_psql_conn
if ! check_host_allowed; then
    fail "refusing to touch host '$PSQL_HOST' (allowed: $ALLOWED_HOSTS) — see .harness.json::test_helpers.allowed_hosts"
    exit 1
fi
PSQL=("$PSQL_BIN" -X -h "$PSQL_HOST" -p "$PSQL_PORT" -U "$PSQL_USER" -d "$PSQL_DB")

if ! "${PSQL[@]}" -v ON_ERROR_STOP=1 -f "$SCRIPT_DIR/uninstall.sql" >/dev/null 2>&1; then
    fail "uninstall.sql failed against db=$PSQL_DB"
    exit 1
fi
ok "dropped schema harness_test_helpers (db=$PSQL_DB)"
