# Harness Engineering Toolkit

A portable, multi-tool agent harness: a `leader` → `implementer` → `reviewer`
workflow, backed by a local SQLite database (the source of truth for feature
tracking and session history) with an optional, best-effort Postgres/Supabase
mirror for cross-project queries and dashboards.

It's project-agnostic — install it into any project, any language, any stack.

## Works with Claude Code and Codex CLI

`AGENTS.md` is the single canonical instructions file. `CLAUDE.md` is a real
symlink to it (`CLAUDE.md -> AGENTS.md`) — Claude Code auto-loads `CLAUDE.md`
and gets the same content; Codex CLI reads `AGENTS.md` natively. There is
nothing to keep in sync by hand: edit `AGENTS.md` and both tools pick it up.

The `leader` → `implementer` → `reviewer` subagent workflow is defined once
per agent in `.agents/*.md` (the canonical source — YAML frontmatter carries
fields for both targets, e.g. `tools:` for Claude Code and `sandbox_mode:` for
Codex CLI) and generated into each tool's native format by `./gen_agents.sh`:
`.claude/agents/*.md` (Claude Code's `Agent` tool) and `.codex/agents/*.toml`
(Codex CLI's own custom-agent-definition mechanism) — those two are generated
files, not hand-edited; re-run `gen_agents.sh` after changing anything in
`.agents/`. Same idea for MCP server config: `.mcp.json` (Claude Code) and
`.codex/config.toml` (Codex CLI) both declare the same Notion connector (these
two are small enough to stay hand-maintained). `install.sh` scaffolds both
trees into target projects.

Known caveat: on a Windows checkout without symlink support enabled, git may
check `CLAUDE.md` out as a plain text file containing the literal string
`AGENTS.md` instead of a real symlink. If that happens, replace it with
`@AGENTS.md` on the first line of a real `CLAUDE.md` file instead (Claude
Code's documented import syntax) as a fallback.

## What's in here

- `AGENTS.md` (+ `CLAUDE.md` symlink) — the shared orchestrator/navigation instructions.
- `.agents/*.md` — canonical source for the `leader`/`implementer`/`reviewer` subagents; `./gen_agents.sh`
  generates `.claude/agents/*.md` and `.codex/agents/*.toml` from it (don't hand-edit those two).
- `init.sh` — environment/verification check, run at the start of every session.
- `install.sh` — bootstraps this toolkit into a target project.
- `db/schema.sqlite.sql` — the local primary schema (applied to each installed project's `harness.db`).
- `db/schema.postgres.sql` + `db/rpc/*.sql` — the optional Postgres/Supabase mirror schema and RPC functions.
- `templates/` — scaffolds for a new project's `docs/*.md`, `CHECKPOINTS.md`, and `features.seed.json`.
- `scripts/harness.sh` — the single entry point agents use to read/write harness state (claim, log, log-out, snapshot, sync, notion-diff, notion-import).
- `examples/notes-cli/` — a fully worked reference installation (see below).

## Installing into a project

```bash
cd /path/to/your-project
bash /path/to/this-toolkit/install.sh \
  --slug your-project \
  --verify-command "npm test"   # whatever proves your project works
```

This creates `harness.db`, scaffolds `docs/*.md` and `CHECKPOINTS.md` (fill in
their TODOs), writes `.harness.json`, and copies the agent workflow files in.
Re-running `install.sh` refreshes the harness-core files but never overwrites
your project's own `docs/*.md` or `CHECKPOINTS.md`.

Optionally pass `--features-seed features.seed.json` (see
`templates/features.seed.json.tmpl`) to bulk-load an initial feature list.

## The Postgres/Supabase mirror (optional)

Nothing about the harness depends on this — `harness.db` is the real source
of truth, and every sync failure is a `[WARN]`, never a `[FAIL]`.

### Option A — local Postgres + PostgREST via `docker-compose.yml` (fastest)

This repo ships a minimal compose file: just Postgres and PostgREST, with
`db/schema.postgres.sql` and `db/rpc/*.sql` applied automatically on first
start.

```bash
docker compose up -d              # starts postgres (54329) + postgrest (3001)
source <(bash scripts/dev_jwt.sh) # exports SUPABASE_URL / SUPABASE_ANON_KEY
```

Bare PostgREST has no `/rest/v1` prefix (that's Supabase's own gateway, not
PostgREST itself), so any project pointed at this stack needs
`"supabase_rest_path": ""` in its `.harness.json` — `install.sh --supabase-rest-path ""`
sets this at install time. `examples/notes-cli/` already ships configured
this way, so from a fresh clone:

```bash
docker compose up -d
source <(bash scripts/dev_jwt.sh)
cd examples/notes-cli && bash scripts/harness.sh sync   # mirrors it immediately
```

`docker compose down -v` tears it down and wipes the data volume (schema
gets re-applied fresh next `up`); `docker compose down` alone keeps the data.

### Option B — hosted Supabase, or `supabase start`

Apply `db/schema.postgres.sql` and `db/rpc/*.sql` via the Supabase SQL editor
or CLI, then set `SUPABASE_URL`/`SUPABASE_ANON_KEY` (or `SUPABASE_SERVICE_ROLE_KEY`
for write access) to the project's real values. Both hosted Supabase and
`supabase start`'s bundled Kong gateway already serve PostgREST under
`/rest/v1`, so leave `supabase_rest_path` at its default (`/rest/v1`) —
no `--supabase-rest-path ""` override needed here.

`init.sh` and `scripts/harness.sh sync` pick up either option automatically
once the env vars are set.

## Notion task intake (optional)

If your task tickets (Jira, etc.) tend to lack the detail you actually need,
you can keep an enriched copy in a Notion database and have the harness
notice new ones every time you open Claude Code — it only ever *proposes*
adding them as `pending` features; it never claims or works one itself.

This uses Notion's official hosted MCP server (OAuth login, no integration
token to create or store), since the check only ever needs to run inside an
interactive Claude Code session.

**One-time setup:**

1. Create a Notion database (e.g. "Backlog") with these properties:
   - `Title` (title)
   - `Project` (select) — value must match the installed project's `project_slug`
   - `Description` (rich text)
   - `Acceptance Criteria` (rich text — one criterion per line)
   - `Ready` (checkbox) — leave unchecked while still drafting a ticket's detail
2. Install (or re-run) with the database id:
   ```bash
   bash install.sh --slug your-project --notion-database-id <database-id-from-its-url> ...
   ```
   This writes `notion_database_id` into `.harness.json` and declares the
   connector in a project-scoped `.mcp.json` (Claude Code):
   ```json
   { "mcpServers": { "notion": { "type": "http", "url": "https://mcp.notion.com/mcp" } } }
   ```
   and in `.codex/config.toml` (Codex CLI):
   ```toml
   [mcp_servers.notion]
   url = "https://mcp.notion.com/mcp"
   auth = "oauth"
   ```
   (`install.sh` merges these in without clobbering any other MCP servers
   already declared in the project.)
3. Open Claude Code and run `/mcp`, or start a Codex CLI session, to complete
   the one-time OAuth login, granting access to the specific database when
   prompted.

One Notion database can back multiple projects — just filter by `Project`.
From then on, at the start of every session the `leader` checks that
database for `Ready`-checked pages tagged with this project's slug that
aren't imported yet (tracked via `features.source_id`, so it's idempotent),
and asks you which ones, if any, to add via `scripts/harness.sh notion-import`.
See `AGENTS.md`'s "Notion Task Intake" section for the exact flow.

## Try it yourself

`examples/notes-cli/` is a complete worked example — a minimal Python notes
CLI with its full feature history already seeded. To see the harness in
action:

```bash
cd examples/notes-cli
bash ../../install.sh --slug notes-cli \
  --verify-command "python3 -m unittest discover -s tests -v" \
  --features-seed features.seed.json
bash scripts/harness.sh import-sessions sessions.seed.json   # loads the historical session log
./init.sh
bash scripts/harness.sh status
```

Then open Claude Code in `examples/notes-cli/` and give it a task — it will
pick up the one remaining `pending` feature (`cli_recent`) and work through
the `leader` → `implementer` → `reviewer` loop end to end.
