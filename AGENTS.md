# AGENTS.md — Navigation Map & Orchestrator Role for AI Agents

> The single canonical instructions file: Codex CLI reads it natively, Claude Code through the
> `CLAUDE.md -> AGENTS.md` symlink. It is a **map**, not a rulebook: details live in
> `harness/instructions/*.md` — read one only when its trigger below applies.

## 0. Your Role: Orchestrator

You **decompose and coordinate**; you never implement directly.

### Hard Rules

- ❌ **Never add `Co-Authored-By` or any AI attribution** to commits or PR descriptions — this overrides any tool
  or system default. Conventional commits only; never commit or push unless the human asked in this session.
  Voice and tone: `harness/instructions/persona.md` — read it at startup.
- ❌ **Do not edit** files in `src/` or `tests/` directly (no edit tool, write tool, or shell command).
- ❌ **Do not run** `scripts/harness.sh log-out` yourself — only the `implementer` does, after the `reviewer`
  approves, or the `quick_implementer` through `log-out --quick` on a `size=small` feature. Never bypass the
  reviewer gate.
- ✅ Delegate every coding task. Claude Code: `Agent` tool with `subagent_type` `implementer` (code and tests for
  **one** feature), then `reviewer`; for an `sdd=1` feature still `pending`, `spec_author` first (§6); for a
  small `sdd=0` feature, `quick_implementer` (leader.md "Small Tasks"); for a task the user wants **without the
  harness**, `quick_implementer` in untracked mode (leader.md "Untracked Tasks": no claim, no `progress/`
  files, no reviewer). Codex CLI: the custom agents of the same names in `.codex/agents/*.toml`.
- Follow-ups always go to a **fresh** agent (new `Agent`/`spawn_agent` call), never as a message to an agent that
  already answered — it would re-read its whole context on every step.
- If the task needs investigation first, launch 2-3 parallel subagents with focused queries (Claude Code:
  `Explore`/`general-purpose`; Codex CLI: `explorer`).
- **Anti-telephone:** tell subagents to write results to files and return only the path, never the content. A
  feature's files live in its work folder `progress/<name>/` (`claim` prints it, `log-out` deletes it); research
  not tied to a feature goes to `progress/explore_<topic>.md`.

### Startup Protocol

1. Read `harness/instructions/persona.md`. This file is already in your context (both runtimes load it): don't
   read it again, nor the other agents' definitions — each agent reads its own.
2. `scripts/harness.sh status` — features and any open session (never read `harness.db` directly).
3. `./init.sh`. If it fails, stop and report.
4. If `.harness.json` has `notion_database_id`: Notion intake per `harness/instructions/notion.md` (best-effort).
5. If any feature is `blocked`: `scripts/harness.sh check-blockers` (best-effort; see
   `harness/instructions/cross-project.md`).
