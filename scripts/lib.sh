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

# resolve_indirect <env-var-name>
# Given the NAME of an env var (already resolved from .harness.json, e.g. via
# `config '.notion_token_env' 'NOTION_API_TOKEN'`), returns its value — tried in order:
#   1. already exported in this process — always wins, never overridden.
#   2. `set -gx/-x/-Ux <name> <value>` in ~/.config/fish/config.fish, if present — fish
#      is this machine's primary interactive shell, so it's treated as the live source
#      of truth (a narrow regex for this one line shape, not a general fish parser).
#   3. ~/.harness_env (`export NAME=value`, plain bash), if present — portable fallback
#      for machines without fish, or a single place to override 1/2.
# This matters for unattended agents (e.g. Codex running claim/log-out/init.sh on its
# own, not typed by the user) whose exec environment may not mirror an interactive
# shell 1:1 — callers shouldn't have to rely on however that environment got inherited.
resolve_indirect() {
  local name="$1"
  [ -n "$name" ] || return 0
  local val="${!name:-}"

  if [ -z "$val" ] && [ -f "$HOME/.config/fish/config.fish" ]; then
    val="$(sed -n -E "s/^set[[:space:]]+-[A-Za-z]*x[A-Za-z]*[[:space:]]+${name}[[:space:]]+(.*)\$/\1/p" \
      "$HOME/.config/fish/config.fish" 2>/dev/null | tail -n1 | sed -E "s/^['\"]//; s/['\"]\$//")"
  fi

  if [ -z "$val" ] && [ -f "$HOME/.harness_env" ]; then
    val="$( (set -a; source "$HOME/.harness_env" >/dev/null 2>&1; printf '%s' "${!name:-}") )"
  fi

  printf '%s' "$val"
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
