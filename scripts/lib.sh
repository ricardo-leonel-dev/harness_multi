#!/usr/bin/env bash
# lib.sh — shared helpers for scripts/harness.sh. Sourced, not executed directly.
#
# Prerequisites: sqlite3, jq, curl (curl only needed if the Postgres mirror
# is configured — everything else works without it).

set -u

HARNESS_CONFIG="${HARNESS_CONFIG:-.harness.json}"

require_config() {
  if [ ! -f "$HARNESS_CONFIG" ]; then
    echo "[FAIL] $HARNESS_CONFIG not found. Run install.sh first." >&2
    exit 1
  fi
}

config() {
  # config <jq-path> [default]
  # Fallback happens inside jq, not bash: jq's `//` only treats null/false/
  # missing as absent, so a deliberately-set "" (e.g. supabase_rest_path)
  # is preserved instead of being clobbered by a bash `[ -z ]` check.
  local path="$1" default="${2:-}"
  jq -r --arg d "$default" "($path) // \$d" "$HARNESS_CONFIG" 2>/dev/null
}

require_config
DB_PATH="$(config '.db_path' 'harness.db')"
SNAPSHOT_PATH="$(config '.snapshot_path' 'state')"
PROJECT_SLUG="$(config '.project_slug')"

if [ ! -f "$DB_PATH" ]; then
  echo "[FAIL] $DB_PATH not found. Run install.sh first." >&2
  exit 1
fi

# Forward-only migrations for harness.db files created before a schema
# addition existed. Each check is idempotent (safe to run on every
# invocation) so older installs pick up new columns without a manual step.
if ! sqlite3 "$DB_PATH" "PRAGMA table_info(features);" | grep -q '|source_id|'; then
  sqlite3 "$DB_PATH" "ALTER TABLE features ADD COLUMN source_id TEXT;"
  sqlite3 "$DB_PATH" "CREATE UNIQUE INDEX IF NOT EXISTS features_source_id_active ON features(project_id, source_id) WHERE deleted_at IS NULL AND source_id IS NOT NULL;"
fi

db() {
  sqlite3 "$DB_PATH" "$@"
}

# Run one or more ; separated SQL statements, failing loudly on error.
db_exec() {
  sqlite3 "$DB_PATH" <<SQL
.bail on
$1
SQL
}

# Escape a value for embedding as a single-quoted SQL string literal.
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%S.000Z"
}

# Build a JSON array (as a SQL-escaped string literal body) from args.
json_array() {
  jq -c -n '$ARGS.positional' --args -- "$@" 2>/dev/null || echo '[]'
}

warn() { printf '[WARN]  %s\n' "$1" >&2; }
ok()   { printf '[OK]    %s\n' "$1"; }
fail() { printf '[FAIL]  %s\n' "$1" >&2; }
