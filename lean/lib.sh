#!/usr/bin/env bash
# lib.sh — helpers shared by lean/run.sh, lean/gate.sh, scripts/harness.sh and init.sh.
# Sourced, not executed; every name starts with lean_.
#
# State: the lean flow keeps each project's pinned state outside the project, in
# lean_state_dir: frozen/<name>.sha (risk mode's acceptance manifest), lean/<name>/trusted.sha
# (the hashes of the harness-owned files the flow runs or trusts), lean/<name>/nested.sha (the
# nested instruction files there before the feature's first run) and run results. The folder is keyed by the project's resolved path,
# never by .harness.json (a session could edit that and point the next step at fresh state).

LEAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The harness-owned paths the flow runs or trusts, relative to the project. Sessions can't
# write them (sandbox.sh denyWrite); lean_trusted_manifest hashes them for lean_check_trusted.
# Their own settings.local.json is left out of the hashes (Claude Code writes it when the
# user allows a command in their own session) but stays write-denied.
LEAN_TRUSTED_PATHS="lean scripts .harness.json init.sh harness .claude .codex AGENTS.md CLAUDE.md CLAUDE.local.md .mcp.json"

# lean_state_dir <project> — ~/.cache/harness/projects/<folder>-<12 hex of the sha256 of its
# resolved path>.
lean_state_dir() {
  local real
  real=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  printf '%s/.cache/harness/projects/%s-%s\n' "$HOME" "$(basename "$real")" \
    "$(printf '%s' "$real" | shasum -a 256 | cut -c1-12)"
}

# lean_adopt_legacy <project> — once, when the path-keyed folder doesn't exist yet, copies
# the frozen manifests and run state an older version kept under the slug
# (~/.cache/harness/<project_slug>), so a feature frozen before the change keeps its risk mode.
lean_adopt_legacy() {
  local state slug old d
  state=$(lean_state_dir "$1") || return 0
  [ ! -d "$state" ] || return 0
  slug=$(jq -r '.project_slug // empty' "$1/.harness.json" 2>/dev/null)
  slug="${slug:-$(basename "$(cd "$1" && pwd)")}"
  case "$slug" in ""|projects|*/*|.|..) return 0 ;; esac
  old="$HOME/.cache/harness/$slug"
  [ -d "$old/frozen" ] || [ -d "$old/lean" ] || return 0
  mkdir -p "$state" || return 0
  for d in frozen lean; do [ ! -d "$old/$d" ] || cp -R "$old/$d" "$state/$d"; done
  echo "[lean] copied the lean state kept under $old to $state" >&2
}

# lean_trusted_manifest <project> — "<sha256>  <path>" for every file under the trusted
# paths (links followed), sorted.
lean_trusted_manifest() {
  (
    cd "$1" || exit 1
    for p in $LEAN_TRUSTED_PATHS; do
      [ -e "$p" ] || continue
      find -L "$p" -type f ! -name settings.local.json ! -name .DS_Store ! -name '*.pyc' 2>/dev/null
    done | LC_ALL=C sort -u | while IFS= read -r f; do shasum -a 256 "$f"; done
  )
}

# lean_nested_line <path> — "<sha256>  <path>", the line lean_nested_manifest records for a
# file and lean/gate.sh compares against.
lean_nested_line() { shasum -a 256 -- "$1"; }

# lean_nested_manifest <project> — lean_nested_line for each nested instruction file already in
# the project, sorted: the files lean/gate.sh's scan looks for (CLAUDE.md / CLAUDE.local.md below
# the top level, any case, and files in a .claude/ folder below the top level; git-ignored ones
# included, .git not entered), regular files only (a link always fails the gate), no name with
# a newline.
lean_nested_manifest() {
  (
    cd "$1" || exit 1
    find . -name .git -prune -o \( -iname claude.md -o -iname claude.local.md -o -ipath './?*/.claude/*' \) \
      -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
      f="${f#./}"
      case "$f" in *$'\n'*|.claude/*) continue ;; */*) ;; *) continue ;; esac
      lean_nested_line "$f"
    done | LC_ALL=C sort
  )
}

