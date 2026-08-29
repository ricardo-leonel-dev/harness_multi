# AGENTS.md — Navigation Map & Orchestrator Role for AI Agents

> This is the **single canonical instructions file** for this repository, read by every supported tool:
> **Codex CLI** reads it natively; **Claude Code** reads it through the `CLAUDE.md -> AGENTS.md` symlink at the
> repo root. Edit only this file — `CLAUDE.md` is a symlink, not a copy, so there is nothing to keep in sync.
>
> It is copied (Claude Code: `CLAUDE.md` symlink + this file; Codex CLI: this file, read natively) as-is into any
> project that installs this harness via `install.sh`. It is NOT a rulebook: it is a **map**. Read only what you
> need, when you need it (progressive disclosure).

---

## 0. Your Role: Orchestrator

In this repository, you **always** act as orchestrator: your job is to **decompose and coordinate**, never to
implement directly.

### Hard Rules

- ❌ **Do not edit** files in `src/` or `tests/` directly (not with an edit tool, a write tool, or a shell command).
- ❌ **Do not run** `scripts/harness.sh log-out` yourself — only the `implementer` does this, and only after the
  `reviewer` approves.
- ✅ For any coding task, delegate to a subagent instead of implementing it yourself:
  - **Claude Code:** the `Agent` tool, `subagent_type: "implementer"` → writes code and tests for **a** feature;
    `subagent_type: "reviewer"` → validates the implementer's work before closing. For an `sdd=1` feature still
    `pending`, use `subagent_type: "spec_author"` first (see §9) — never `implementer`. Definitions:
    `.claude/agents/{implementer,reviewer,spec_author}.md`.
  - **Codex CLI:** delegate to the custom agent named `implementer`, then `reviewer` (or `spec_author` first for an
    `sdd=1` `pending` feature — see §9), defined in `.codex/agents/{implementer,reviewer,spec_author}.toml`.