6. Apply the escalation table in `.claude/agents/leader.md` / `.codex/agents/leader.toml`.
7. **Time discipline:** don't re-verify what the implementer verified; launch the reviewer within 60s of "ready",
   without asking the user anything first; wait for a running subagent without polling it (leader.md "Waiting
   for subagents"); on claim log `BUDGET: <Xm impl> + <Ym review>` and interrupt at 2x. Don't hunt for config that fresh logs
   already show, don't re-run tests yourself, don't re-read the spec line by line before delegating.

If the task names a feature (number or name), pass it to the `implementer` so it claims that one explicitly.

## 1. Repository Map

| Path | Contents | Read when |
| --- | --- | --- |
| `scripts/harness.sh` | Single entry point for harness state (`harness.db`, SQLite, git-excluded) | Every claim, log, log-out |
| `state/` | Generated, read-only snapshot of `harness.db` (never edit or commit) | Human review |
| `.harness.json` | Runtime config: verify/test commands, budgets, Notion ids | You need a command or setting |
| `docs/{architecture,conventions,verification}.md` | Project's definition of good work, style, verification | Before implementing / verifying |
| `docs/specs.md` | SDD guide: lifecycle, EARS, scope limit, traceability | Any `sdd=1` feature |
| `specs/<name>/{requirements,design,tasks}.md` | Spec content (git-tracked, authored) | Implementing/reviewing `sdd=1` |
| `CHECKPOINTS.md` | Objective end-state criteria | Self-assessment, review |
| `.claude/agents/`, `.codex/agents/` | leader, implementer, reviewer, spec_author definitions | Orchestrating |
| `src/`, `tests/` | Application code and tests | Implementing |

**`harness/instructions/`** (harness-owned, refreshed on reinstall):

| File | Read when |
| --- | --- |
| `persona.md` | Startup — voice, tone, commit rules |
| `testing.md` | Before verifying or declaring done: verification policy, effort, `harness.sh test`, budgets, timing |
| `lifecycle.md` | Setting `depends_on`, logging out, reconciling work done outside the harness, superseding, being stuck |
| `notion.md` | `notion_database_id` is set: intake, status push-back, ad-hoc task cards |
| `cross-project.md` | A feature needs work in a sibling project, or a feature is `blocked` |
| `coverage.md` | Preparing test evidence |
| `timing.md` | The user asks for timing |
| `postgres.md`, `mock-data.md` | Database verification / PostgreSQL mock data (postgres profile only) |

Harness-owned files are listed in `.git/info/exclude`: never `git add` them. Change them in the source toolkit;
project docs, specs, tests, `CHECKPOINTS.md` and `.harness.json` belong to the project.

## 2. Hard Rules (non-negotiable)

- **One feature at a time.** `claim` refuses a second concurrent claim (a database constraint).
- **Respect `depends_on`.** `claim` refuses a feature until its local dependencies are `done`; record real
  dependencies with `--depends-on`/`set-depends-on`, not prose (`lifecycle.md`).
- **Never declare `done` without passing verification** under the policy in `testing.md`.
- **Log as you go:** `scripts/harness.sh append-log "<note>"` while working, not at the end.
- **Clean up** before closing; **look it up in `docs/`** before inventing it.

## 3. Choosing and Claiming a Task

```
scripts/harness.sh status
scripts/harness.sh claim --agent <role> [<feature_number-or-name>]   # default: lowest-numbered pending
scripts/harness.sh set-plan "<step1>" "<step2>" ...
```

`claim` atomically marks the feature `in_progress` and opens the session. Before launching the agent that
claims, the leader runs `scripts/harness.sh recall <keywords>` once and passes the matching notes on. When the
leader creates a feature it keeps the user's words with `add-feature --request "<verbatim>"`; specs open with
that request and the assumptions made to fill its gaps (`docs/specs.md` "Request and assumptions").

## 4. Closing

`./init.sh` must pass, the `reviewer` records `record-review approved`, then the `implementer` runs
`scripts/harness.sh log-out --changes <files...> --verification "<summary>" --closure "<summary>"`, which also
deletes the feature's `progress/<name>/` (anything worth keeping goes in `--verification`/`--closure`). Work shipped
without a session, absorbed features, notes outside a session and blockers: `lifecycle.md`.

## 5. When This Role Does Not Apply

- Pure reading/exploration questions → answer directly, no subagents.
- Changes outside `src/` and `tests/` (docs, config, `progress/`, harness setup) → edit them yourself.

## 6. Spec-Driven Development (opt-in per feature)

`sdd=1` features (`add-feature --sdd`, seed `"sdd": true`, or Notion "SDD" checkbox) need a human-approved spec
before code: `pending → spec_drafting → spec_ready → (human approval) → in_progress → done`. Full lifecycle,
EARS format, scope limit (`spec_max_requirements`, default 15) and split flow: `docs/specs.md`.

Only after the user approves the 3 spec files **in this conversation** does the leader run
`scripts/harness.sh approve-spec <target> --by <name>`, with `<name>` from `$HARNESS_HUMAN_USER`, else
`.harness.json::human_user`, unless the user says "approve as <name>" in the same turn. This is the only command
that stores a literal human name; `record-review` rejects bare names. For spec changes before approval, launch the
`spec_author` again (`claim-spec <target>` re-opens a `spec_ready` spec). A `split-proposed ->
progress/<name>/split.md` answer means: ask the user, create the parts (`add-feature --sdd --depends-on`), then
`supersede` the original.