# lean_pin <project> <name> [--again] — pins the hashes of the trusted files under
# <state>/lean/<name>/trusted.sha when they aren't pinned yet (--again: afresh). With them, and
# only when it isn't there yet (--again: afresh), it records the nested instruction files
# already in the project in <state>/lean/<name>/nested.sha (lean_nested_manifest): the gate
# accepts those as they are (an npm package that ships a .claude/ folder), not new or changed
# ones. Deleting trusted.sha to accept a harness-file change keeps nested.sha.
lean_pin() {
  local project="$1" name="$2" again="${3:-}" dir n
  dir="$(lean_state_dir "$project")/lean/$name" || return 1
  mkdir -p "$dir" || return 1
  [ "$again" = --again ] || [ ! -f "$dir/trusted.sha" ] || return 0
  lean_trusted_manifest "$project" > "$dir/trusted.tmp" && mv "$dir/trusted.tmp" "$dir/trusted.sha" || return 1
  echo "[lean] pinned the hashes of $(wc -l < "$dir/trusted.sha" | tr -d ' ') harness-owned file(s) in $dir/trusted.sha" >&2
  if [ "$again" = --again ] || [ ! -f "$dir/nested.sha" ]; then
    lean_nested_manifest "$project" > "$dir/nested.tmp" && mv "$dir/nested.tmp" "$dir/nested.sha" || return 1
    n=$(wc -l < "$dir/nested.sha" | tr -d ' ')
    [ "$n" = 0 ] || echo "[lean] recorded $n nested CLAUDE.md / .claude/ file(s) already in the project in $dir/nested.sha (the gate accepts them unchanged)" >&2
  fi
}

# lean_check_trusted <project> <name> — fails, naming the files, when a trusted file changed
# since lean_pin (no pin: passes).
lean_check_trusted() {
  local file now
  file="$(lean_state_dir "$1")/lean/$2/trusted.sha" || return 1
  [ -f "$file" ] || return 0
  now=$(lean_trusted_manifest "$1")
  [ "$now" = "$(cat "$file")" ] && return 0
  echo "harness-owned files changed since feature $2 was pinned ($file):" >&2
  diff <(cat "$file") <(printf '%s\n' "$now") | sed -n 's/^[<>] [0-9a-f]*  /  /p' | LC_ALL=C sort -u >&2
  echo "Sessions can't write them. If you changed them yourself (a reinstall, a config edit), delete $file to pin them again." >&2
  return 1
}

# Environment variables whose names look like secrets (case-insensitive extended regex):
# lean_env_drop lists them, and sessions and the gate's commands run without them. Besides
# the secret-looking words (generic *_KEY and *_PASSPHRASE included) and connection strings:
# *_PASS, *_PAT (personal access tokens), *_COOKIE, DOCKER_AUTH_CONFIG, NPM_AUTH*, Gradle's
# ORG_GRADLE_PROJECT_<signing key / password> properties,
# MYSQL_PWD, Yarn's npmAuthIdent (*_AUTH_IDENT), Bundler's per-host credentials
# (BUNDLE_<HOST>__<TLD>, a name with a double underscore; BUNDLE_BUILD__<gem> build options
# are kept, LEAN_KEEP_ENV), git config passed through the environment (GIT_CONFIG_COUNT /
# GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n>, GIT_CONFIG_PARAMETERS: an http.extraHeader
# there carries a token past GIT_CONFIG_GLOBAL=/dev/null) and npm's registry auth keys
# (npm_config_*_auth, *_authToken, *_password, including the scoped
# npm_config_//<registry>/:_authToken). .harness.json::lean.env_passthrough keeps a name.
LEAN_SECRET_ENV='TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|_PASS$|_PAT$|API_KEY|APIKEY|PRIVATE_KEY|ACCESS_KEY|_KEY$|^KEY$|CREDENTIAL|_AUTH_IDENT$|^MYSQL_PWD$|_COOKIE$|^DOCKER_AUTH_CONFIG$|^NPM_AUTH|^ORG_GRADLE_PROJECT_.*(SIGNING|PASSWORD|SECRET)|^BUNDLE_.+__|_URL$|_URI$|_DSN$|^SSH_AUTH_SOCK$|^GIT_CONFIG_(COUNT$|KEY_|VALUE_|PARAMETERS$)|^npm_config_.*(_auth|_authtoken|_password)$'
LEAN_KEEP_ENV='^BUNDLE_BUILD__'

