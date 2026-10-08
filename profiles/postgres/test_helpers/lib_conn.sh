# lib_conn.sh — sourced by install.sh and uninstall.sh so both resolve the
# same psql binary and connection target. Not executable on its own.
#
# Inputs:  SCRIPT_DIR (directory of the sourcing script), optional PROJECT_DIR.
# Outputs: PSQL_BIN, PSQL_HOST, PSQL_PORT, PSQL_USER, PSQL_DB, exported
#          PGPASSWORD (when found). Returns 1 if psql cannot be found.
#
# Connection resolution, in order:
# 1. Env vars: PSQL_{HOST,PORT,USER,DB}, then PG{HOST,PORT,USER,DATABASE}.
# 2. The -h/-p/-U/-d flags and PGPASSWORD=... of .harness.json::verify_command.
# 3. Defaults: localhost:5432, user postgres, db postgres.
#
# Strategy 2 has a wrinkle for projects whose verify_command is a database
# existence check rather than a real connection — e.g.
#   psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='web-display';"
# connects to `postgres` to ask whether `web-display` exists, so the
# extracted -d is `postgres` rather than the project's actual db. When
# we detect that pattern, we substitute the datname from the query as
# the real connection target.

resolve_psql_bin() {
    PSQL_BIN=""
    local candidate
    for candidate in /opt/homebrew/Cellar/postgresql@16/*/bin/psql /opt/homebrew/Cellar/postgresql@15/*/bin/psql /usr/bin/psql; do
        if [ -x "$candidate" ]; then
            PSQL_BIN="$candidate"
            break
        fi
    done
    if [ -z "$PSQL_BIN" ] && command -v psql >/dev/null 2>&1; then
        PSQL_BIN="$(command -v psql)"
    fi
    [ -n "$PSQL_BIN" ]
}

resolve_psql_conn() {
    PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd 2>/dev/null)}"
    PSQL_HOST="${PSQL_HOST:-${PGHOST:-}}"
    PSQL_PORT="${PSQL_PORT:-${PGPORT:-}}"
    PSQL_USER="${PSQL_USER:-${PGUSER:-}}"
    PSQL_DB="${PSQL_DB:-${PGDATABASE:-}}"
    if [ -z "${PGPASSWORD:-}" ] && [ -n "${PG_PASSWORD:-}" ]; then export PGPASSWORD="$PG_PASSWORD"; fi

    if [ -f "$PROJECT_DIR/.harness.json" ]; then
        local verify_cmd flag v real_db pwd_val
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
}

# Refuses any host not explicitly allowed, so a verify_command (or PG* env)
# pointing at a shared/remote database never gets the helpers installed —
# they run DDL and are EXECUTE-able by PUBLIC. Allowed by default: local
# hosts and Unix sockets (an empty host or a path). Projects whose dev DB is
# elsewhere list it in .harness.json::test_helpers.allowed_hosts (an array;
# setting it replaces the local defaults, sockets stay allowed).
# Sets ALLOWED_HOSTS (space-separated) for error messages. Returns 1 if refused.
check_host_allowed() {
    ALLOWED_HOSTS="localhost 127.0.0.1 ::1"
    if [ -f "$PROJECT_DIR/.harness.json" ] \
        && jq -e '.test_helpers.allowed_hosts | type == "array"' "$PROJECT_DIR/.harness.json" >/dev/null 2>&1; then
        ALLOWED_HOSTS="$(jq -r '.test_helpers.allowed_hosts | map(tostring) | join(" ")' "$PROJECT_DIR/.harness.json")"
    fi
    case "$PSQL_HOST" in
        ''|/*) return 0 ;;
    esac
    local h
    for h in $ALLOWED_HOSTS; do
        [ "$h" = "$PSQL_HOST" ] && return 0
    done
    return 1
}

# Directory holding project-owned Tier 2 helpers, relative to PROJECT_DIR.
# Lives outside harness/ on purpose: harness/ is excluded from git by the
# toolkit's install.sh, and Tier 2 files must be versioned with the project.
resolve_project_specific_dir() {
    local rel="test_helpers"
    if [ -f "$PROJECT_DIR/.harness.json" ]; then
        rel="$(jq -r '.test_helpers.project_specific_dir // "test_helpers"' "$PROJECT_DIR/.harness.json")"
    fi
    PROJECT_SPECIFIC_DIR="$PROJECT_DIR/$rel"
}
