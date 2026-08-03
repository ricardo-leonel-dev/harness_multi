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
`.agents/`. `install.sh` scaffolds both trees into target projects.

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
- `scripts/harness.sh` — the single entry point agents use to read/write harness state (claim, log, log-out, snapshot, sync, notion-check, notion-diff, notion-import).
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
notice new ones every time you open a session — it only ever *proposes*
adding them as `pending` features; it never claims or works one itself.

This queries the Notion API directly via `scripts/notion_check.sh`
(curl+jq, plain REST — not the Notion MCP connector). That's deliberate: a
plain script filters the response server- and client-side and only ever
returns the trimmed `{source_id, name, title, description, acceptance}`
array, so Notion's raw, verbose JSON never has to enter the model's context.
It requires a static **internal integration token**, not OAuth.

**One-time setup:**

1. Create a Notion database (e.g. "Backlog") as a **board** with these
   properties:
   - `Name` (title, Notion's native title property — don't rename it)
   - `Project` (select) — value must match the installed project's `project_slug`
   - `Description` (rich text)
   - `Acceptance Criteria` (rich text — one criterion per line)
   - `Status` (the board's status/select property) — a card counts as ready
     for intake once it's in the `Ready` column
2. Create a Notion **internal integration** at `notion.so/my-integrations`.
   Read content capability is enough for task intake; also enable **Update
   content** if you want the status push-back described below. Then share
   the database with it (`···` menu on the database → `Connections` →
   your integration).
3. Export its token in your shell profile (never commit it to a tracked
   file — it's a real secret):
   ```bash
   export NOTION_API_TOKEN=secret_...
   ```
4. Install (or re-run) with the database id:
   ```bash
   bash install.sh --slug your-project --notion-database-id <database-id-from-its-url> ...
   ```
   This writes `notion_database_id` and `notion_token_env` (default
   `NOTION_API_TOKEN`; override with `--notion-token-env` if you use a
   different variable name) into `.harness.json`.

One Notion database can back multiple projects — just filter by `Project`.
From then on, at the start of every session the `leader` runs
`scripts/harness.sh notion-check` for pages tagged with this project's slug
and sitting in the `Ready` column that aren't imported yet (tracked via
`features.source_id`, so it's idempotent), and asks you which ones, if any,
to add via `scripts/harness.sh notion-import`. See `AGENTS.md`'s "Notion
Task Intake" section for the exact flow.

### Status push-back (optional, automatic once the token can write)

Once a feature has a `source_id` (imported from Notion), `scripts/harness.sh
claim` and `log-out` each best-effort push a status update to that feature's
Notion page — `claim` sets it to `notion_status_in_progress` (default `In
Progress`), `log-out` sets it to `notion_status_done` (default `Done`).
Override either with `--notion-status-in-progress`/`--notion-status-done` at
install time. This needs the integration's **Update content** capability
(step 2 above); without it, pushes just fail as a `[WARN]` and everything
else keeps working. See `scripts/notion_set_status.sh`.

If you'd rather have the model reason about Notion interactively (search,
edit pages, etc.) instead of this fixed one-shot check, you can separately
declare Notion's hosted MCP server in `.mcp.json` (Claude Code) or
`.codex/config.toml` (Codex CLI) and authorize it via OAuth — `install.sh`
doesn't do this for you, so add it by hand if and when you actually need it.

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