# lean_env_names — the names of the exported variables, NUL-terminated, read from the
# environment itself (env -0, or perl's %ENV where env has no -0), so names that aren't shell
# identifiers (MY-API_TOKEN, npm_config_//reg/:_authToken: bash 5 passes them on without
# listing them in compgen -e) and multi-line values are handled. Fails (prints nothing) when
# neither is there: the callers then refuse to run anything (fail closed).
lean_env_names() {
  local kv
  if env -0 >/dev/null 2>&1; then
    env -0 | while IFS= read -r -d '' kv; do
      if [ -n "${kv%%=*}" ]; then printf '%s\0' "${kv%%=*}"; fi
    done
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'length and print "$_\0" for keys %ENV'
  else
    return 1
  fi
}

# Secret files: basenames (any case) the sessions run.sh opens must not read (lean/sandbox.sh
# denies them to sessions only: the gate's profile keeps them readable, suites load .env) and
# lean/run.sh brief leaves out of its search. LEAN_SECRET_KEEP: the .env templates, which hold
# names without values, stay readable. A folder whose name matches is denied whole.
LEAN_SECRET_NAMES='.env .env.* *.pem *.key *.p12 *.pfx *secret* *credential*'
LEAN_SECRET_KEEP='.env.example .env.sample .env.template'
# Folders lean_secret_files doesn't enter: the git state and installed dependencies (third-party
# code: their credential-provider modules and CA bundles must stay readable, and they are large).
LEAN_SECRET_SKIP_DIRS='.git node_modules bower_components .venv venv .tox vendor Pods target .gradle'
# The names also denied by glob anywhere in the project, for files that appear after the session
# starts: only names no template has (a glob can't leave .env.example out: Claude Code's Read
# rules and Codex take no exception to a deny) and none a dependency ships (*.pem: CA bundles).
LEAN_SECRET_GLOBS='.env .env.local .env.*.local *.key *.p12 *.pfx'

# lean_secret_files <dir> [<skip path>] — the files and folders under <dir> (not <dir> itself)
# whose basename matches LEAN_SECRET_NAMES but not LEAN_SECRET_KEEP, any case, NUL-terminated,
# as found (links not followed; a matching folder is listed and not entered). LEAN_SECRET_SKIP_DIRS
# and <skip path> (with what it holds) are not entered; a folder holding <skip path> is entered
# but never listed (a project inside a repository folder named like a secret stays readable).
lean_secret_files() (
  set -f   # the names are patterns for find, not for the shell
  local dir="$1" skip="${2:-}" n match=() keep=() prune=() hold=() d
  for n in $LEAN_SECRET_NAMES; do match+=(-o -iname "$n"); done
  for n in $LEAN_SECRET_KEEP; do keep+=(-o -iname "$n"); done
  for n in $LEAN_SECRET_SKIP_DIRS; do prune+=(-o -name "$n"); done
  if [ -n "$skip" ]; then
    prune+=(-o -path "$skip")
    d=$(dirname "$skip")
    while [ "$d" != "$dir" ] && [ "$d" != / ] && [ "$d" != . ]; do hold+=(-o -path "$d"); d=$(dirname "$d"); done
  fi
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 \( -type d \( "${prune[@]:1}" \) -prune \) \
    -o \( -false ${hold[@]+"${hold[@]}"} \) \
    -o \( \( "${match[@]:1}" \) ! \( "${keep[@]:1}" \) \( -type d -prune -print0 -o -print0 \) \) 2>/dev/null
)