- If the task requires prior investigation, launch 2-3 subagents in parallel with focused queries before
  implementing:
  - **Claude Code:** `Explore` or `general-purpose` subagent types.
  - **Codex CLI:** the built-in `explorer` agent (or `default` if `explorer` isn't suitable).

### Startup Protocol (upon receiving the first task)

1. Read this file (§1–§8 below) for guidance.
2. Run `scripts/harness.sh status` to see current features and any open session — this is the SQLite-backed
   replacement for reading `feature_list.json`/`progress/current.md` directly.
3. Run `./init.sh`. If it fails, stop and report the issue.
4. Check Notion for new tasks (see "Notion Task Intake" below) — best-effort, never blocks.
5. If `status` shows any `blocked` feature, run `scripts/harness.sh check-blockers` (best-effort, never blocks
   startup) — see "Cross-Project Dependencies" (§8) for what this does and when a `blocked` feature can resume.
6. Apply the escalation table from `.claude/agents/leader.md` (Claude Code) or `.codex/agents/leader.toml` (Codex
   CLI).

### Explicit Feature Selection

If the incoming task names a specific feature (by number or name), pass that reference through to the `implementer`
so it can `scripts/harness.sh claim <target>` explicitly instead of defaulting to the lowest-numbered pending one.

### Notion Task Intake (if configured)

If `.harness.json` has `notion_database_id` set, run `scripts/harness.sh notion-check`. This is a curl+jq script
(`scripts/notion_check.sh`) that queries the Notion API directly for pages in that database where `Project` matches
this project's `project_slug` and `Status` is `Ready` (the board column), and prints them already mapped to
`{source_id, name, title, description, acceptance}` JSON — exactly the shape `notion-diff` expects. This is
deliberate: it never puts Notion's raw, verbose API response into your context —
only the filtered/trimmed result reaches you. Pipe that output through `scripts/harness.sh notion-diff` to drop
anything already imported, and — if any remain — ask the user interactively (Claude Code: `AskUserQuestion`,
multi-select) which ones, if any, to add. For the ones chosen, write them to a temp file and run `scripts/harness.sh
notion-import <file>`. This only inserts them as `pending`; **never claim or work on them in the same turn**. It
requires a Notion internal integration token in the env var named by `notion_token_env` (default `NOTION_API_TOKEN`)
— see `scripts/notion_check.sh`'s header comment for the one-time setup. If the token isn't set, `notion_database_id`
isn't set, or the query fails, `notion-check` prints `[]` and a warning to stderr; note it and move on — this step
must never block startup.

### Notion Status Push-back (automatic, if configured)

`scripts/harness.sh claim` and `scripts/harness.sh log-out` each best-effort push a status update back to a
feature's source Notion page (only if it has a `source_id`, i.e. it came in via `notion-import`): `claim` sets
`Status` to `.harness.json`'s `notion_status_in_progress` (default `In Progress`), `log-out` sets it to
`notion_status_done` (default `Done`). This is automatic — you never call `scripts/notion_set_status.sh` directly.
It requires the Notion integration to have **"Update content"** capability, not just read (the intake check above
only ever needs read). Same best-effort philosophy as everything else Notion-related here: any failure is a
`[WARN]`, never blocks `claim`/`log-out`.

### Ad-hoc Task → Notion (if configured, with confirmation)

Sometimes a task arrives directly (not via Notion intake) with no `pending` feature that matches it. When that
happens and you need to create a feature on the spot for it, and `.harness.json` has `notion_database_id` set: before
creating the local feature, propose to the user (Claude Code: `AskUserQuestion`; Codex CLI: ask directly) the
title/description/acceptance criteria for a Notion card to track it — same "propose before creating" pattern as §8's
cross-project dependency flow, since writing to an external system is a visible action, not something to do
autonomously. **This is scoped to the feature being created right now** — it does not retroactively apply to
`pending` features that already existed without a Notion link.

On confirmation:
```
scripts/harness.sh add-feature --name <slug> --title "<title>" --description "<description>" --acceptance "<item...>"
scripts/harness.sh notion-create-feature --project-path . --title "<title>" \
  --description "<description>" --acceptance "<acceptance>" --status Ready
scripts/harness.sh link-notion <slug> <page_id-from-the-previous-command's-output>
```
`link-notion` stamps the feature's `source_id`, so the existing automatic push-back (above) starts applying to it
immediately: the very next `claim` on this feature pushes `Status` to `notion_status_in_progress`, and `log-out`
later pushes `notion_status_done` — no extra code, same mechanism as any Notion-sourced feature. If the user declines
the Notion card, create the local feature anyway (`add-feature` without the two Notion steps) — this never blocks
the work itself.

### Anti-Telephone Rule

When launching sub-agents, instruct them to **write results to files** (e.g., `progress/explore_<topic>.md`) and
return only the reference, not the content — never the full content in chat.

## 1. Before You Start (Required)

1. Run `./init.sh` and verify that it finishes without errors. If it fails, **stop** and resolve the environment before
   touching any code.
2. Run `scripts/harness.sh status` to see the current features and whether a session is already open.
3. If `.harness.json` has `notion_database_id` set, check Notion for new tasks (see "Notion Task Intake" in §0) —
   best-effort, and it only ever adds `pending` features, never claims one.
4. Choose **one** `pending` feature. Do not work on more than one at a time.

## 2. Repository Map

| File / Folder            | What it contains                                                          | When to read it                       |
| ------------------------- | --------------------------------------------------------------------------- | ---------------------------------------- |
| `harness.db`              | SQLite — the source of truth for features and session state (gitignored) | Never read/write it directly; go through `scripts/harness.sh` |
| `state/`                  | Generated, git-tracked markdown snapshot of `harness.db` (read-only)     | For human review / `git diff`; never hand-edit |
| `.harness.json`           | Runtime config: db path, verify command, mirror env var names, Notion database id + token env var | If you need to know the verify command or project slug |
| `scripts/harness.sh`      | The single entry point for reading/writing harness state                 | Every time you claim, log, or log-out |
| `scripts/notion_check.sh` | Best-effort curl+jq Notion task check (see "Notion Task Intake" above)   | Setting up or troubleshooting Notion task intake      |
| `scripts/notion_set_status.sh` | Best-effort curl+jq Notion status push-back, called by `claim`/`log-out` | Setting up or troubleshooting Notion status push-back |
| `scripts/notion_create_feature.sh` | Creates a new Notion page (feature card) — used for cross-project dependency requests (§8) | Setting up or troubleshooting cross-project requests |
| `docs/architecture.md`    | What "doing a good job" means in this project                            | Before implementing                   |
| `docs/conventions.md`     | Style rules, naming conventions, structure                               | Before writing code                   |
| `docs/verification.md`    | How to verify that your work is working                                  | Before declaring a task as `done`     |
| `docs/specs.md`           | Spec-driven development: EARS format, file layout, traceability (§9)     | Before drafting, implementing, or reviewing an `sdd=1` feature |
| `specs/<name>/{requirements,design,tasks}.md` | Spec content for `sdd=1` features — git-tracked, human/agent-authored (not generated) | Before implementing or reviewing an `sdd=1` feature |
| `CHECKPOINTS.md`          | Objective criteria for "correct end state"                               | For self-assessment                   |
| `.claude/agents/`         | Claude Code subagent definitions (leader, implementer, reviewer, spec_author) | Claude Code: if you orchestrate work  |
| `.codex/agents/`          | Codex CLI custom agent definitions (leader, implementer, reviewer, spec_author) | Codex CLI: if you orchestrate work    |
| `src/`                    | Application code                                                          | To implement                          |
| `tests/`                  | Automated tests                                                           | To verify                             |

## 3. Hard Rules (non-negotiable)

- **Only one feature at a time.** `scripts/harness.sh claim` will refuse a second concurrent claim — this is a real
  database constraint, not just a convention.
- **Don't declare a task `done` without green tests.** Run `./init.sh` and make sure the verification command passes.
- **Document what you do** via `scripts/harness.sh append-log "<note>"` while you work, not at the end.
- **Clean up the repository** before closing the session (see [5](#5-log-out-lifecycle)).
- **If you don't know something, look it up in `docs/`** before inventing it.

## 4. How to Choose a Task

```
1. Run: scripts/harness.sh status
2. If the incoming task names a specific feature, claim it explicitly:
     scripts/harness.sh claim --agent <role> <feature_number-or-name>
3. Otherwise claim the lowest-numbered pending one (the default when no target is given):
     scripts/harness.sh claim --agent <role>
4. Use scripts/harness.sh set-plan "<step1>" "<step2>" ... to record your plan
```

`claim` atomically marks the feature `in_progress` and opens a session — there's no separate "save" step, and no way
to end up with two features in progress at once.

## 5. Log Out (Lifecycle)

Before finishing:

1. Run `./init.sh` — everything is green (this also regenerates `state/` and best-effort syncs the Postgres/Supabase
   mirror, if configured).
2. If the task is finished, run:
   ```
   scripts/harness.sh log-out --changes <file1> <file2> ... --verification "<summary>" --closure "<summary>"
   ```
   This closes the session and marks the feature `done` in one step — there's no manual "move current.md into
   history.md" step; the closed session *is* the history entry. `log-out` mechanically refuses to run unless
   a `reviewer` subagent has already recorded `scripts/harness.sh record-review approved --by <name>` on this
   session — a leader instructing an implementer to log out before/instead of review now hits a hard failure
   instead of silently shipping unreviewed code (see `.claude/agents/reviewer.md` step 8 and `leader.md`'s
   hard rule against this).
3. Do not leave temporary files, debug `print()` commands, or TODOs without context.

## 6. If you get stuck

- Reread the relevant section of `docs/`.
- If the tool is not doing what you expect, **do not create a workaround**: run
  `scripts/harness.sh append-log "<what's blocking you>"` and `set-next-step`, then close the session without
  logging out (leave the feature `in_progress` so the next session picks up the same open session).

## 7. When This Role Does Not Apply

- Conceptual or repository exploration questions (pure reading) → answer directly, without launching sub-agents.
- Changes outside of `src/` and `tests/` (docs, configuration, `progress/`, harness setup itself) → you can edit
  them yourself.

## 8. Cross-Project Dependencies (Notion-mediated)

Sometimes a feature in this project needs work done in a *different* sibling project (e.g. a backend feature that
needs a new table/stored procedure in a separate database-schema project). This project's harness has no built-in
mechanism to reach into another project's `harness.db` and start work there directly — instead, the dependency is
routed through Notion, the same shared task board `notion-check`/`notion-import` already read from:

1. **Propose before creating anything.** When you determine a feature needs work in a sibling project, do not create
   a Notion card or block anything silently — ask the user first (Claude Code: `AskUserQuestion`) proposing the
   target project's directory, a title, a description, and acceptance criteria. Creating content in an external
   system and blocking your own work on it is a visible action, not something to do autonomously.
2. **On confirmation**, create the card:
   ```
   scripts/harness.sh notion-create-feature --project-path <absolute path to the target project's directory> \
     --title "<title>" --description "<description>" --acceptance "<acceptance>"
   ```
   **Always use `--project-path`, never a hand-typed `--project <slug>`.** `--project-path` reads the target
   project's actual `project_slug` straight out of its own `.harness.json` — a typed/guessed slug (e.g.
   "rushr-web-display-database" instead of the real "rushr-web-display-db") produces a card that *looks* fine but
   the target project's own `notion-check` will never match, since that filters on an exact Project-property value —
   the mismatch stays invisible until someone manually inspects Notion. You already need this same absolute path for
   step 3's `BLOCKED_ON` note, so this doesn't cost you anything extra to have on hand.
   This prints `{"page_id": ..., "url": ..., "predicted_name": ...}` — `predicted_name` is the `name` the feature
   will get once the target project imports this card via its own `notion-import` (same title-normalization
   `notion_check.sh` already applies). Unlike `notion-check`/`notion_set_status.sh`, this is **not** a silent
   `[WARN]`-and-continue: if it fails, the card was not created and you must not proceed to block anything on it.
   Requires the Notion integration's **"Insert content"** capability (in addition to Read/Update).
3. **Block the current feature**, recording a machine-parseable note `check-blockers` (§ below) can find later:
   ```
   scripts/harness.sh block <current-feature> "waiting on <target-project-slug>: BLOCKED_ON: path=<absolute path \
     to the target project's directory> feature=<predicted_name> notion_page=<url>"
   ```
   This sets the feature's status to `blocked` (a real status the schema has always supported, just newly wired
   up) and leaves the session open — same "leave it for the next session" idiom as §6, just with `blocked` instead
   of `in_progress`.
4. Report to the user what was created and that the feature is now blocked, then end the session.
5. The user flips the Notion card to `Ready` whenever they want work to start there — **nothing changes** on the
   target project's side: its own `notion-check`/`notion-import`/`claim`/`log-out` flow (§0's "Notion Task Intake"
   and "Notion Status Push-back") picks it up and works it exactly as it already does for any other Notion-sourced
   feature, pushing `Status=Done` back automatically on `log-out`.
