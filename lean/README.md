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
   `~/.cache/harness/<slug>/frozen/<name>.sha` (and the database), outside the project.
2. **Freeze check** (risk mode): `lean/run.sh freeze <name>` shows the frozen tests fail before
   implementation (without the harness, it also writes the manifest).
3. **Implement**: `lean/run.sh implement <name>`.
4. **Review**: `lean/run.sh review <name>`.
5. **Fix** (when the review asks for changes or the gate fails): `lean/run.sh fix <name>`.
6. **Gate**: `lean/run.sh gate <name>`: suite green; no assertion removed from an existing test file
   unless the document lists it under **Changed tests**; every changed file listed under **Files**;
   risk mode: the frozen tests unchanged and passing.

Steps 3–5 open an interactive session (`--headless` for `claude -p`). Close with
`scripts/harness.sh log-out --lean --changes … --verification … --closure …`: it runs the gate
itself against the commit the session started from (risk mode: with the manifest frozen at
approval, and it needs the review file with its `VERDICT:` line). A feature with a mode closes only
this way; `set-mode <name> none` before any review puts it back on the reviewer path.

## Sandbox

Every session `run.sh` opens is sandboxed (`lean/sandbox.sh`): Bash writes only in the project and the
temp dir, no network except localhost and `lean.allowed_domains`, no reads of private folders, other
projects or the frozen manifests. A plain `claude-mini` started by hand is **not** sandboxed; the gate
still catches a changed frozen test, because the manifest lives outside the project.

- **Symlinks and git worktrees.** The resolved target of each symlink at the project's top level (a
  worktree's `harness.db`, `scripts/`, `migrations/`… pointing into the main worktree) and the project's
  git directories (`.git` file or dir, `git rev-parse --git-dir`, `--git-common-dir`) are readable, so
  a worktree or a project in a repository's subfolder can read its links and run `git status`/`git diff`.
  Read only: writes stay in the project and the temp dir, and a link into a private folder, the frozen
  manifests (`~/.cache/harness`) or another project's transcripts stays denied (`sandbox.sh` names it on
  stderr). Only links git knows are read through: committed at `HEAD` and unchanged, or ignored or
  excluded (`link-worktree` excludes its links). An untracked, non-ignored link, which a session could
  have planted for the next one, stays unreadable and is named on stderr.
- **Session environment.** `RUSTC_WRAPPER` and `CARGO_BUILD_RUSTC_WRAPPER` are empty, so cargo runs
  `rustc` directly: `sccache` can't reach its server from the sandbox ("Operation not permitted"), and
  builds are slower without its cache. `GIT_OPTIONAL_LOCKS=0`, so `git status`/`git diff` don't write
  the index (in a worktree it lives outside the project). Sessions never commit.
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

Tools: `claude[:<model>]`, `claude-mini` (the user's fish function, which holds the MiniMax
credentials). `codex` is designed (design §10) but not built.