# lean_env_drop <project> [<keep regex>] — the exported variables to drop, NUL-terminated:
# the names matching LEAN_SECRET_ENV (connection strings such as DATABASE_URL too), except
# those listed in .harness.json::lean.env_passthrough and those matching <keep regex>.
lean_env_drop() {
  local pass n
  pass=$(jq -r '.lean.env_passthrough // [] | .[]' "$1/.harness.json" 2>/dev/null || true)
  while IFS= read -r -d '' n; do
    printf '%s\n' "$n" | grep -qiE "$LEAN_SECRET_ENV" || continue
    ! printf '%s\n' "$n" | grep -qE "$LEAN_KEEP_ENV" || continue
    [ -z "${2:-}" ] || ! printf '%s\n' "$n" | grep -qE "$2" || continue
    [ -n "$pass" ] && grep -qxF -- "$n" <<<"$pass" && continue
    printf '%s\0' "$n"
  done < <(lean_env_names)
}

# lean_env_args <project> [<keep regex>] — sets LEAN_ENV_ARGS to `env` arguments: -u for each
# lean_env_drop name, then the sessions' variables (sandbox.sh's settings env). Returns 1
# when the environment's names can't be listed (lean_env_names).
lean_env_args() {
  local n
  LEAN_ENV_ARGS=()
  lean_env_names >/dev/null || { echo "lean: can't list the environment's variables (no env -0, no perl): refusing to run without dropping the secret-looking ones" >&2; return 1; }
  while IFS= read -r -d '' n; do [ -z "$n" ] || LEAN_ENV_ARGS+=(-u "$n"); done < <(lean_env_drop "$@")
  # Proxy variables (any name ending in "proxy", any case: http_proxy, HTTPS_PROXY, ALL_PROXY,
  # npm_config_https_proxy, YARN_HTTPS_PROXY, BUNDLE_HTTP_PROXY, ...) are kept, but without the
  # credentials a URL may carry: everything up to the last @ goes
  # (http://user:pa/ss@proxy:8080 -> http://proxy:8080); a value holding an @ that isn't then
  # [scheme://]host[:port][/] is dropped. Unless .harness.json::lean.env_passthrough lists the name.
  local pass v s set=()
  pass=$(jq -r '.lean.env_passthrough // [] | .[]' "$1/.harness.json" 2>/dev/null || true)
  while IFS= read -r -d '' n; do
    printf '%s\n' "$n" | grep -qiE 'proxy$' || continue
    [ -n "$pass" ] && grep -qxF -- "$n" <<<"$pass" && continue
    v=$(printenv -- "$n") || continue
    case "$v" in *@*) ;; *) continue ;; esac
    s=""
    case "$v" in *$'\n'*) ;; *) s=$(printf '%s\n' "$v" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)?.*@#\1#') ;; esac
    if printf '%s\n' "$s" | grep -qE '^([A-Za-z][A-Za-z0-9+.-]*://)?(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(:[0-9]+)?/?$'; then
      set+=("$n=$s")
    else
      LEAN_ENV_ARGS+=(-u "$n")
    fi
  done < <(lean_env_names)
  # LEAN_GATE_UNSANDBOXED never reaches a session or the commands the gate runs: it is the
  # caller's choice for its own gate run, not something session-written code should see.
  LEAN_ENV_ARGS+=(-u LEAN_GATE_UNSANDBOXED)
  LEAN_ENV_ARGS+=(${set[@]+"${set[@]}"} RUSTC_WRAPPER= CARGO_BUILD_RUSTC_WRAPPER= GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_GLOBAL=/dev/null)
}

