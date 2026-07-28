# AGENTS.md — Navigation Map for AI Agents

> This file is the **entry point** for any agent working in this repository. It is NOT a rulebook: it is a **map**. Read
> only what you need, when you need it (progressive disclosure). It is copied as-is into any project that installs
> this harness via `install.sh`.

---

## 1. Before You Start (Required)

1. Run `./init.sh` and verify that it finishes without errors. If it fails, **stop** and resolve the environment before
   touching any code.
2. Run `scripts/harness.sh status` to see the current features and whether a session is already open.
3. If `.harness.json` has `notion_database_id` set, check Notion for new tasks (see `CLAUDE.md`'s "Notion Task
   Intake") — best-effort, and it only ever adds `pending` features, never claims one.
4. Choose **one** `pending` feature. Do not work on more than one at a time.

## 2. Repository Map

| File / Folder            | What it contains                                                          | When to read it                       |
| ------------------------- | --------------------------------------------------------------------------- | ---------------------------------------- |
| `harness.db`              | SQLite — the source of truth for features and session state (gitignored) | Never read/write it directly; go through `scripts/harness.sh` |
| `state/`                  | Generated, git-tracked markdown snapshot of `harness.db` (read-only)     | For human review / `git diff`; never hand-edit |
| `.harness.json`           | Runtime config: db path, verify command, mirror env var names, Notion database id | If you need to know the verify command or project slug |
| `.mcp.json`                | Project-scoped MCP server declarations (e.g. the hosted Notion connector) | If setting up or troubleshooting Notion task intake   |
| `scripts/harness.sh`      | The single entry point for reading/writing harness state                 | Every time you claim, log, or log-out |
| `docs/architecture.md`    | What "doing a good job" means in this project                            | Before implementing                   |
| `docs/conventions.md`     | Style rules, naming conventions, structure                               | Before writing code                   |
| `docs/verification.md`    | How to verify that your work is working                                  | Before declaring a task as `done`     |
| `CHECKPOINTS.md`          | Objective criteria for "correct end state"                               | For self-assessment                   |
| `.claude/agents/`         | Definitions of sub-agents (leader, implementer, reviewer)                | If you orchestrate work               |
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
   history.md" step; the closed session *is* the history entry.
3. Do not leave temporary files, debug `print()` commands, or TODOs without context.

## 6. If you get stuck

- Reread the relevant section of `docs/`.
- If the tool is not doing what you expect, **do not create a workaround**: run
  `scripts/harness.sh append-log "<what's blocking you>"` and `set-next-step`, then close the session without
  logging out (leave the feature `in_progress` so the next session picks up the same open session).
