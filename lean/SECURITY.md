# lean/ — what the sandbox protects, and what it doesn't

## Threat model

Lean sessions run another model (MiniMax by default) through Claude Code, and anything a session
reads goes to that provider's servers. The sandbox is built for a **cooperative model that makes
mistakes**: it keeps secrets from being read (and so from leaving the machine), and it keeps a
session, or the code it writes, from damaging the harness, the git history or the rest of the
machine by accident.

It is **not** built to contain a model that deliberately tries to escape. A determined adversary
with shell access in the project has ways around several of the rules below (renaming folders
above a denied path, processes that leave the gate's process group, nested repositories whose
git config runs later, sockets in `/private/tmp`, mach registration, devices and IOKit).
Rounds 3–10 of the `fix/lean-worktrees` work went after those and were trimmed back to this
model; see "Hardening further" at the end.

## What runs sandboxed

- Every session `lean/run.sh` opens (`lean/sandbox.sh` builds Claude Code's `--settings`).
- The code those sessions leave behind, when the harness runs it: the gate's suite and acceptance
  tests (`lean/gate.sh`), `run.sh freeze`, `./init.sh` and `scripts/harness.sh test` while a lean
  feature has an open session (`lean/lib.sh` `lean_sandboxed`, a `sandbox-exec` profile built by
  `sandbox.sh --seatbelt` from the same rules).

Not sandboxed: a `claude-mini` started by hand, and a suite you start directly (`npm test`,
`cargo test`, an IDE runner) while a lean feature is open.

## What it protects, and how

- **Reads of secrets.** Every entry of `$HOME` is denied except the project, the toolchains and
  package caches (`LEAN_HOME_READ` in `sandbox.sh`), `.harness.json::lean.allowed_read`, the targets
  of top-level links git tracks or ignores, the git directories and this project's own Claude Code
  folder. Credential files (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.docker`, `~/.kube`,
  `~/.config/{gh,fish,git}`, `~/.gitconfig`, `~/.npmrc`, `~/.yarnrc*`, `~/.pypirc`,
  `~/.cargo/credentials*`, `~/.gradle/gradle.properties`, `~/.m2/settings*.xml`,
  `~/.gem/credentials`, uv's credential store, `~/Library/Keychains`, shell and REPL histories:
  fish's, `~/.zsh_history`, `~/.zsh_sessions`, `~/.bash_history`, `~/.python_history`,
  `~/.node_repl_history`, `~/.psql_history`, `~/.sqlite_history`, `~/.mysql_history`, `~/.lesshst`,
  `~/.irb_history`) never open,
  not through a link, not through `allowed_read` (an entry is normalised and resolved, and refused
  whole when either form is protected), and not inside an allowed toolchain folder: the profile denies
  them again after its allows, and the session settings keep folders holding them out of `allowRead`.
  `/Volumes`, `/Users/Shared`, the per-user cache dir, other projects' transcripts and Claude Code's
  temp folder (`/private/tmp/claude-<uid>`: other sessions' scratchpads) are denied too.
- **Secrets in the environment.** Sessions and the gate's commands start without variables whose
  names look like secrets (tokens, passwords, keys, `*_URL`/`*_URI`/`*_DSN` connection strings,
  `SSH_AUTH_SOCK`, git config and npm auth passed through the environment; proxy URLs lose their
  credentials), read from the environment itself (`env -0`, else perl; neither: nothing runs).
  `lean.env_passthrough` keeps a name. `GIT_CONFIG_GLOBAL=/dev/null`.
- **Unix sockets.** Only in the project, the local database sockets (`.s.PGSQL.<port>`,
  `mysql.sock`, `redis*.sock`, `memcached*.sock` in `/private/tmp`) and the gate run's own `TMPDIR`:
  no Docker API, no ssh-agent.
- **Writes.** Only in the project and the temp dir (the gate's commands: the project, `/private/tmp`,
  `/dev` and a fresh `TMPDIR` of their own). Inside the project, the harness-owned paths are
  write-denied by name (`lean/`, `scripts/`, `.harness.json`, the database and its journals,
  `init.sh`, `harness/`, `.claude/`, `.codex/`, `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md`,
  `.mcp.json`) and their hashes are pinned per feature: a changed one stops the next `run.sh` step
  and `log-out --lean`. The git state (`.git`, the git dir, the common dir) is write-denied: sessions
  never commit, and the gate and `log-out --lean` refuse a moved `HEAD`.
- **Instructions for the next session.** Nested `CLAUDE.md` / `CLAUDE.local.md` and `.claude/`
  folders are write-denied (Edit globs; a regex in the profile), and the gate fails on any of them,
  git-ignored ones included, that git doesn't track unchanged at the base. It also fails on paths
  with a newline and on folders it can't list.
- **The state the gate trusts** (risk mode's frozen manifest, the pinned hashes) lives in
  `~/.cache/harness/projects/<folder>-<hash of the resolved path>`, outside the project and keyed
  by something a session can't edit.
- **Processes outside the sandbox** (gate profile only): mach services are denied but for an
  allowlist (`LEAN_MACH_ALLOW` in `sandbox.sh`, plus `lean.allowed_mach`), which never includes
  LaunchServices (`open`), Apple Events (`osascript`), the pasteboard or cfprefsd's agent (other
  apps' preferences): denying those services by name alone was not enough, `open` still launched an
  app outside the sandbox. Also no `/bin/launchctl`,
  no signals to processes outside the sandbox, no write or `ioctl` on a terminal. The gate's commands
  run in a session of their own (`setsid`: no controlling terminal), with stdin from `/dev/null` and
  no inherited descriptor above 2; when they end, whatever is left in their process group is killed
  and the report carries a `[WARN]`.
- **One gate at a time** per project (`lean_run_lock`), with stale locks taken over.

## Known limits

- **Git-ignored trees are untrusted after a lean run.** `node_modules`, `.venv`, `target/` and build
  folders may hold code a session or the suite wrote or installed; the gate checks only what it
  lists above. Reinstall them before running tooling outside the sandbox.
- **The gate's suite runs session-written code**, sandboxed but with the project writable and
  localhost open.
- **Reads outside `$HOME`** stay open: system toolchains, `/opt/homebrew`, the user temp dir and
  `/private/tmp`, other apps' files there included. A project kept outside `$HOME` has its siblings
  readable.
- **Localhost** reaches every local service (databases, dev servers, the harness mirror), by design.
- **`lean.allowed_domains`**: seatbelt can't filter by host name, so the gate's outbound network is
  open while it is set (a `[WARN]` says so).
- **Processes that leave the process group** (a new session or process group: `setsid`, `setpgid`)
  are not looked for.
- **macOS only for the gate's profile**: without `sandbox-exec` (Linux) the gate's commands run
  unsandboxed, with a `[WARN]`; `LEAN_GATE_UNSANDBOXED=1` does the same on request.
- **Only verified on macOS, through `sandbox-exec`.** The session settings were checked as generated
  JSON and by applying their rules with `sandbox-exec`, not against Claude Code's own runtime (its
  handling of `allowRead` inside `denyRead`, `denyWrite` on a missing path, `allowUnixSockets`), and
  not at all on Linux (bubblewrap).
- `~/.cargo/config.toml` stays readable (cargo needs it): keep registry tokens in
  `~/.cargo/credentials.toml`, which is denied.

## Hardening further

The archived work exists only in the toolkit's own working copy (git-excluded, not shipped, absent
from installed copies):
`progress/lean_worktree_fixes/archive/rounds3-10.patch` (the full diff of rounds 3–10, including
default-deny mach lookups, `/dev` and IOKit denies, write-denied ancestors of denied paths, a
pid-hopping survivor scan, a pinned link snapshot and nested-repository checks) and
`progress/lean_worktree_fixes/archive/probes/` (the probes the reviews used). Run them only in a
throwaway VM: several touch real system state.