# lean_in_group <command...> — runs the command in a new session (setsid: its own process
# group, and no controlling terminal, so it can't push input into the caller's terminal with
# TIOCSTI or stop the caller's job), with stdin from /dev/null and no file descriptor above 2
# (what the caller holds open stays out of reach). When it ends, whatever it left running in
# that group (a server or a background job the suite started) is killed, with a [WARN] on
# stderr; the exit status stays the command's. A process that starts a session or group of
# its own is out of the group and not looked for. Without perl (setsid, closing the
# descriptors), nothing runs: exit 125 (fail closed).
lean_in_group() {
  command -v perl >/dev/null 2>&1 || { echo "lean: perl is needed to run the command in a session of its own, without a terminal or inherited descriptors: refusing to run it" >&2; return 125; }
  local pid rc=0
  perl -e '
    use POSIX ();
    my $sid = POSIX::setsid();
    defined $sid && $sid > 0 or die "lean_in_group: setsid: $!\n";
    opendir(my $d, "/dev/fd") or die "lean_in_group: /dev/fd: $!\n";
    my @fds = grep { /^\d+$/ && $_ > 2 } readdir $d;
    closedir $d;
    POSIX::close($_) for @fds;
    open(STDIN, "<", "/dev/null") or die "lean_in_group: /dev/null: $!\n";
    exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"' "$@" &
  pid=$!
  trap 'kill -TERM -- "-$pid" 2>/dev/null' INT TERM
  wait "$pid" || rc=$?
  trap - INT TERM
  if kill -0 -- "-$pid" 2>/dev/null; then
    echo "[WARN] lean: processes the command started were still running when it ended (killed; a suite should stop what it starts)" >&2
    kill -TERM -- "-$pid" 2>/dev/null; sleep 1; kill -KILL -- "-$pid" 2>/dev/null
  fi
  return "$rc"
}

# lean_run_lock <project> / lean_run_unlock <project> — one sandboxed run of a project at a
# time (two suites of one project at once would trip over each other's files, ports and
# databases). The lock is a folder in the project's lean state, which the profile can neither
# read nor write, holding "<pid> <start time>" of the holder (the shell that took it); a holder
# that is gone loses it, and so does one whose pid now belongs to another process (a different
# start time), and a lock left without a holder for 5 s. Waits up to LEAN_RUN_LOCK_WAIT seconds
# (default 900), then fails.
lean_proc_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }
lean_run_lock() {
  local dir holder hpid waited=0
  dir="$(lean_state_dir "$1")/tmp/run.lock" || return 1
  mkdir -p "$(dirname "$dir")" || return 1
  until mkdir "$dir" 2>/dev/null; do
    holder=$(cat "$dir/pid" 2>/dev/null || true); hpid=${holder%% *}
    if [ -n "$hpid" ] && { ! kill -0 "$hpid" 2>/dev/null || [ "$(lean_proc_start "$hpid")" != "${holder#* }" ]; }; then
      rm -rf "$dir"; continue
    fi
    if [ -z "$hpid" ] && [ "$waited" -ge 5 ]; then rm -rf "$dir"; continue; fi
    if [ "$waited" -ge "${LEAN_RUN_LOCK_WAIT:-900}" ]; then
      echo "lean: another sandboxed run of this project (pid ${hpid:-?}) still holds $dir: failing" >&2
      return 1
    fi
    [ "$waited" != 0 ] || echo "lean: waiting for another sandboxed run of this project (pid ${hpid:-?}) to end" >&2
    sleep 1; waited=$((waited + 1))
  done
  printf '%s %s\n' "$$" "$(lean_proc_start "$$")" > "$dir/pid"
}
lean_run_unlock() { rm -rf "$(lean_state_dir "$1")/tmp/run.lock"; }

# lean_in_session <project> — true inside a session run.sh opened: the adapters set
# LEAN_SESSION=1 in its environment, and, should a command unset that, the project's lean state
# (which the sessions' sandbox denies) refuses to be listed ("Operation not permitted").
lean_in_session() {
  local state err
  [ "${LEAN_SESSION:-}" != 1 ] || return 0
  state=$(lean_state_dir "$1" 2>/dev/null) || return 1
  err=$(LC_ALL=C ls -- "$state" 2>&1 >/dev/null) && return 1
  case "$err" in *"not permitted"*) return 0 ;; esac
  return 1
}

# LEAN_SESSION_REFUSAL — why nothing runs when lean_sandbox_prepare finds itself in a session.
LEAN_SESSION_REFUSAL="inside a lean session: the full suite, ./init.sh and the gate run after the session, outside it (LEAN_GATE_UNSANDBOXED is ignored here); run the feature's own tests directly"

