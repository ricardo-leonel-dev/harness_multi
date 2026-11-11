# lean/ — the lean flow

A cheap, gated way to build one feature: the planner (Claude, in the user's session) writes a one-page
document; sandboxed sessions on another model (MiniMax by default) implement and review it; a script,
not an agent, decides whether it may close. It sits next to the harness: a feature that does not ask
for it never touches this folder.

Design and evidence: `progress/design_lean_flow.md`, `progress/explore_benchmark_neutral.md`.

## Modes

| Mode | Use it for | What the planner writes | Review |
| --- | --- | --- | --- |
| normal | most features | `docs/features/<name>.md` | `lean.reviewer` (or its `normal` key) when set, else the implementer's model; fresh session, one pass, may fix once |
| risk | concurrency, money, permissions, migrations | the document **and** frozen acceptance tests in `acceptance/<name>.test.*` | `lean.reviewer` (or its `risk` key), else `claude:claude-haiku-5-5`; another model than the implementer, report only, `VERDICT:` line |

Measured (Opus plans, MiniMax implements): normal mode cost the least of every method tried (about 2
window points per task) with the best probe scores; risk mode was the only method robust under
concurrency in both runs, at 5–6 window points per task. Neither catches what the planner does not
think of.

## Steps (by hand, from the project directory)

0. **Create** the feature with its mode: `scripts/harness.sh add-feature --name <name> … --mode
   normal|risk [--approval]` (or `set-mode` on a pending one). `--approval` makes a normal feature
   wait for the user's approval too; risk always does.
1. **Plan**: the planner starts with `lean/run.sh brief <name> <keyword...>` (read-only, one call: the
   feature, the planning rules, the risk questions, an earlier plan, the docs' headings, the project's
   files and the keyword matches) and follows `lean/instructions/planning.md`. When approval applies, the leader
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
   no nested `CLAUDE.md` / `CLAUDE.local.md` or nested `.claude/` file (git-ignored ones included)
   unless git tracks it unchanged at the base or it was already there, unchanged, when the feature
   was first pinned (`<lean state>/lean/<name>/nested.sha`: e.g. an npm package that ships a
   `.claude/` folder); risk mode: the frozen tests unchanged and passing.

7. **Chain** (instead of 2–6, when the steps should run unattended): `lean/run.sh chain <name>
   [--base <rev>] [--step-minutes N]` runs them headless in one call, each as its own `run.sh
   <step> --headless` (so each keeps its checks): normal: implement → review → gate; risk: freeze →
   implement → review → gate (verdict `changes` goes straight to fix). A failed gate, or a risk
   verdict `changes`, gets one fix and a last gate. It stops at the first failure (a step exiting
   non-zero or past its cap, a result JSON missing or with `is_error`, a risk review without a
   `VERDICT:` line or that changed files) and refuses to start when the plan awaits approval or a
   risk feature has no frozen manifest. Output: one line per step (duration, turns, cost), the
   final gate's headings (the full report and every step's log stay under `<lean state>/lean/`),
   `git status --short`, then `CHAIN: PASS` or `CHAIN: FAIL at <step> (<reason>)`; exit 0 only on
   PASS. On PASS with the harness, a `next:` line before it holds the `log-out --lean` command to
   run: `--changes` lists the files the gate checked (quoted), only `--closure` is left to fill
   in. Each step is capped at `--step-minutes` (default `lean.step_minutes`, else 30): its
   process group is killed and the step fails. With the harness, each step's result is
   `append-log`ged. It never logs out.

Every step refuses a name without `docs/features/<name>.md` before pinning anything.
Steps 3–5 open an interactive session (`--headless` for `claude -p` / `codex exec`). Close with
`scripts/harness.sh log-out --lean --changes … --verification … --closure …`: it runs the gate
itself against the commit the session started from (risk mode: with the manifest frozen at
approval, and it needs the review file with its `VERDICT:` line); that gate's suite run stands in
for `./init.sh`, so none is needed first. A feature with a mode closes only this way; `set-mode <name> none` before any review puts it back on the reviewer path.

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
  link stays unreadable and is named on stderr). Those targets and git directories also get a
  `Read` allow rule, so Claude Code's Read tool follows the links without asking. Credentials never open.
  Secret files in the project and the rest of its repository (`.env`, `.env.*`, `*.pem`, `*.key`,
  `*.p12`, `*.pfx`, `*secret*`, `*credential*`, any case; not `.env.example` / `.sample` /
  `.template`; `node_modules`, `.venv`, `vendor` and the like not searched: `lean/lib.sh`
  `LEAN_SECRET_*`) are unreadable to sessions: by path when the session starts, plus `.env`,
  `.env.local`, `.env.*.local`, `*.key`, `*.p12`, `*.pfx` by glob for later ones, for commands
  and for the Read/Grep tools (Codex: `deny`). Sessions can't rename them either (Codex sessions can't create them). The
  gate, `./init.sh` and `harness.sh test` still read them (suites load `.env`); so does a test a
  session runs, which then sees no `.env`.
