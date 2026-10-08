#!/usr/bin/env bash
# install.sh — installs harness_test_helpers into the project's dev/test DB,
# then loads any project-owned Tier 2 helpers (see README.md).
# Runs from any working directory; the connection is resolved by lib_conn.sh
# (env vars, then .harness.json::verify_command, then defaults).
#
# Required tools: psql (in PATH or under /opt/homebrew/Cellar/postgresql@*/bin), jq.
#
# Exit codes: 0 on success, 1 on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_conn.sh
. "$SCRIPT_DIR/lib_conn.sh"

ok()   { printf '[OK]    %s\n' "$1"; }
warn() { printf '[WARN]  %s\n' "$1"; }
fail() { printf '[FAIL]  %s\n' "$1" >&2; }

if ! resolve_psql_bin; then
    fail "psql not found in PATH or /opt/homebrew/Cellar/postgresql@*/bin"
    exit 1
fi
resolve_psql_conn
if ! check_host_allowed; then
    fail "refusing to install into host '$PSQL_HOST' (allowed: $ALLOWED_HOSTS) — add it to .harness.json::test_helpers.allowed_hosts if it is a dev/test database"
    exit 1
fi
PSQL=("$PSQL_BIN" -X -h "$PSQL_HOST" -p "$PSQL_PORT" -U "$PSQL_USER" -d "$PSQL_DB")

if ! "${PSQL[@]}" -tAc "SELECT 1" >/dev/null 2>&1; then
    fail "could not connect to: ${PSQL[*]} (check PGPASSWORD / env)"
    exit 1
fi
ok "connected via: ${PSQL[*]} (db=$PSQL_DB)"

INSTALL_LOG="$(mktemp -t helpers_install.XXXXXX)"

if ! "${PSQL[@]}" -v ON_ERROR_STOP=1 -f "$SCRIPT_DIR/install.sql" >/dev/null 2>"$INSTALL_LOG"; then
    fail "install.sql failed; tail of log:"
    tail -n 20 "$INSTALL_LOG" >&2
    rm -f "$INSTALL_LOG"
    exit 1
fi
ok "installed harness_test_helpers (6 functions, GRANT EXECUTE TO PUBLIC)"

# Tier 2: project-owned per-table helpers, loaded in name order after Tier 1.
resolve_project_specific_dir
if [ -d "$PROJECT_SPECIFIC_DIR" ]; then
    loaded=0
    for f in "$PROJECT_SPECIFIC_DIR"/*.sql; do
        [ -f "$f" ] || continue
        if ! "${PSQL[@]}" -v ON_ERROR_STOP=1 -f "$f" >/dev/null 2>"$INSTALL_LOG"; then
            fail "Tier 2 helper failed: $f; tail of log:"
            tail -n 20 "$INSTALL_LOG" >&2
            rm -f "$INSTALL_LOG"
            exit 1
        fi
        loaded=$((loaded + 1))
    done
    ok "loaded $loaded project-specific helper(s) from ${PROJECT_SPECIFIC_DIR#"$PROJECT_DIR"/}/"
fi
rm -f "$INSTALL_LOG"