# lean_sandbox_prepare <project> — decides how lean_sandboxed runs commands for the
# project's open lean feature and sets LEAN_SANDBOX: "sandbox" (LEAN_PROFILE holds the seatbelt profile),
# "unsandboxed: <why>" (no sandbox-exec, or LEAN_GATE_UNSANDBOXED=1), "broken: <why>"
# (sandbox-exec is there but can't apply the profile, e.g. when already inside a sandbox) or
# "session: <why>" (inside a lean session, lean_in_session: nothing runs, and
# LEAN_GATE_UNSANDBOXED=1 is ignored; it is for the gate and the tests run from outside).
# LEAN_SANDBOX_WARN holds sandbox.sh's [WARN] lines (allowed_domains opening the network):
# every caller prints them.
lean_sandbox_prepare() {
  local err why
  LEAN_PROFILE="" LEAN_SANDBOX_WARN=""
  if lean_in_session "$1"; then LEAN_SANDBOX="session: $LEAN_SESSION_REFUSAL"; return 0; fi
  if [ "${LEAN_GATE_UNSANDBOXED:-}" = 1 ]; then LEAN_SANDBOX="unsandboxed: LEAN_GATE_UNSANDBOXED=1"; return 0; fi
  if ! command -v sandbox-exec >/dev/null 2>&1; then
    LEAN_SANDBOX="unsandboxed: no sandbox-exec on this platform ($(uname -s))"; return 0
  fi
  err=$(mktemp) || { LEAN_SANDBOX="broken: no temp file for lean/sandbox.sh's messages"; return 0; }
  if ! LEAN_PROFILE=$("$LEAN_LIB_DIR/sandbox.sh" "$1" --seatbelt 2>"$err"); then
    # Name sandbox.sh's own reason (its first non-[WARN] lines) so the gate's message says why.
    why=$(grep -v '^\[WARN\]' "$err" | grep -v '^[[:space:]]*$' | head -3 | tr '\n' ' ' | sed 's/ *$//')
    rm -f "$err"; LEAN_SANDBOX="broken: lean/sandbox.sh could not build the profile${why:+: $why}"; return 0
  fi
  LEAN_SANDBOX_WARN=$(grep '^\[WARN\]' "$err" || true); rm -f "$err"
  if ! sandbox-exec -p "$LEAN_PROFILE" true 2>/dev/null; then
    LEAN_SANDBOX="broken: sandbox-exec can't apply the profile here (already inside a sandbox?)"; return 0
  fi
  LEAN_SANDBOX=sandbox
}

# lean_sandboxed <project> <command> — runs `bash -c <command>` in <project> as
# lean_sandbox_prepare decided: under the rules of the feature's sessions (sandbox.sh
# --seatbelt: the same reads, writes only in the project, /private/tmp and a fresh TMPDIR of
# its own, network only to localhost, unix sockets only in the project, the local database
# sockets and that TMPDIR, plus the specific denies listed there), one run of the project at a
# time (lean_run_lock); unsandboxed when it said so. Either way with the sessions' environment
# (lean_env_args) and in a new session without a terminal, stdin or inherited descriptors, its
# process group killed when the command ends (lean_in_group). Exit 125 when the sandbox is
# broken, the environment can't be scrubbed or the lock can't be taken.
lean_sandboxed() {
  local rc=0 run_tmp
  lean_env_args "$1" || return 125
  case "${LEAN_SANDBOX:-}" in
    sandbox)
      lean_run_lock "$1" || return 125
      if ! run_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lean-run.XXXXXX") || ! run_tmp=$(cd "$run_tmp" && pwd -P); then
        lean_run_unlock "$1"; return 125
      fi
      (cd "$1" && lean_in_group env "${LEAN_ENV_ARGS[@]}" TMPDIR="$run_tmp/" sandbox-exec -p "$LEAN_PROFILE
(allow file-write* (subpath \"$run_tmp\"))
(allow network-outbound (remote unix-socket (subpath \"$run_tmp\")))" bash -c "$2") || rc=$?
      rm -rf "$run_tmp"
      lean_run_unlock "$1"
      return "$rc" ;;
    unsandboxed:*) (cd "$1" && lean_in_group env "${LEAN_ENV_ARGS[@]}" bash -c "$2") ;;
    *) echo "lean: ${LEAN_SANDBOX:-lean_sandbox_prepare did not run}" >&2; return 125 ;;
  esac
}

# lean_z_lines — NUL-separated names on stdin, one per line; a name holding a newline is printed
# quoted (printf %q), so it stays one line and matches no listed path.
lean_z_lines() {
  local n
  while IFS= read -r -d '' n; do
    case "$n" in *$'\n'*) printf '%q\n' "$n" ;; *) printf '%s\n' "$n" ;; esac
  done
}