- **Writes.** Only in the project and the temp dir; the harness-owned files, the git state and
  `CLAUDE.md` / `.claude/` anywhere are write-denied, and the harness-owned files' hashes are pinned
  per feature (a changed one stops the next step: delete `<lean state>/lean/<name>/trusted.sha` to
  accept a change you made yourself). Claude Code's own temp folder is denied, so each session gets
  a fresh `TMPDIR` in the user temp dir (a SessionStart hook; removed after a headless session).
- **Network.** Localhost and `lean.allowed_domains`; unix sockets only in the project and the local
  database sockets. The gate's profile denies the harness Postgres mirror's TCP ports (54329,
  3001: `LEAN_DENY_PORTS`) and `lean.deny_ports` on every address; sessions still reach them.
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
| `implementer` | `claude-mini` | tool for implement and fix, and for the normal review when `reviewer` is not set |
| `reviewer` | `claude:claude-haiku-5-5` (risk only) | tool for the review (any tool: `claude[:<model>]`, `claude-mini`, `codex[:<model>]`). Risk mode: report only, must differ from the implementer. Normal mode: used only when set (no default; unset, the implementer reviews), same review as the implementer's (one pass, may fix once), may equal the implementer. A string serves both modes; an object picks one per mode, each key optional (a missing or empty key takes that mode's fallback): `"reviewer": {"normal": "codex:gpt-5.1", "risk": "claude:claude-haiku-5-5"}`. Any other value (number, boolean, array, an object with other keys or non-string values) stops every step with exit 2 |
| `risk_questions` | `backend` | list in `lean/risk-questions/`; a project's own `docs/risk-questions.md` wins |
| `acceptance_dir` | `acceptance` | where risk-mode acceptance tests live (outside `src/` and `tests/`, so the planner may write them) |
| `allowed_domains` | `[]` | hosts the sandboxed sessions may reach besides localhost |
| `allowed_read` | `[]` | paths (`~` expanded, `..` normalised, links resolved) the sessions and the gate may read in `$HOME` besides the toolchain list; an entry reaching credentials or the lean state is refused whole |
| `deny_ports` | `[]` | TCP ports (integers 1-65535) the gate's profile denies on every address besides `LEAN_DENY_PORTS` in `sandbox.sh` (the mirror's 54329 and 3001); an invalid entry fails the profile build |
| `allowed_mach` | `[]` | mach service names the gate's commands may look up besides `LEAN_MACH_ALLOW` in `sandbox.sh` (`LEAN_MACH_NEVER` is refused: LaunchServices, Apple Events, the pasteboard, securityd, `cfprefsd.agent`, …); Chromium's own rendezvous service (`org.chromium.Chromium.MachPortRendezvousServer.<pid>`) is always allowed |
| `step_minutes` | `30` | `run.sh chain`'s cap per step, in minutes (`--step-minutes` wins) |
| `env_passthrough` | `[]` | secret-looking environment variables (`DATABASE_URL`, `NPM_TOKEN`, …) the sessions and the gate's commands keep |

Frontends tested with Karma (or another headless-browser runner): Google Chrome can't start in the
gate (it needs the window server and LaunchServices), so point the runner at Puppeteer's
`chrome-headless-shell` (`CHROME_BIN`), launched with `--no-sandbox --use-mock-keychain
--password-store=basic`, and add its folder (e.g. `~/.cache/chrome-headless-shell`) to
`lean.allowed_read`. Sessions get this automatically: when `CHROME_BIN` (else the last copy found
in `~/.cache/chrome-headless-shell`) is a `chrome-headless-shell`, the session's `CHROME_BIN`
points at a wrapper that adds `--single-process`, since Claude Code's sandbox won't let it
register its rendezvous service (the gate runs the browser unwrapped).

Tools: `claude[:<model>]`, `claude-mini` (the user's fish function, which holds the MiniMax
credentials), `codex[:<model>]` (Codex CLI, `lean/adapters/codex.sh`: interactive `codex`, headless
`codex exec --json`, whose events become the same result JSON with tokens, duration and
`is_error`; Codex reports no cost). The Codex sessions run in a Codex permission profile built from
the same lists as the Claude sandbox (reads denied, writes only in the project and a fresh
`TMPDIR`, network through Codex's proxy: localhost and `lean.allowed_domains`); the adapter first
confirms it with `codex sandbox` and refuses to start when it can't (macOS only). Differences from
the Claude sandbox: [`SECURITY.md`](SECURITY.md) "Codex sessions". `lean/adapters/codex.sh <project>
check - <file> -` runs only that check.
