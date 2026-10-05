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
# — re-running install.sh refreshes them. docs/{architecture,conventions,verification}.md,
# CHECKPOINTS.md, .claude/settings.json, specs/, and .harness.json are created
# only if absent — never clobbers project-owned content. Shared instructions and
# docs/specs.md are refreshed; --profile postgres explicitly adds shared SQL tools
# on each install. Harness-owned files and the state/ snapshot are listed in the
# repository's .git/info/exclude so they never reach the project's history.

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
NOTION_STATUS_SPEC_READY="Spec Ready"
HUMAN_USER=""
PROFILE="generic"

usage() {
  cat <<EOF
Usage: install.sh --slug SLUG [options]
  --profile NAME               generic (default) or postgres; explicit on each installation
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
  --notion-status-spec-ready VAL   Status value to push to Notion when an sdd=1 feature's spec is marked ready
                                    (default: "Spec Ready"; see docs/specs.md)
  --human-user NAME            name of the human who approves specs in this project (e.g. "Ricardo Aguilar").
                                Written to .harness.json::human_user; approve-spec uses it as the default for
                                --by when the leader doesn't pass an explicit name. On first install, install.sh
                                prompts interactively if --human-user is not passed. Skipping the prompt is
                                only possible in CI by passing --human-user "...".
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
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
    --notion-status-spec-ready) NOTION_STATUS_SPEC_READY="$2"; shift 2 ;;
    --human-user) HUMAN_USER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1"; usage; exit 1 ;;
  esac
done

case "$PROFILE" in
  generic|postgres) ;;
  *) fail "unknown profile: $PROFILE"; exit 1 ;;
esac

if [ -z "$PROJECT_SLUG" ]; then
  fail "--slug is required"
  usage
  exit 1
fi

for tool in sqlite3 jq; do
  command -v "$tool" >/dev/null 2>&1 || { fail "$tool is required but not installed"; exit 1; }
done

# --human-user is mandatory for first installs; reinstall preserves configuration.
# If not passed via flag on first install, prompt interactively —
# the install does NOT proceed with an empty name. The leader agent prompt
# reads this from .harness.json when running approve-spec --by, so an empty
# value would silently fall through to the legacy "user" default and pollute
# the audit trail. Refusing to install without it is the only way to keep
# approve-spec attribution accurate across teams. CI callers must pass
# --human-user "<name>" explicitly OR pipe the name into stdin (e.g.
# `echo "Name" | bash install.sh --slug ...`).
if [ -f "$TARGET_DIR/.harness.json" ]; then
  # Runtime configuration belongs to the project; reinstall does not replace it.
  HUMAN_USER="$(jq -r '.human_user // empty' "$TARGET_DIR/.harness.json")"
elif [ -z "$HUMAN_USER" ]; then
  printf 'human user (the person who will approve specs in this project, e.g. "Ricardo Aguilar"): '
  read -r HUMAN_USER
fi
# Trim leading/trailing whitespace (pure POSIX, no subshell)
HUMAN_USER="${HUMAN_USER#"${HUMAN_USER%%[![:space:]]*}"}"
HUMAN_USER="${HUMAN_USER%"${HUMAN_USER##*[![:space:]]}"}"
if [ ! -f "$TARGET_DIR/.harness.json" ] && [ -z "$HUMAN_USER" ]; then
  fail "--human-user cannot be empty (pass --human-user \"<name>\" or pipe a name into stdin)"
  exit 1
fi
ok "human user: $HUMAN_USER"

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

# Shared instructions are harness-owned and refreshed even in existing projects.
mkdir -p "$TARGET_DIR/harness/instructions"
cp "$TOOLKIT_DIR/shared/coverage.md" "$TARGET_DIR/harness/instructions/coverage.md"
if [ "$PROFILE" = postgres ]; then
  mkdir -p "$TARGET_DIR/scripts/templates"
  cp "$TOOLKIT_DIR/profiles/postgres/build_traceability.sh" "$TARGET_DIR/scripts/build_traceability.sh"
  chmod +x "$TARGET_DIR/scripts/build_traceability.sh"
  cp "$TOOLKIT_DIR/profiles/postgres/acceptance_test_prologue.sql" "$TARGET_DIR/scripts/templates/acceptance_test_prologue.sql"
  cp "$TOOLKIT_DIR/profiles/postgres/verification.md" "$TARGET_DIR/harness/instructions/postgres.md"
  ok "refreshed postgres profile tools and shared instructions"
fi

mkdir -p "$TARGET_DIR/.claude"
if [ -f "$TARGET_DIR/.claude/settings.json" ]; then
  warn ".claude/settings.json already exists — leaving as-is (may have project-specific hooks)"
else
  cp "$TOOLKIT_DIR/templates/settings.json.tmpl" "$TARGET_DIR/.claude/settings.json"
  ok "scaffolded .claude/settings.json (Claude Code hooks: verify_command after edits, init.sh on session stop — Codex CLI has no equivalent hook mechanism, see docs/specs.md)"
fi

# specs/ holds git-tracked spec content for sdd=1 features (see docs/specs.md) —
# deliberately NOT added to .gitignore below, unlike harness.db.
if [ -d "$TARGET_DIR/specs" ]; then
  :
else
  mkdir -p "$TARGET_DIR/specs"
  cat > "$TARGET_DIR/specs/README.md" <<'EOF'
Spec content for features with `sdd=1` lives here, one directory per feature
(`specs/<name>/{requirements,design,tasks}.md`), git-tracked like `src/`/`tests/`.
See `docs/specs.md` for the format and lifecycle.
EOF
  ok "scaffolded specs/ (empty until an sdd=1 feature drafts one)"
fi

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
# docs/specs.md has no project-specific content, so it is harness-owned like
# harness/instructions/: refreshed on every install and excluded from git below.
cp "$TOOLKIT_DIR/templates/docs/specs.md.tmpl" "$TARGET_DIR/docs/specs.md"
ok "refreshed docs/specs.md (harness-owned — same across every project)"

if [ -f "$TARGET_DIR/CHECKPOINTS.md" ]; then
  warn "CHECKPOINTS.md already exists — leaving as-is"
else
  sed "s|{{VERIFY_COMMAND}}|${VERIFY_COMMAND:-<set verify_command in .harness.json>}|g" \
    "$TOOLKIT_DIR/templates/CHECKPOINTS.md.tmpl" > "$TARGET_DIR/CHECKPOINTS.md"
  ok "scaffolded CHECKPOINTS.md"
fi

echo ""
echo "── 4. Writing .harness.json ─────────────────────────────"

if [ -f "$TARGET_DIR/.harness.json" ]; then
  warn ".harness.json already exists — leaving project runtime configuration as-is (flags do not override it)"
else
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
  --arg notion_status_spec_ready "$NOTION_STATUS_SPEC_READY" \
  --arg human_user "$HUMAN_USER" \
  '{harness_version: $version, db_path: "harness.db", snapshot_path: "state",
    project_slug: $slug, verify_command: $verify,
    supabase_url_env: $url_env, supabase_key_env: $key_env, supabase_rest_path: $rest_path,
    notion_database_id: $notion_db, notion_token_env: $notion_token_env,
    notion_status_in_progress: $notion_status_in_progress, notion_status_done: $notion_status_done,
    notion_status_spec_ready: $notion_status_spec_ready,
    human_user: $human_user}' \
  > "$TARGET_DIR/.harness.json"
