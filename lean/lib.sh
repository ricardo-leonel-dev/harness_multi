#!/usr/bin/env bash
# lib.sh — helpers shared by lean/run.sh, lean/gate.sh, scripts/harness.sh and init.sh.
# Sourced, not executed; every name starts with lean_.
#
# State: the lean flow keeps each project's pinned state outside the project, in
# lean_state_dir: frozen/<name>.sha (risk mode's acceptance manifest), lean/<name>/trusted.sha
# (the hashes of the harness-owned files the flow runs or trusts) and run results. The folder is keyed by the project's resolved path,
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

# lean_pin <project> <name> [--again] — pins the hashes of the trusted files under
# <state>/lean/<name>/trusted.sha when they aren't pinned yet (--again: afresh).
lean_pin() {
  local project="$1" name="$2" again="${3:-}" dir
  dir="$(lean_state_dir "$project")/lean/$name" || return 1
  mkdir -p "$dir" || return 1
  [ "$again" = --again ] || [ ! -f "$dir/trusted.sha" ] || return 0
  lean_trusted_manifest "$project" > "$dir/trusted.tmp" && mv "$dir/trusted.tmp" "$dir/trusted.sha" || return 1
  echo "[lean] pinned the hashes of $(wc -l < "$dir/trusted.sha" | tr -d ' ') harness-owned file(s) in $dir/trusted.sha" >&2
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

# lean_sandbox_prepare <project> — decides how lean_sandboxed runs commands for the
# project's open lean feature and sets LEAN_SANDBOX: "sandbox" (LEAN_PROFILE holds the seatbelt profile),
# "unsandboxed: <why>" (no sandbox-exec, or LEAN_GATE_UNSANDBOXED=1) or "broken: <why>"
# (sandbox-exec is there but can't apply the profile, e.g. when already inside a sandbox).
# LEAN_SANDBOX_WARN holds sandbox.sh's [WARN] lines (allowed_domains opening the network):
# every caller prints them.
lean_sandbox_prepare() {
  local err
  LEAN_PROFILE="" LEAN_SANDBOX_WARN=""
  if [ "${LEAN_GATE_UNSANDBOXED:-}" = 1 ]; then LEAN_SANDBOX="unsandboxed: LEAN_GATE_UNSANDBOXED=1"; return 0; fi
  if ! command -v sandbox-exec >/dev/null 2>&1; then
    LEAN_SANDBOX="unsandboxed: no sandbox-exec on this platform ($(uname -s))"; return 0
  fi
  err=$(mktemp) || { LEAN_SANDBOX="broken: no temp file for lean/sandbox.sh's messages"; return 0; }
  if ! LEAN_PROFILE=$("$LEAN_LIB_DIR/sandbox.sh" "$1" --seatbelt 2>"$err"); then
    rm -f "$err"; LEAN_SANDBOX="broken: lean/sandbox.sh could not build the profile"; return 0
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