# lean_repo_changes <base> — every changed (against <base>) or untracked, non-ignored file of
# the current directory's repository, from its root (git diff --no-relative), sorted, one per
# line. lean/gate.sh checks this set; lean/chain.sh lists it in its close line.
lean_repo_changes() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  { git diff -z --no-relative --name-only "$1"; git -C "$top" ls-files -z --others --exclude-standard; } \
    | lean_z_lines | sed '/^$/d' | sort -u
}

# Usage report: <state>/lean/<name>/usage.tsv, append-only, one row per session run.sh opens
# (implement, review, fix; headless or interactive, chained or by hand). Columns:
#   at feature step mode tool model turns input cache_read cache_write output seconds cost_usd note
# From the result JSON the adapter wrote (claude -p's, or codex.sh's in the same shape):
# model = the keys of claude's modelUsage, most output first (else the configured model,
# "default" when none), turns = num_turns (Codex: completed items), tokens summed over modelUsage when present (it
# counts subagents too), else from usage. input is the uncached input for every tool: Codex
# reports the cached tokens inside input_tokens, so they are subtracted. cost_usd only as the
# CLI reports it (total_cost_usd); "-" for Codex (none) and claude-mini (Claude Code's estimate
# at Anthropic prices, not what MiniMax bills). No price table anywhere. A field the JSON lacks
# is "?"; an interactive session has no result JSON: its row holds the duration only.
# seconds: the session's wall time as run.sh measured it. Best-effort: a failure here never
# changes a step's outcome.
LEAN_USAGE_HEADER='at	feature	step	mode	tool	model	turns	input	cache_read	cache_write	output	seconds	cost_usd	note'

lean_usage_file() { printf '%s/lean/%s/usage.tsv\n' "$(lean_state_dir "$1")" "$2"; }