ok "wrote .harness.json"
fi

touch "$TARGET_DIR/.gitignore"
grep -qxF 'harness.db' "$TARGET_DIR/.gitignore" || echo 'harness.db' >> "$TARGET_DIR/.gitignore"
ok "harness.db added to .gitignore"

# Everything install.sh owns (copied, refreshed or generated) stays out of git:
# the rules go to .git/info/exclude — local, never committed — so a project's
# history only holds what the project itself authored. Each install writes its
# own block keyed by the project's path inside the repository, so several
# installs can share one repository (one harness per service in a monorepo) and
# a reinstall replaces its block instead of appending duplicates.
exclude_harness_files() {
  if ! git -C "$TARGET_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    warn "not inside a git repository — skipping .git/info/exclude"
    return 0
  fi
  local prefix exclude_rel exclude_file snapshot begin end name entries tracked
  prefix="$(git -C "$TARGET_DIR" rev-parse --show-prefix)"
  exclude_rel="$(cd "$TARGET_DIR" && git rev-parse --git-path info/exclude)"
  case "$exclude_rel" in /*) exclude_file="$exclude_rel" ;; *) exclude_file="$TARGET_DIR/$exclude_rel" ;; esac
  snapshot="$(jq -r '.snapshot_path // "state"' "$TARGET_DIR/.harness.json")"
  snapshot="${snapshot%/}"

  entries="AGENTS.md CLAUDE.md init.sh harness.db harness/ docs/specs.md $snapshot/"
  for name in "$TOOLKIT_DIR"/.claude/agents/*.md; do entries="$entries .claude/agents/${name##*/}"; done
  for name in "$TOOLKIT_DIR"/.codex/agents/*.toml; do entries="$entries .codex/agents/${name##*/}"; done
  for name in "$TOOLKIT_DIR"/scripts/*.sh; do entries="$entries scripts/${name##*/}"; done
  entries="$entries scripts/build_traceability.sh scripts/templates/acceptance_test_prologue.sql"

  begin="# >>> harness-managed: /$prefix (written by install.sh — re-run it instead of editing)"
  end="# <<< harness-managed: /$prefix"
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"
  {
    awk -v begin="$begin" -v end="$end" \
      '$0 == begin { skip = 1; next } $0 == end { skip = 0; next } !skip' "$exclude_file"
    printf '%s\n' "$begin"
    for name in $entries; do
      printf '/%s%s\n' "$prefix" "$name" | sed 's/[][*?\\]/\\&/g'
    done
    printf '%s\n' "$end"
  } > "$exclude_file.tmp"
  mv "$exclude_file.tmp" "$exclude_file"
  ok "harness-owned files excluded from git ($exclude_rel)"

  # Exclude rules only hide untracked files; anything committed earlier stays tracked.
  # shellcheck disable=SC2086
  tracked="$(cd "$TARGET_DIR" && git ls-files -- $entries)"
  if [ -n "$tracked" ]; then
    warn "harness-owned files still tracked by git — untrack them with 'git rm -r --cached' (they stay on disk):"
    printf '%s\n' "$tracked" | sed 's/^/          /'
  fi
}
exclude_harness_files

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
