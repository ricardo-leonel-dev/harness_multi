#!/usr/bin/env bash
# install.sh — bootstrap the harness toolkit into the current directory (the
# target project). Run from the project root, pointing at wherever this
# toolkit repo lives:
#
#   bash /path/to/personal_harness/install.sh --slug my-project \
#     --verify-command "npm test"
#
# Harness-core files (AGENTS.md + a CLAUDE.md symlink to it, .claude/agents/*.md,
# .codex/agents/*.toml, init.sh, scripts/*.sh) are copied/relinked unconditionally
# — re-running install.sh refreshes them. docs/*.md and CHECKPOINTS.md are
# scaffolded from templates only if they don't already exist — never clobbers
# project-owned content.

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$(pwd)"

ok() { printf '[OK]    %s\n' "$1"; }
warn() { printf '[WARN]  %s\n' "$1"; }
fail() { printf '[FAIL]  %s\n' "$1" >&2; }

PROJECT_SLUG=""
DESCRIPTION=""
VERIFY_COMMAND=""
SUPABASE_URL_ENV="SUPABASE_URL"
SUPABASE_KEY_ENV="SUPABASE_ANON_KEY"
SUPABASE_REST_PATH="/rest/v1"
FEATURES_SEED=""
NOTION_DATABASE_ID=""
NOTION_TOKEN_ENV="NOTION_API_TOKEN"
NOTION_STATUS_IN_PROGRESS="In Progress"
NOTION_STATUS_DONE="Done"

usage() {
  cat <<EOF
Usage: install.sh --slug SLUG [options]
  --slug SLUG                  project slug (required)
  --description TEXT           project description
  --verify-command CMD         shell command init.sh runs to verify the project
  --supabase-url-env VAR       env var holding the Postgres/Supabase URL (default: SUPABASE_URL)
  --supabase-key-env VAR       env var holding the Postgres/Supabase key (default: SUPABASE_ANON_KEY)
  --supabase-rest-path PATH    REST path suffix on the URL (default: /rest/v1; use "" for a bare PostgREST instance)
  --features-seed FILE         optional features.seed.json to import on install
  --notion-database-id ID      Notion database id to check for new tasks (see README's Notion Task Intake section)
  --notion-token-env VAR       env var holding the Notion internal integration token (default: NOTION_API_TOKEN)
  --notion-status-in-progress VAL  Status value to push to Notion when a feature is claimed (default: "In Progress")
  --notion-status-done VAL         Status value to push to Notion when a feature is logged out (default: "Done")
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --slug) PROJECT_SLUG="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --verify-command) VERIFY_COMMAND="$2"; shift 2 ;;
    --supabase-url-env) SUPABASE_URL_ENV="$2"; shift 2 ;;
    --supabase-key-env) SUPABASE_KEY_ENV="$2"; shift 2 ;;
    --supabase-rest-path) SUPABASE_REST_PATH="$2"; shift 2 ;;
    --features-seed) FEATURES_SEED="$2"; shift 2 ;;
    --notion-database-id) NOTION_DATABASE_ID="$2"; shift 2 ;;
    --notion-token-env) NOTION_TOKEN_ENV="$2"; shift 2 ;;
    --notion-status-in-progress) NOTION_STATUS_IN_PROGRESS="$2"; shift 2 ;;
    --notion-status-done) NOTION_STATUS_DONE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [ -z "$PROJECT_SLUG" ]; then
  fail "--slug is required"
  usage
  exit 1
fi

for tool in sqlite3 jq; do
  command -v "$tool" >/dev/null 2>&1 || { fail "$tool is required but not installed"; exit 1; }
done

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
  fi
}

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

echo "── 1. Copying harness-core files ───────────────────────"

