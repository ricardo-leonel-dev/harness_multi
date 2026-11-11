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

- Every session `lean/run.sh` opens (`lean/sandbox.sh` builds Claude Code's `--settings`; for a
  `codex` role, `lean/adapters/codex.sh` turns the same lists into a Codex permission profile,
  see "Codex sessions").
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
  temp folder (`/private/tmp/claude-<uid>`: other sessions' scratchpads) are denied too. The
  session settings re-open that folder's entry named after the project (as written and resolved):
  Claude Code writes each Bash command's stdout and stderr to a file there, and seatbelt checks an
  `fstat` on that inherited descriptor against the file's path, so with the entry denied `cat`
  fails (`stdout: Operation not permitted`) and node aborts. When the entry is missing (the first
  session from the project after a reboot cleared `/tmp`) `lean/sandbox.sh` creates it (mode
  700, as Claude Code does), and `lean/adapters/claude.sh` refuses to start a session whose
  settings deny the folder without re-opening an entry. The entry is shared by every Claude Code
  session started from the project (the leader's scratchpad included), not by other projects.
- **Secret files in the project.** Sessions (not the gate: suites load `.env`) can't read files or
  folders named `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*secret*` or
  `*credential*` (any case) in the project or the rest of its repository, except the templates
  `.env.example`, `.env.sample`, `.env.template` (`lean/lib.sh` `LEAN_SECRET_*`, the list
  `run.sh brief` also leaves out of its search). Those present when the session starts are denied
  by path (`denyRead`, a link also by its target, and a `Read(...)` deny rule, which also keeps
  them out of Grep and Glob); `.env`, `.env.local`, `.env.*.local`, `*.key`, `*.p12` and `*.pfx`
  are denied by glob anywhere in the project too, for files that appear later. Claude Code's macOS
  sandbox takes globs in `denyRead` (turned into a seatbelt regex; checked in the bundled profile
  builder of Claude Code 2.1.318, not in a live session) and also refuses to rename or hard-link
  a denied path or rename the folders above it (a new file with a glob name may be created, and
  stays unreadable); the Codex profile gets the same list as
  `deny` entries (verified with `codex sandbox`, codex-cli 0.166.0: reads, writes, renames and
  hard links refused) and its self-check fails closed if the first secret file found is readable.
- **Secrets in the environment.** Sessions and the gate's commands start without variables whose
  names look like secrets (tokens, passwords, keys, `*_URL`/`*_URI`/`*_DSN` connection strings,
  `SSH_AUTH_SOCK`, git config and npm auth passed through the environment; proxy URLs lose their
  credentials), read from the environment itself (`env -0`, else perl; neither: nothing runs).
  `lean.env_passthrough` keeps a name. `GIT_CONFIG_GLOBAL=/dev/null`.
- **Unix sockets.** Only in the project, the local database sockets (`.s.PGSQL.<port>`,
  `mysql.sock`, `redis*.sock`, `memcached*.sock` in `/private/tmp`) and the gate run's own `TMPDIR`:
  no Docker API, no ssh-agent.
- **TCP ports.** The gate's profile denies the harness Postgres mirror's host ports (54329 Postgres,
  3001 PostgREST: `LEAN_DENY_PORTS`) and `lean.deny_ports` on every address, after the localhost
  allow and also with `lean.allowed_domains`: a suite can't read the cross-project mirror.
- **Writes.** Only in the project and the temp dir (the gate's commands: the project, `/private/tmp`,
  `/dev` and a fresh `TMPDIR` of their own). A session's `TMPDIR` is a fresh folder in the user temp
  dir (a SessionStart hook; Claude Code's own temp folder is denied), removed after a headless session. Inside the project, the harness-owned paths are
  write-denied by name (`lean/`, `scripts/`, `.harness.json`, the database and its journals,
  `init.sh`, `harness/`, `.claude/`, `.codex/`, `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md`,
  `.mcp.json`) and their hashes are pinned per feature: a changed one stops the next `run.sh` step
  and `log-out --lean`. The git state (`.git`, the git dir, the common dir) is write-denied: sessions
  never commit, and the gate and `log-out --lean` refuse a moved `HEAD`.
- **Instructions for the next session.** Nested `CLAUDE.md` / `CLAUDE.local.md` and `.claude/`
  folders are write-denied (Edit globs; a regex in the profile), and the gate fails on any of them,
  git-ignored ones included, that git doesn't track unchanged at the base. It also fails on paths
  with a newline and on folders it can't list. Files present before the feature's first run are
  trusted as they were (`<lean state>/lean/<name>/nested.sha`, written with the first pin);
  re-pinning by hand after a session (`claim` afresh, `lean_pin --again`, or deleting `trusted.sha`
  of a feature pinned before `nested.sha` existed) trusts what the session left, so only re-pin
  when you know why. The same holds for a new feature after one whose gate never passed: what
  that one's sessions left is there at the new feature's first pin.
- **The state the gate trusts** (risk mode's frozen manifest, the pinned hashes) lives in
  `~/.cache/harness/projects/<folder>-<hash of the resolved path>`, outside the project and keyed
  by something a session can't edit.
- **Processes outside the sandbox** (gate profile only): mach services are denied but for an
  allowlist (`LEAN_MACH_ALLOW` in `sandbox.sh`, plus `lean.allowed_mach`), which never includes
  LaunchServices (`open`), Apple Events (`osascript`), the pasteboard or cfprefsd's agent (other
  apps' preferences): denying those services by name alone was not enough, `open` still launched an
  app outside the sandbox. One prefix is allowed besides: Chromium's rendezvous service
  (`org.chromium.Chromium.MachPortRendezvousServer.<pid>`), which headless Chromium's children
  need to reach their parent. Also no `/bin/launchctl`,
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
- **Localhost**: sessions reach every local service (databases, dev servers, the harness mirror
  included). Claude Code's sandbox can't deny a single localhost port, and macOS refuses a nested
  `sandbox-exec`; the mirror's credentials stay out of the session (environment stripped,
  `docker-compose.yml` unreadable). The gate denies `LEAN_DENY_PORTS` and `lean.deny_ports`.
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
- **Secret files: what is left.** A file with a secret name that appears mid-session and isn't
  in the glob list (`.env.production`, `*.pem`, `*secret*`, `*credential*`) is readable: a glob
  can't leave the templates out (Claude Code's Read rules and Codex take no exception to a
  deny), and `*.pem`, `*secret*` and `*credential*` would also deny dependencies' CA bundles and
  credential-provider modules. Folders not searched at session start (`LEAN_SECRET_SKIP_DIRS`:
  `node_modules`, `.venv`, `venv`, `vendor`, `target`, …) hold no denied path but the globs. A
  secret under any other name (`config/prod.yml`, `appsettings.json`), a tracked secret file's
  content in the git objects (`git show HEAD:.env`) and secrets a session's own test prints are
  not covered. A source file or folder named like a secret (`src/secretStore.ts`) is unreadable to
  sessions too; there is no setting to open one (rename it, or don't run that feature in lean
  mode). Codex sessions can't create files with the glob names (a test writing `server.key` into
  the project fails there, not in the gate); Claude sessions likely can, but can't read them back.
- `~/.cargo/config.toml` stays readable (cargo needs it): keep registry tokens in
  `~/.cargo/credentials.toml`, which is denied.

## Codex sessions

`lean/adapters/codex.sh` (checked against codex-cli 0.166.0 and 0.167.1 on macOS; 0.166 probes in the
toolkit's `progress/design_lean_flow.md` §10; 0.167.1 reproduced locally with `codex debug
prompt-input`, no model call) runs Codex with a permission profile, `--enable
network_proxy` and pinned approval settings, and never with `--dangerously-bypass-*`,
`--approve-for-me` or a `danger-full-access` mode:

- **Reads**: base `:read-only` (everything readable) minus `deny` on sandbox.sh's `denyRead` list:
  the same `$HOME` entries, credentials, the lean state with the frozen manifest, Claude Code's
  temp folder, the project's secret files and globs. `~/.codex` (Codex's auth) is a `$HOME` entry, so commands can't read it; Codex
  itself, outside the sandbox, still does. The adapter starts Codex by the binary's resolved path
  (Codex re-runs itself inside the profile, and Codex resolves the profile's paths, so a link
  such as `~/.local/bin/codex -> ~/.codex/packages/standalone/current/...` can't be opened) and
  makes only that binary's release folder `read` when it lies under `<Codex home>/packages/`
  (`auth.json`, `config.toml`, sessions, logs and the rest of `~/.codex` stay denied; a binary
  outside `$HOME` needs nothing).
- **Writes**: only the project and a fresh session `TMPDIR` (not `/tmp`, not the user temp dir:
  stricter than the Claude sessions). sandbox.sh's `denyWrite` list (harness-owned files, the git
  state) is `read`. `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `AGENTS.override.md`, `.claude/`
  and `.codex/` anywhere in the project are `deny` globs: Codex accepts only `deny` on a glob, so
  commands can't read them either.
- **Instructions**: the session's only instructions are the lean system prompt
  (`developer_instructions`). Codex loads no project `AGENTS.md` / `AGENTS.override.md`
  (`project_doc_max_bytes = 0`, `project_doc_fallback_filenames = []`): a lean session must not
  get the harness's orchestrator instructions, and codex-cli 0.167 reads the project docs through
  its sandboxed helper, so with the deny globs above the session failed to start ("failed to load
  AGENTS.md instructions for environment `local`: Operation not permitted"). The user's global
  `<Codex home>/AGENTS.md` is still loaded (Codex reads it outside the profile; 0.167 has no
  switch for it, and the adapter can't swap `CODEX_HOME` without losing the user's login).
- **Network**: Codex's own proxy (the experimental `network_proxy` feature): allowed hosts are
  `lean.allowed_domains`, direct outbound connections are blocked, localhost is open
  (`allow_local_binding`). Unix sockets: the project and sandbox.sh's local database sockets.
- **Approvals**: `never` in both modes, interactive included: a command the sandbox blocks fails
  back to the model, and there is no escalation a user could approve to run a command outside the
  profile (the Claude sessions' `allowUnsandboxedCommands: false`). `approvals_reviewer = "user"`
  is pinned so a user config can't hand approvals to a model reviewer; headless also passes
  `--ignore-rules` (no execpolicy rule runs a command outside the sandbox).
- **Environment**: the same secret-looking variables dropped (`lean_env_args`), Codex's own
  `OPENAI_*` / `CODEX_*` kept for Codex, and `OPENAI_*` and `CODEX_API_KEY` removed again from the
  commands' environment (`shell_environment_policy.exclude`, verified through `codex sandbox`); `TMPDIR`, `GIT_CONFIG_GLOBAL=/dev/null`,
  `GIT_OPTIONAL_LOCKS=0`, empty `RUSTC_WRAPPER` / `SSH_AUTH_SOCK` set through
  `shell_environment_policy.set`. Every proxy variable of the caller (any name ending in
  `proxy`, any case: `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`, lowercase, `npm_config_*`)
  and Codex's own `CODEX_SANDBOX*` / `CODEX_NETWORK_*` markers are unset for the check and the
  session, so the only proxy the commands see is Codex's (Codex's own API traffic doesn't use the
  caller's proxy either).
- **Fails closed**: before each session `codex sandbox` runs a check with the same flags (seatbelt
  active, a canary in the lean state unreadable and unwritable, the session `TMPDIR` writable,
  the codex binary runnable by that resolved path (`--version` with a temp `CODEX_HOME`), the
  Codex home unreadable when it is under `$HOME` (a `CODEX_HOME` outside `$HOME` is not denied
  and not checked: keep it in `~/.codex` or under `$HOME`),
  Codex's proxy in place: `CODEX_NETWORK_PROXY_ACTIVE=1` and `HTTP(S)_PROXY` on `127.0.0.1`, which
  only Codex can supply since the caller's are unset); a failure, a nested sandbox, or a flag or key the installed Codex doesn't know
  refuses the session (exit 3). Then `codex debug prompt-input` builds the session's prompt with
  the same flags from the project, locally (no model; a temp `CODEX_HOME`, no API key, proxies to
  a closed port): it must succeed and carry no `AGENTS.md instructions`, or the session is
  refused (exit 3). A Codex update that can't open a session with the profile fails there, not
  after the model call starts.

Gaps compared with the Claude sessions:

- **Without the `network_proxy` feature the profile's network is fully open.** The adapter enables
  it and the check refuses a session without the proxy, but the feature is experimental: a Codex
  update that renames it fails the check (closed), one that changes its behaviour is not detected.
- **Private addresses**: `allow_local_binding` opens the machine's LAN addresses too (verified with
  its own `192.168.x` address), not only loopback.
- **Not observed in a live session**: the profile was verified through `codex sandbox` (the same
  config stack, no model). That `codex` / `codex exec` apply it identically to the model's commands
  and to its built-in file edits (`apply_patch`), and the `codex exec --json` event format the usage
  is parsed from, were not observed (a model call). The parser is tolerant: a missing usage gives
  zeros and `is_error`.
- **User and project config** (`~/.codex/config.toml`, a trusted project's `.codex/config.toml`)
  still load: MCP servers, hooks and model providers they define run outside the profile, as in
  the user's own Codex sessions. The project's `.codex/` is write-denied and hash-pinned.
- **Globs are case-sensitive** as far as known: a nested `claude.md` in another case is not denied
  (the gate still fails on it).
- **macOS only**: the check expects `CODEX_SANDBOX=seatbelt`; elsewhere the adapter refuses.
- No `LEAN_DENY_PORTS`: as for the Claude sessions, localhost ports can't be denied one by one.

## Hardening further

The archived work exists only in the toolkit's own working copy (git-excluded, not shipped, absent
from installed copies):
`progress/lean_worktree_fixes/archive/rounds3-10.patch` (the full diff of rounds 3–10, including
default-deny mach lookups, `/dev` and IOKit denies, write-denied ancestors of denied paths, a
pid-hopping survivor scan, a pinned link snapshot and nested-repository checks) and
`progress/lean_worktree_fixes/archive/probes/` (the probes the reviews used). Run them only in a
throwaway VM: several touch real system state.
