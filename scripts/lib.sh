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

# Adds features.sdd + expands the status CHECK to include spec_drafting/
# spec_ready, and creates the specs table (metadata only — spec content
# lives as files at specs/<name>/, never in this table). SQLite has no
# ALTER TABLE ... ALTER CHECK, so the features change requires the standard
# 12-step rebuild; the specs table itself is a plain CREATE TABLE IF NOT
# EXISTS, gated by the same probe so both land together on first run.
if ! sqlite3 "$DB_PATH" "PRAGMA table_info(features);" | grep -q '|sdd|'; then
  sqlite3 "$DB_PATH" <<'SQL'
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;

CREATE TABLE features_new (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  feature_number INTEGER NOT NULL,
  name TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  acceptance TEXT NOT NULL DEFAULT '[]',
  sdd INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'spec_drafting', 'spec_ready', 'in_progress', 'done', 'blocked')),
  source_id TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at TEXT
);

INSERT INTO features_new (id, project_id, feature_number, name, title, description, acceptance, sdd, status, source_id, created_at, updated_at, deleted_at)
  SELECT id, project_id, feature_number, name, title, description, acceptance, 0, status, source_id, created_at, updated_at, deleted_at
  FROM features;

DROP TABLE features;
ALTER TABLE features_new RENAME TO features;

CREATE UNIQUE INDEX features_number_active ON features(project_id, feature_number) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX features_name_active ON features(project_id, name) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX features_source_id_active ON features(project_id, source_id)
  WHERE deleted_at IS NULL AND source_id IS NOT NULL;
CREATE UNIQUE INDEX one_in_progress_per_project ON features(project_id)
  WHERE status = 'in_progress' AND deleted_at IS NULL;
CREATE INDEX idx_features_project_status ON features(project_id, status);

CREATE TABLE IF NOT EXISTS specs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  feature_id INTEGER NOT NULL REFERENCES features(id) ON DELETE CASCADE,
  path TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'drafting'
    CHECK (status IN ('drafting', 'ready', 'approved')),
  requirements_count INTEGER,
  tasks_count INTEGER,
  drafted_by TEXT,
  ready_at TEXT,
  approved_at TEXT,
  approved_by TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS specs_feature_active ON specs(feature_id) WHERE deleted_at IS NULL;

COMMIT;
PRAGMA foreign_key_check;
PRAGMA foreign_keys=ON;
SQL
fi

# Adds session_log.review_status/reviewed_by/reviewed_at — the mechanical
# gate that makes log-out refuse to close a session (and mark its feature
# done) without a recorded reviewer verdict, instead of relying on every
# agent/prompt to remember the implementer->reviewer->implementer handoff.
# Plain ADD COLUMN is enough here — no CHECK constraint at the DB level, so
# no 12-step rebuild like the sdd migration above; record-review validates
# the verdict value in bash before writing it.
if ! sqlite3 "$DB_PATH" "PRAGMA table_info(session_log);" | grep -q '|review_status|'; then
  sqlite3 "$DB_PATH" "ALTER TABLE session_log ADD COLUMN review_status TEXT;"
  sqlite3 "$DB_PATH" "ALTER TABLE session_log ADD COLUMN reviewed_by TEXT;"
  sqlite3 "$DB_PATH" "ALTER TABLE session_log ADD COLUMN reviewed_at TEXT;"
fi

# Adds features.depends_on — a JSON array of *local* feature names (same
# project) that must all be 'done' before this feature is claimable. This is
# the mechanical fix for a real incident: a feature was explicitly claimed
# and blocked before another feature in the same project that it textually
# depended on ("Depende de X" in its own description) had even been started,
# because nothing checked that prose. `claim` now refuses instead of
# silently allowing out-of-order work — same "real DB constraint, not just a
# convention" posture already used for sdd/spec approval. Plain ADD COLUMN
# is enough (no CHECK constraint at the DB level): membership against the
# JSON array is validated at claim time via json_each, not by SQLite itself.
if ! sqlite3 "$DB_PATH" "PRAGMA table_info(features);" | grep -q '|depends_on|'; then
  sqlite3 "$DB_PATH" "ALTER TABLE features ADD COLUMN depends_on TEXT NOT NULL DEFAULT '[]';"
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

# Build a standardized agent attribution string in the format
# "<tool> (<role> agent by <MODEL>)" where <tool> is detected from env vars
# ("Claude" when $ANTHROPIC_MODEL is set, "Codex" when $CODEX_MODEL is set —
# or "Claude" as the default for callers that pass a model explicitly). Used
# by claim/claim-spec/record-review/append-log so any session's `agent` and
# `reviewed_by` columns + every append-log entry carry the same shape across
# both Claude Code and Codex CLI sessions.
#
# Args: <role> [explicit] [model]
#   $role     — the agent role (implementer / reviewer / spec_author / leader).
#   $explicit — pre-formatted string that wins as-is (e.g. Codex's
#               "leader -> implementer (GPT-5)" chain format).
#   $model    — explicit model override for this call (3rd arg); otherwise
#               resolved from env vars below.
#
# Resolution priority (model + tool prefix detected together):
#   1. $explicit returns as-is, ignoring everything else.
#   2. $model (3rd arg)  → prefix "Claude" (default; override via the explicit
#      agent chain if you need "Codex" with an explicit model).
#   3. $HARNESS_AGENT_MODEL env var → prefix "Claude" (caller set a model but
#      not a prefix; Claude Code is the default tool in this harness).
#   4. $ANTHROPIC_MODEL  → prefix "Claude" (set by Claude Code per-session;
#      the Agent tool's `model` param overrides it in subagents, so a reviewer
#      running Opus shows Opus here even if the orchestrator is MiniMax-M3).
#   5. $CODEX_MODEL      → prefix "Codex" (set by Codex CLI in some versions;
#      not all Codex versions export this — pass --agent-model explicitly or
#      rely on the Codex chain-string convention if it doesn't).
#   6. Fall back to $HARNESS_AGENT (legacy env var) or "unknown" — no prefix.
harness_agent_attribution() {
  local role="$1"
  local explicit="${2:-}"
  local prefix="Claude"
  local model="${3:-}"
  if [ -z "$model" ] && [ -n "${HARNESS_AGENT_MODEL:-}" ]; then
    model="$HARNESS_AGENT_MODEL"
  fi
  if [ -z "$model" ] && [ -n "${ANTHROPIC_MODEL:-}" ]; then
    model="$ANTHROPIC_MODEL"
    prefix="Claude"
  fi
  if [ -z "$model" ] && [ -n "${CODEX_MODEL:-}" ]; then
    model="$CODEX_MODEL"
    prefix="Codex"
  fi

  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"
  elif [ -n "$model" ]; then
    printf '%s (%s agent by %s)' "$prefix" "$role" "$model"
  else
    printf '%s' "${HARNESS_AGENT:-unknown}"
  fi
}

warn() { printf '[WARN]  %s\n' "$1" >&2; }
ok()   { printf '[OK]    %s\n' "$1"; }
fail() { printf '[FAIL]  %s\n' "$1" >&2; }
