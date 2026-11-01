# lean/ — the lean flow

A cheap, gated way to build one feature: the planner (Claude, in the user's session) writes a one-page
document; sandboxed sessions on another model (MiniMax by default) implement and review it; a script,
not an agent, decides whether it may close. It sits next to the harness: a feature that does not ask
for it never touches this folder.

Design and evidence: `progress/design_lean_flow.md`, `progress/explore_benchmark_neutral.md`.

## Modes

| Mode | Use it for | What the planner writes | Review |
| --- | --- | --- | --- |
| normal | most features | `docs/features/<name>.md` | implementer's model, fresh session, one pass, may fix once |
| risk | concurrency, money, permissions, migrations | the document **and** frozen acceptance tests in `acceptance/<name>.test.*` | another model, report only, `VERDICT:` line |

Measured (Opus plans, MiniMax implements): normal mode cost the least of every method tried (about 2
window points per task) with the best probe scores; risk mode was the only method robust under
concurrency in both runs, at 5–6 window points per task. Neither catches what the planner does not
think of.

## Steps (by hand, from the project directory)

0. **Create** the feature with its mode: `scripts/harness.sh add-feature --name <name> … --mode
   normal|risk [--approval]` (or `set-mode` on a pending one). `--approval` makes a normal feature
   wait for the user's approval too; risk always does.
1. **Plan**: the planner follows `lean/instructions/planning.md`. When approval applies, the leader
   runs `scripts/harness.sh approve-plan <name> --by <name>` right after the user approves; `claim`
   refuses until then. In risk mode that also hashes the acceptance tests into
   `<lean state>/frozen/<name>.sha` (and the database), outside the project (see "Sandbox" > "State").
2. **Freeze check** (risk mode): `lean/run.sh freeze <name>` shows the frozen tests fail before
   implementation (without the harness, it also writes the manifest).
3. **Implement**: `lean/run.sh implement <name>`.
4. **Review**: `lean/run.sh review <name>`.
5. **Fix** (when the review asks for changes or the gate fails): `lean/run.sh fix <name>`.
6. **Gate**: `lean/run.sh gate <name>`: `HEAD` still the base commit; suite green; no assertion removed from an existing test file
   unless the document lists it under **Changed tests**; every changed file listed under **Files**;
   risk mode: the frozen tests unchanged and passing.

Steps 3–5 open an interactive session (`--headless` for `claude -p`). Close with
`scripts/harness.sh log-out --lean --changes … --verification … --closure …`: it runs the gate
itself against the commit the session started from (risk mode: with the manifest frozen at
approval, and it needs the review file with its `VERDICT:` line). A feature with a mode closes only
this way; `set-mode <name> none` before any review puts it back on the reviewer path.

## Sandbox

Threat model, details and known limits: [`SECURITY.md`](SECURITY.md). The sandbox guards against
mistakes and secret leaks by a cooperative model, not against a model trying to escape.

- **What runs sandboxed.** Every session `run.sh` opens (`lean/sandbox.sh`), and the code those
  sessions leave when the harness runs it: the gate's suite, `run.sh freeze`, `./init.sh` and
  `scripts/harness.sh test` while a lean feature is open (`sandbox-exec` on macOS; elsewhere, or with
  `LEAN_GATE_UNSANDBOXED=1`, unsandboxed with a `[WARN]`; a `sandbox-exec` that can't apply the
  profile fails the gate instead). A `claude-mini` started by hand, or a suite you start directly,
  is not.
- **Reads.** `$HOME` is denied but for the project, toolchains and package caches,
  `lean.allowed_read`, the git directories and the targets of top-level links git tracks or ignores
  (a worktree's `harness.db`, `scripts/`… pointing into the main worktree; an untracked, non-ignored
  link stays unreadable and is named on stderr). Credentials never open.
- **Writes.** Only in the project and the temp dir; the harness-owned files, the git state and
  `CLAUDE.md` / `.claude/` anywhere are write-denied, and the harness-owned files' hashes are pinned
  per feature (a changed one stops the next step: delete `<lean state>/lean/<name>/trusted.sha` to
  accept a change you made yourself).
- **Network.** Localhost and `lean.allowed_domains`; unix sockets only in the project and the local
  database sockets.
- **Environment.** Secret-looking variables are dropped (`lean.env_passthrough` keeps one);
  `RUSTC_WRAPPER`/`CARGO_BUILD_RUSTC_WRAPPER` empty (sccache can't reach its server),
  `GIT_OPTIONAL_LOCKS=0`, `GIT_CONFIG_GLOBAL=/dev/null` (a suite that commits sets its own identity).
  Sessions keep Claude Code's own `ANTHROPIC_*` / `CLAUDE_*`.
- **State.** `~/.cache/harness/projects/<folder>-<hash of the resolved path>` (`lean/lib.sh`): risk
  mode's frozen manifests, the pinned hashes and run results. Moving the project starts a new folder;
  `claim` writes the manifest and the pins again from the database. State kept under
  `~/.cache/harness/<slug>` by an older version is copied over once.
- **Paths in the plan** are relative to the project directory, even when it is a subfolder of its
  repository. A path starting with the project's folder in the repository is read from the repository
  root only when nothing is at it inside the project (rule in `lean/instructions/planning.md`). Any
  changed or untracked, non-ignored file outside the project directory fails the gate, named by its
  repository-root path.

## Configuration (`.harness.json::lean`, all optional)

| Key | Default | Meaning |
| --- | --- | --- |
| `implementer` | `claude-mini` | tool for implement, normal review and fix |
| `reviewer` | `claude:claude-haiku-5-5` | tool for the risk-mode review; must differ from the implementer |
| `risk_questions` | `backend` | list in `lean/risk-questions/`; a project's own `docs/risk-questions.md` wins |
| `acceptance_dir` | `acceptance` | where risk-mode acceptance tests live (outside `src/` and `tests/`, so the planner may write them) |
| `allowed_domains` | `[]` | hosts the sandboxed sessions may reach besides localhost |
| `allowed_read` | `[]` | paths (`~` expanded, `..` normalised, links resolved) the sessions and the gate may read in `$HOME` besides the toolchain list; an entry reaching credentials or the lean state is refused whole |
| `allowed_mach` | `[]` | mach service names the gate's commands may look up besides `LEAN_MACH_ALLOW` in `sandbox.sh` (`LEAN_MACH_NEVER` is refused: LaunchServices, Apple Events, the pasteboard, securityd, `cfprefsd.agent`, …) |
| `env_passthrough` | `[]` | secret-looking environment variables (`DATABASE_URL`, `NPM_TOKEN`, …) the sessions and the gate's commands keep |

Tools: `claude[:<model>]`, `claude-mini` (the user's fish function, which holds the MiniMax
credentials). `codex` is designed (design §10) but not built.