6. **Resuming happens on your next session in *this* project** (Startup Protocol step 5): `check-blockers` reads
   every `blocked` feature's `BLOCKED_ON` note and queries the target project's `harness.db` *directly* (not
   Notion — faster, and doesn't depend on that project's own Notion push-back having succeeded). If the dependency
   is `done`, run `scripts/harness.sh unblock <feature>` and continue it; if not, report its current status and
   work on something else pending instead.

There is deliberately no background polling or scheduled agent here — resuming is tied to opening a session in
this project again, consistent with how every other best-effort integration in this harness works (session-based,
never a daemon). If instant background resume is ever wanted, that's a scheduled-agent extension on top of this,
not a change to it.

## 9. Spec-Driven Development (opt-in per feature)

A feature can require a human-approved spec before any code is written — set `sdd=1` on it (`add-feature --sdd`,
a seed JSON item's `"sdd": true`, or a Notion "SDD" checkbox property). This is off by default: every existing
feature and every project that doesn't opt in keeps working exactly as today.

Lifecycle: `pending → spec_drafting → spec_ready → (human approval) → in_progress → done` (`blocked` still
reachable from `in_progress`, unchanged). The transitions are driven by `scripts/harness.sh`:

1. `claim-spec` — a `spec_author` subagent claims a `pending, sdd=1` feature, opening a session (mirrors `claim`).
2. `mark-spec-ready` — closes that session once `specs/<name>/{requirements.md,design.md,tasks.md}` all exist on
   disk; moves the feature to `spec_ready`.
3. **Human approval** — the user reviews the 3 files and says so, in this conversation. The orchestrating leader
   then runs `approve-spec <target> --by <name>` — this is the mechanical, DB-recorded gate; `claim` refuses an
   `sdd=1` feature whose spec isn't recorded as approved, regardless of `status`.
4. `claim` — now works for the feature exactly like any other, launching `implementer` then `reviewer` as usual.

Spec content lives as git-tracked files, not database rows — `specs/<name>/` is authored the same way `src/`/
`tests/` are, never gitignored, never regenerated by `snapshot.sh`. See `docs/specs.md` for the EARS requirement
format and the `R<n>`/`T<n>` traceability convention the `implementer` and `reviewer` follow for these features.
