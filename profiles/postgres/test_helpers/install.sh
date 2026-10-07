#!/usr/bin/env bash
# install.sh — installs harness_test_helpers into the project's dev/test DB.
# Runs from any working directory; reads the conn string the same way
# init.sh's verify_command does (.harness.json::verify_command if available,
# otherwise well-known env vars: PSQL_{HOST,PORT,USER,DB}).
#
# Required tools: psql (in PATH or under /opt/homebrew/Cellar/postgresql@*/bin).
#
# Exit codes: 0 on success, 1 on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok()   { printf '[OK]    %s\n' "$1"; }
warn() { printf '[WARN]  %s\n' "$1"; }
fail() { printf '[FAIL]  %s\n' "$1" >&2; }

PSQL_BIN=""
for candidate in /opt/homebrew/Cellar/postgresql@16/*/bin/psql /opt/homebrew/Cellar/postgresql@15/*/bin/psql /usr/bin/psql; do
    if [ -x "$candidate" ]; then
        PSQL_BIN="$candidate"
        break
    fi
done
if [ -z "$PSQL_BIN" ] && command -v psql >/dev/null 2>&1; then
    PSQL_BIN="$(command -v psql)"
fi
if [ -z "$PSQL_BIN" ]; then
    fail "psql not found in PATH or /opt/homebrew/Cellar/postgresql@*/bin"
    exit 1
fi

# Resolve connection string. Three strategies, in order:
# 1. Env vars: PSQL_{HOST,PORT,USER,DB} + PGPASSWORD / PG{PASSWORD,HOST,PORT,USER,DATABASE}.
# 2. Reuse the verify_command from .harness.json: extract -h, -p, -U, -d, PGPASSWORD.
# 3. Fall back to defaults.
#
# Strategy 2 has a wrinkle for projects whose verify_command is a database
# existence check rather than a real connection — e.g.
#   psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='web-display';"
# connects to `postgres` to ask whether `web-display` exists, so the
# extracted -d is `postgres` rather than the project's actual db. When
# we detect that pattern, we substitute the datname from the query as
# the real connection target.
PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd 2>/dev/null)}"
PSQL_ARGS=""
PSQL_HOST="${PSQL_HOST:-${PGHOST:-}}"
PSQL_PORT="${PSQL_PORT:-${PGPORT:-}}"
PSQL_USER="${PSQL_USER:-${PGUSER:-}}"
PSQL_DB="${PSQL_DB:-${PGDATABASE:-}}"
if [ -z "${PGPASSWORD:-}" ] && [ -n "${PG_PASSWORD:-}" ]; then export PGPASSWORD="$PG_PASSWORD"; fi

if [ -f "$PROJECT_DIR/.harness.json" ]; then
    verify_cmd="$(jq -r '.verify_command // empty' "$PROJECT_DIR/.harness.json")"
    for flag in h p U d; do
        v=$(printf '%s\n' "$verify_cmd" | sed -nE "s/.*[[:space:]]-$flag[[:space:]]+([^[:space:]]+).*/\1/p" | head -n1)
        case "$flag" in
            h) [ -z "$PSQL_HOST" ] && [ -n "$v" ] && PSQL_HOST="$v" ;;
            p) [ -z "$PSQL_PORT" ] && [ -n "$v" ] && PSQL_PORT="$v" ;;
            U) [ -z "$PSQL_USER" ] && [ -n "$v" ] && PSQL_USER="$v" ;;
            d) [ -z "$PSQL_DB"   ] && [ -n "$v" ] && PSQL_DB="$v"   ;;
        esac
    done
    # If the verify_command targets a default-like db (postgres/template1)
    # AND its query asks about pg_database, swap the target to the actual
    # project database name from the query.
    if [ "$PSQL_DB" = "postgres" ] || [ "$PSQL_DB" = "template1" ]; then
        real_db=$(printf '%s\n' "$verify_cmd" | sed -nE "s/.*WHERE[[:space:]]+datname[[:space:]]*=[[:space:]]*'([^']+)'.*/\1/p" | head -n1)
        if [ -n "$real_db" ]; then PSQL_DB="$real_db"; fi
    fi
    if [ -z "${PGPASSWORD:-}" ]; then
        pwd_val=$(printf '%s\n' "$verify_cmd" | sed -nE "s/.*PGPASSWORD=([^[:space:]]+).*/\1/p" | head -n1)
        if [ -n "$pwd_val" ]; then export PGPASSWORD="$pwd_val"; fi
    fi
fi

PSQL_HOST="${PSQL_HOST:-localhost}"
PSQL_PORT="${PSQL_PORT:-5432}"
PSQL_USER="${PSQL_USER:-postgres}"
PSQL_DB="${PSQL_DB:-postgres}"
PSQL_ARGS="-h $PSQL_HOST -p $PSQL_PORT -U $PSQL_USER -d $PSQL_DB"

if ! PGPASSWORD="${PGPASSWORD:-}" $PSQL_BIN $PSQL_ARGS -tAc "SELECT 1" >/dev/null 2>&1; then
    fail "could not connect to: $PSQL_BIN $PSQL_ARGS (check PGPASSWORD / env)"
    exit 1
fi
ok "connected via: $PSQL_BIN $PSQL_ARGS (db=$PSQL_DB)"

# Use a script-local psql variable so install.sql can \i the function
# files with paths relative to this directory. Without this, psql
# resolves \i against the current working directory, which won't have
# functions/ when init.sh runs from a project root.
HELPERS_DIR="$SCRIPT_DIR"
INSTALL_LOG="$(mktemp -t helpers_install.XXXXXX.log)"

if ! PGPASSWORD="${PGPASSWORD:-}" $PSQL_BIN $PSQL_ARGS \
    -v ON_ERROR_STOP=1 \
    -v helpers_dir="$HELPERS_DIR" \
    -f "$SCRIPT_DIR/install.sql" >/dev/null 2>"$INSTALL_LOG"; then
    fail "install.sql failed; tail of log:"
    tail -n 20 "$INSTALL_LOG" >&2
    rm -f "$INSTALL_LOG"
    exit 1
fi
rm -f "$INSTALL_LOG"
ok "installed harness_test_helpers (6 functions, GRANT EXECUTE TO PUBLIC)"