# lean_usage_record <project> <name> <step> <mode> <tool> <model|-> <seconds> <result_json|->
# (- : an interactive session).
lean_usage_record() {
  local file tool="$5" model="$6" res="$8" parsed="" jmodel="" turns="" in="" cr="" cw="" out="" cost="" note=""
  file=$(lean_usage_file "$1" "$2") || return 0
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  [ "$model" != - ] || model=default
  if [ "$res" = - ]; then
    turns=- in=- cr=- cw=- out=- cost=- note="interactive (not measured)"
  else
    parsed=$(jq -r 'def num: if type == "number" then (floor | tostring) else "?" end;
      select(type == "object")
      | (.modelUsage | if type == "object" and length > 0 then . else null end) as $mu
      | (if $mu then {in: ([$mu[] | .inputTokens // 0] | add), cr: ([$mu[] | .cacheReadInputTokens // 0] | add),
                      cw: ([$mu[] | .cacheCreationInputTokens // 0] | add), out: ([$mu[] | .outputTokens // 0] | add),
                      m: ($mu | to_entries | sort_by(-(.value.outputTokens // 0)) | map(.key) | join("+"))}
         else (.usage | if type == "object" then . else {} end) as $u
           | {in: $u.input_tokens, cr: $u.cache_read_input_tokens, cw: $u.cache_creation_input_tokens,
              out: $u.output_tokens, m: ""} end) as $t
      | (if .tool == "codex" and ($t.in | type) == "number" and ($t.cr | type) == "number"
         then ([$t.in - $t.cr, 0] | max) else $t.in end) as $in
      | [($t.m | if . == "" then "-" else gsub("[\t\n]"; " ") end), (.num_turns | num), ($in | num), ($t.cr | num),
         ($t.cw | num), ($t.out | num), (.total_cost_usd | if type == "number" then tostring else "-" end),
         (if .subtype == "error_max_turns" then "max_turns"
          elif .is_error == true then "is_error" else "" end)] | join("\t")' "$res" 2>/dev/null | head -1) || parsed=""
    if [ -n "$parsed" ]; then
      IFS=$'\t' read -r jmodel turns in cr cw out cost note <<<"$parsed" || true
      [ "${jmodel:--}" = - ] || model="$jmodel"
    else
      turns='?' in='?' cr='?' cw='?' out='?' cost='?' note="no readable result JSON"
    fi
    [ "$tool" != claude-mini ] || cost=-
  fi
  [ -s "$file" ] || printf '%s\n' "$LEAN_USAGE_HEADER" >> "$file" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" \
    "$tool" "$model" "${turns:-?}" "${in:-?}" "${cr:-?}" "${cw:-?}" "${out:-?}" "$7" "${cost:-?}" "$note" \
    >> "$file" 2>/dev/null || return 0
}

# lean_usage_count <project> <name> — how many rows the feature has (0: none).
lean_usage_count() {
  local file
  file=$(lean_usage_file "$1" "$2") || { echo 0; return 0; }
  [ -f "$file" ] || { echo 0; return 0; }
  awk 'NR > 1' "$file" | wc -l | tr -d ' '
}

# lean_usage_table <project> <name> [<skip>] — the feature's rows after the first <skip> as a
# compact table: tokens in k/M, a sum row over the rows shown (a column with no number in any
# row: "?"; the cost summed over the reported ones only), and a pointer to the skipped rows.
# Fails, printing nothing, when there is no row to show.
lean_usage_table() {
  local file
  file=$(lean_usage_file "$1" "$2") || return 1
  [ -f "$file" ] || return 1
  awk -F'\t' -v skip="${3:-0}" -v name="$2" '
    function tok(x) { if (x !~ /^[0-9]+$/) return x; if (x >= 1e6) return sprintf("%.1fM", x / 1e6)
                      if (x >= 1e3) return sprintf("%.1fk", x / 1e3); return x }
    function dur(s) { return (s ~ /^[0-9]+$/) ? sprintf("%dm%02ds", int(s / 60), s % 60) : s }
    function money(c) { return (c ~ /^[0-9.]+$/) ? sprintf("$%.2f", c) : c }
    function add(i, v) { if (v ~ /^[0-9]+$/) { sum[i] += v; has[i] = 1 } }
    function total(i) { return has[i] ? sum[i] : "?" }
    function line(a, b, c, d, e, f, g, h, i, j, k, l) {
      printf "  %-9s %-6s %-11s %-24s %5s %6s %7s %7s %6s %7s %6s%s\n", a, b, c, substr(d, 1, 24), e, f, g, h, i, j, k, (l == "" ? "" : "  " l)
    }
    NR == 1 || NR - 1 <= skip { next }
    { n++; row[n] = $0
      for (i = 7; i <= 12; i++) add(i, $i)
      if ($13 ~ /^[0-9.]+$/) { cost += $13; costs++ } }
    END {
      if (n == 0) exit 1
      printf "usage (%s: %d session%s%s):\n", name, n, (n == 1 ? "" : "s"),
             (skip > 0 ? sprintf("; %d earlier: lean/run.sh usage %s", skip, name) : "")
      line("step", "mode", "tool", "model", "turns", "in", "c.read", "c.write", "out", "time", "cost", "")
      for (r = 1; r <= n; r++) { split(row[r], f, "\t")
        line(f[3], f[4], f[5], f[6], f[7], tok(f[8]), tok(f[9]), tok(f[10]), tok(f[11]), dur(f[12]), money(f[13]), f[14]) }
      line("sum", "", "", "", total(7), tok(total(8)), tok(total(9)), tok(total(10)), tok(total(11)),
           dur(total(12)), (costs ? money(cost) : "-"), "")
    }' "$file"
}