cp "$TOOLKIT_DIR/AGENTS.md" "$TARGET_DIR/AGENTS.md"
ln -sf AGENTS.md "$TARGET_DIR/CLAUDE.md"
mkdir -p "$TARGET_DIR/.claude/agents"
cp "$TOOLKIT_DIR"/.claude/agents/*.md "$TARGET_DIR/.claude/agents/"
mkdir -p "$TARGET_DIR/.codex/agents"
cp "$TOOLKIT_DIR"/.codex/agents/*.toml "$TARGET_DIR/.codex/agents/"
cp "$TOOLKIT_DIR/init.sh" "$TARGET_DIR/init.sh"
mkdir -p "$TARGET_DIR/scripts"
cp "$TOOLKIT_DIR"/scripts/*.sh "$TARGET_DIR/scripts/"
chmod +x "$TARGET_DIR/init.sh" "$TARGET_DIR"/scripts/*.sh
ok "copied AGENTS.md (+ CLAUDE.md symlink), .claude/agents/*.md, .codex/agents/*.toml, init.sh, scripts/*.sh"

echo ""
echo "── 2. Creating harness.db ───────────────────────────────"

if [ -f "$TARGET_DIR/harness.db" ]; then
  warn "harness.db already exists — leaving it as-is (already installed?)"
else
  sqlite3 "$TARGET_DIR/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql"
  PROJECT_ID="$(gen_uuid)"
  NOW="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
  sqlite3 "$TARGET_DIR/harness.db" "INSERT INTO projects (id, slug, description, created_at, updated_at)
VALUES ('$(sql_escape "$PROJECT_ID")', '$(sql_escape "$PROJECT_SLUG")', '$(sql_escape "$DESCRIPTION")', '$NOW', '$NOW');"
  ok "created harness.db and seeded project '$PROJECT_SLUG'"
fi

echo ""
echo "── 3. Scaffolding project docs ──────────────────────────"

mkdir -p "$TARGET_DIR/docs"
for name in architecture conventions verification; do
  dest="$TARGET_DIR/docs/$name.md"
  if [ -f "$dest" ]; then
    warn "docs/$name.md already exists — leaving as-is"
  else
    cp "$TOOLKIT_DIR/templates/docs/$name.md.tmpl" "$dest"
    ok "scaffolded docs/$name.md (fill in the TODOs)"
  fi
done

if [ -f "$TARGET_DIR/CHECKPOINTS.md" ]; then
  warn "CHECKPOINTS.md already exists — leaving as-is"
else
  sed "s|{{VERIFY_COMMAND}}|${VERIFY_COMMAND:-<set verify_command in .harness.json>}|g" \
    "$TOOLKIT_DIR/templates/CHECKPOINTS.md.tmpl" > "$TARGET_DIR/CHECKPOINTS.md"
  ok "scaffolded CHECKPOINTS.md"
fi

echo ""
echo "── 4. Writing .harness.json ─────────────────────────────"

jq -n \
  --arg version "0.1.0" \
  --arg slug "$PROJECT_SLUG" \
  --arg verify "$VERIFY_COMMAND" \
  --arg url_env "$SUPABASE_URL_ENV" \
  --arg key_env "$SUPABASE_KEY_ENV" \
  --arg rest_path "$SUPABASE_REST_PATH" \
  --arg notion_db "$NOTION_DATABASE_ID" \
  --arg notion_token_env "$NOTION_TOKEN_ENV" \
  --arg notion_status_in_progress "$NOTION_STATUS_IN_PROGRESS" \
  --arg notion_status_done "$NOTION_STATUS_DONE" \
  '{harness_version: $version, db_path: "harness.db", snapshot_path: "state",
    project_slug: $slug, verify_command: $verify,
    supabase_url_env: $url_env, supabase_key_env: $key_env, supabase_rest_path: $rest_path,
    notion_database_id: $notion_db, notion_token_env: $notion_token_env,
    notion_status_in_progress: $notion_status_in_progress, notion_status_done: $notion_status_done}' \
  > "$TARGET_DIR/.harness.json"
ok "wrote .harness.json"

touch "$TARGET_DIR/.gitignore"
grep -qxF 'harness.db' "$TARGET_DIR/.gitignore" || echo 'harness.db' >> "$TARGET_DIR/.gitignore"
ok "harness.db added to .gitignore"

echo ""
echo "── 5. Importing features (if provided) ──────────────────"

cd "$TARGET_DIR" || exit 1
if [ -n "$FEATURES_SEED" ]; then
  bash scripts/harness.sh import-features "$FEATURES_SEED"
else
  warn "no --features-seed given — skipping (see templates/features.seed.json.tmpl to add features later via 'harness.sh import-features')"
fi

echo ""
echo "── 6. Generating initial snapshot + mirror sync ─────────"

bash scripts/harness.sh snapshot
bash scripts/harness.sh sync

echo ""
ok "install complete. Fill in docs/*.md and CHECKPOINTS.md, then run ./init.sh."
