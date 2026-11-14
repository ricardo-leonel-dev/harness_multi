#!/usr/bin/env bash
# lean_codex_adapter_test.sh — lean/adapters/codex.sh and the `codex` roles in lean/run.sh,
# against a STUB `codex` on PATH (it records its argv and environment and emits canned
# output; no model is ever called, no real sandbox runs).
#
#   1. interactive argv: the permission profile, the network proxy, approvals by the user, the
#      system prompt as developer_instructions, the model; no bypass flag; the profile's
#      filesystem table (project writable, harness-owned files and .git read-only, $HOME
#      entries and the lean state denied, instruction files denied by glob, no /tmp); no
#      AGENTS.md loaded (project_doc_max_bytes=0, no fallback names) with the deny globs kept,
#      checked by a local `codex debug prompt-input` probe (same flags, temp CODEX_HOME).
#   2. headless: `codex exec --json`, approvals never, --ignore-rules; the result JSON
#      (tokens summed over turns, num_turns, session_id, duration, total_cost_usd null);
#      a failed turn or a non-zero exit is is_error; a junk line is skipped.
#   3. fail closed: the self-check failing (sandbox can't apply, no seatbelt, no network
#      proxy, a caller's own loopback proxy standing in for Codex's, a write or read of the
#      lean state that goes through, the toolchain cache root listable) refuses before any session (exit 3); the caller's proxy
#      variables never reach codex. The prompt probe failing (AGENTS.md denied to Codex's
#      loader without project_doc_max_bytes=0, as codex-cli 0.167) or carrying AGENTS.md
#      instructions refuses too.
#   3b. codex installed behind a symlink chain into a fake ~/.codex/packages/...: its release
#      folder is `read`, ~/.codex (auth.json, config.toml) stays denied, the session starts the
#      resolved binary, the check runs it with a temp CODEX_HOME; a binary directly in the
#      Codex home (no packages/ release folder) can't run inside the profile -> exit 3.
#   4. environment: secret-looking variables dropped, lean.env_passthrough kept, OPENAI_*
#      kept for Codex but excluded from the commands.
#   5. run.sh: `codex` / `codex:<model>` for implementer and reviewer; risk mode still refuses
#      the same tool in both roles; an unknown tool is refused.
#   6. chain with a codex implementer (no lean.reviewer: it reviews too): CHAIN: PASS, turns on
#      the step line, no cost.
#   7. codex-m3 (lean/adapters/codex-m3.sh): the resolved codex binary with --profile minimax
#      (LEAN_CODEX_M3_PROFILE overrides, an invalid name refused) on the session and the sandbox
#      check, never through fish; every protection of 1-4 unchanged; the prompt probe without the
#      profile; the model argument ignored; result/usage rows say codex-m3 and the reported model,
#      else minimax, no cost; run.sh accepts it as a string and per mode; risk mode refuses it in
#      both roles and next to claude-mini (both MiniMax); "codex-m3:<model>" is unknown.
#
# Usage: bash tests/lean_codex_adapter_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"   # resolved: the adapter starts codex by its resolved path
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }
g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

mkdir -p "$WORK/home/Documents" "$WORK/bin"
echo private > "$WORK/home/Documents/p.txt"
export HOME="$WORK/home" LEAN_CACHE_BASE="$WORK/cache-base" LEAN_GATE_UNSANDBOXED=1 GIT_CONFIG_GLOBAL=/dev/null
export LEAN_CLAUDE_TMP="$WORK/no-claude-tmp"
export CALLS="$WORK/calls"
A="$TOOLKIT_DIR/lean/adapters/codex.sh"

# The stub: each call gets $CALLS/<n>.<kind>.argv (NUL-separated) and .env (env -0).
# sandbox: runs the self-check script as the real one would see it (CODEX_SANDBOX=seatbelt,
# the canary folder unreadable and unwritable; with --enable network_proxy, Codex's proxy:
# HTTP(S)_PROXY on loopback and CODEX_NETWORK_PROXY_ACTIVE=1; without it the caller's
# environment passes through unchanged, as the real codex does), unless STUB_SANDBOX says
# otherwise: fail (exit 71 like sandbox-exec), noseatbelt, noproxy (the proxy feature not
# taking effect), open (canary left writable), readable (canary readable, not writable), noexec
# (the codex binary can't run inside the profile), rootopen (the toolchain cache root and the
# project's cache folder left listable around the session folder's `write` entry). Like the real profile, it applies the
# filesystem table to the codex binary and the Codex home the check names: when the most
# specific non-glob entry covering them is `deny`, the binary can't run and the home can't be
# listed (a stand-in folder: the real home must stay traversable for the binary). --version: records CODEX_HOME in $CALLS/version.codex_home, nothing else. exec:
# prints $STUB_EVENTS (default: canned events), writes the -o file, runs
# $STUB_EXEC_SCRIPT in the current dir, exits $STUB_EXEC_RC. Otherwise (interactive): exit 0.
# Every recorded call also keeps the path it was started by ($0) in $CALLS/<n>.<kind>.self.
cat > "$WORK/bin/codex" <<'SH'
#!/usr/bin/env bash
mkdir -p "$CALLS"
[ "${1:-}" != --version ] || { printf '%s\n' "${CODEX_HOME:-}" > "$CALLS/version.codex_home"; echo "codex-cli 0.0.0-stub"; exit 0; }
n=$(ls "$CALLS" | grep -c '\.argv$')
kind=interactive
case "${1:-}" in sandbox) kind=sandbox ;; exec) kind=exec ;; debug) kind=debug ;; esac
printf '%s\0' "$@" > "$CALLS/$n.$kind.argv"
env -0 > "$CALLS/$n.$kind.env"
printf '%s' "$0" > "$CALLS/$n.$kind.self"
case "$kind" in
  sandbox)
    [ "${STUB_SANDBOX:-}" != fail ] || { echo "sandbox-exec: sandbox_apply: Operation not permitted" >&2; exit 71; }
    proxy=() table='{}'
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
      case "$1" in permissions.lean.filesystem=*) table=$(printf '%s' "${1#*=}" | sed 's/"="/":"/g') ;; esac
      [ "$1 ${2:-}" != "--enable network_proxy" ] || [ "${STUB_SANDBOX:-}" = noproxy ] \
        || proxy=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 CODEX_NETWORK_PROXY_ACTIVE=1)
      shift
    done; shift
    # "$@" = /bin/sh -c <script> sh <canary> <session tmp> <secret> <codex binary> <Codex home>
    #       <cache folder> <cache root> <project's cache folder>
    canary="$5" home="${9:-}"
    denied() {
      [ "$(jq -r --arg p "$1" '[to_entries[] | .key as $k | select(($k | contains("*") | not)
        and ($p == $k or ($p | startswith($k + "/"))))] | max_by(.key | length) | .value // ""' <<<"$table")" = deny ]
    }
    args=("$@")
    noexec=""
    if [ "${STUB_SANDBOX:-}" = noexec ] || denied "$8"; then noexec="$8"; chmod a-x "$noexec"; fi
    if [ -n "$home" ] && denied "$home"; then args[8]="$CALLS/denied-home"; mkdir -p "${args[8]}"; chmod 000 "${args[8]}"; fi
    # A `deny` cache root (or project folder) around the session's `write` folder: unlistable,
    # still traversable (mode 300), as the real profile leaves it.
    locked=()
    for i in 10 11; do
      d="${args[$i]:-}"
      [ -n "$d" ] && [ -d "$d" ] && [ "${STUB_SANDBOX:-}" != rootopen ] && denied "$d" || continue
      chmod 300 "$d"; locked+=("$d")
    done
    case "${STUB_SANDBOX:-}" in open) ;; readable) chmod 555 "$canary" ;; *) chmod 000 "$canary" ;; esac
    seat=seatbelt
    [ "${STUB_SANDBOX:-}" != noseatbelt ] || seat=""
    rc=0; env CODEX_SANDBOX="$seat" ${proxy[@]+"${proxy[@]}"} "${args[@]}" || rc=$?
    [ -z "$noexec" ] || chmod u+x "$noexec"
    chmod 700 "$canary"; [ ! -d "$CALLS/denied-home" ] || chmod 700 "$CALLS/denied-home"
    for d in ${locked[@]+"${locked[@]}"}; do chmod 700 "$d"; done
    exit "$rc" ;;
  debug)
    # `debug prompt-input` as codex-cli 0.167 does it: the project's AGENTS.md is read through
    # the sandboxed helper, so a deny glob on it fails the session; project_doc_max_bytes=0
    # skips it. STUB_DEBUG=fail fails anyway; STUB_DEBUG=agents loads it anyway.
    printf '%s\n' "$CODEX_HOME" > "$CALLS/debug.codex_home"
    a=$(printf '%s\n' "$@")
    if [ "${STUB_DEBUG:-}" = fail ] || { [ "${STUB_DEBUG:-}" != agents ] && [ -f AGENTS.md ] \
         && ! grep -qx 'project_doc_max_bytes=0' <<<"$a" && grep -q '/\*\*/AGENTS\.md"="deny"' <<<"$a"; }; then
      echo 'Error: failed to load AGENTS.md instructions for environment `local`: Operation not permitted (os error 1)' >&2; exit 1
    fi
    if [ "${STUB_DEBUG:-}" = agents ] || { [ -f AGENTS.md ] && ! grep -qx 'project_doc_max_bytes=0' <<<"$a"; }; then
      jq -n --arg t "# AGENTS.md instructions for $PWD" '[{type: "message", content: [{text: $t}]}]'
    else echo '[]'; fi
    exit 0 ;;
  exec)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
    [ -z "$out" ] || echo "all done" > "$out"
    [ -z "${STUB_EXEC_SCRIPT:-}" ] || bash -c "$STUB_EXEC_SCRIPT"
    if [ -n "${STUB_EVENTS:-}" ]; then printf '%s\n' "$STUB_EVENTS"; else cat <<'EV'
{"type":"thread.started","thread_id":"th-123"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"i0","type":"command_execution"}}
not json at all
{"type":"item.completed","item":{"id":"i1","type":"file_change"}}
{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50,"reasoning_output_tokens":7}}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"i2","type":"agent_message"}}
{"type":"turn.completed","usage":{"input_tokens":200,"cached_input_tokens":100,"cache_write_input_tokens":3,"output_tokens":20}}
EV
    fi
    exit "${STUB_EXEC_RC:-0}" ;;
esac
exit 0
SH
chmod +x "$WORK/bin/codex"
# Fail closed: the real claude adapters stay in use, so a step routed to claude (or to the
# claude-mini fish function) must hit these stubs and fail loudly, never a real model CLI.
for cli in claude fish; do
  printf '#!/usr/bin/env bash\necho "real CLI called from a test: %s $*" >&2\nexit 99\n' "$cli" > "$WORK/bin/$cli"
  chmod +x "$WORK/bin/$cli"
done
export PATH="$WORK/bin:$PATH"

reset() { rm -rf "$CALLS"; mkdir -p "$CALLS"; unset STUB_SANDBOX STUB_EVENTS STUB_EXEC_RC STUB_EXEC_SCRIPT STUB_DEBUG; }
# argv_of <kind> — the last call of that kind, one argument per line.
argv_of() { local f; f=$(ls "$CALLS"/*."$1".argv 2>/dev/null | tail -1); [ -n "$f" ] && tr '\0' '\n' < "$f"; }
env_of() { local f; f=$(ls "$CALLS"/*."$1".env 2>/dev/null | tail -1); [ -n "$f" ] && tr '\0' '\n' < "$f"; }
has() { argv_of "$1" | grep -qxF -- "$2"; }
n_calls() { ls "$CALLS" | grep -c "\.$1\.argv$"; }
no_bypass() {
  local re='dangerously|bypass|danger-full-access|approve-for-me|^--sandbox$|^-s$|workspace-write|^-a$|^--ask-for-approval|on-request|on-failure|untrusted|escalat'
  if argv_of "$1" | grep -qiE "$re"; then
    die "$1 argv carries a bypass, escalation or legacy sandbox flag: $(argv_of "$1" | grep -iE "$re")"
  fi
}
fs_table() { argv_of "$1" | sed -n 's/^permissions\.lean\.filesystem=//p'; }

# new_project <dir> <implementer> <reviewer> — a git repository whose suite passes once
# src/app.txt says done.
new_project() {
  local p="$1"
  mkdir -p "$p/src" "$p/tests" "$p/docs/features" "$p/acceptance" "$p/lean"
  jq -n --arg i "$2" --arg r "$3" '{verify_command: "bash run_tests.sh", lean: {implementer: $i, reviewer: $r, allowed_domains: ["registry.example"]}}' > "$p/.harness.json"
  cat > "$p/run_tests.sh" <<'T'
[ $# -gt 0 ] || set -- tests/*_test.sh
rc=0
for f in "$@"; do if bash "$f"; then echo " 1 pass"; else echo " 1 fail"; rc=1; fi; done
[ "$rc" = 0 ] && echo "suite passes"
exit "$rc"
T
  printf 'grep -q done src/app.txt || { echo "FAIL: app_test expects done"; exit 1; }\n' > "$p/tests/app_test.sh"
  printf 'grep -q done src/app.txt || { echo "FAIL: acceptance expects done"; exit 1; }\n' > "$p/acceptance/f.test.sh"
  printf 'todo\n' > "$p/src/app.txt"
  printf '# f\n\n**Files**\n- `src/app.txt`\n' > "$p/docs/features/f.md"
  printf '.harness.json\nlean/\n' > "$p/.gitignore"
  g -C "$p" init -q && g -C "$p" add -A && g -C "$p" commit -qm base || die "project setup: $p"
}

P="$WORK/p1"; new_project "$P" codex codex:other
printf '# orchestrator instructions\n' > "$P/AGENTS.md"; g -C "$P" add AGENTS.md && g -C "$P" commit -qm agents || die "project setup: AGENTS.md"
P_REAL=$(cd "$P" && pwd -P)
printf 'You are the lean implementer. "Quotes" and \\ backslashes.\nSecond line.\n' > "$WORK/system.md"

echo "1. interactive"
reset
"$A" "$P" interactive gpt-test "$WORK/system.md" "Implement docs/features/f.md" > "$WORK/out" 2>&1 || die "interactive: $(cat "$WORK/out")"
[ "$(n_calls sandbox)" = 1 ] && [ "$(n_calls interactive)" = 1 ] || die "one check then one session: $(ls "$CALLS")"
for a in --enable network_proxy 'default_permissions="lean"' 'permissions.lean.extends=":read-only"' \
         'approval_policy="never"' 'approvals_reviewer="user"' -m gpt-test -C "$P"; do
  has interactive "$a" || die "interactive argv lacks $a: $(argv_of interactive | head -40)"
done
[ "$(argv_of interactive | tail -1)" = "Implement docs/features/f.md" ] || die "the prompt goes last"
no_bypass interactive; no_bypass sandbox
dev=$(argv_of interactive | sed -n 's/^developer_instructions=//p')
[ "$(jq -r . <<<"$dev")" = "$(cat "$WORK/system.md")" ] || die "developer_instructions must carry the system prompt exactly: $dev"
argv_of interactive | grep -q '^permissions\.lean\.network={enabled=true,allow_local_binding=true,domains={"registry.example"="allow"},unix_sockets={' \
  || die "network: proxy with allowed domains: $(argv_of interactive | grep network)"
# The check ran with the session's own flags.
sandbox_flags() { argv_of "$1" | grep -E '^(network_proxy|default_permissions=|permissions\.|approvals_reviewer=|shell_environment_policy\.)' | sort; }
[ -n "$(sandbox_flags sandbox)" ] && [ "$(sandbox_flags sandbox)" = "$(sandbox_flags interactive)" ] \
  || die "the self-check must use the session's sandbox flags: $(diff <(sandbox_flags sandbox) <(sandbox_flags interactive))"
pass "interactive: profile, proxy, approvals never (no escalation), model, system prompt; no bypass flag; check uses the same flags"

fs=$(fs_table interactive)
st=$(bash -c '. "$1/lean/lib.sh"; lean_state_dir "$2"' _ "$TOOLKIT_DIR" "$P")
for kv in "\"$P\"=\"write\"" "\"$P/lean\"=\"read\"" "\"$P/.git\"=\"read\"" "\"$P/.harness.json\"=\"read\"" \
          "\"$HOME/Documents\"=\"deny\"" "\"$P/**/CLAUDE.md\"=\"deny\"" "\"$P/**/AGENTS.md\"=\"deny\"" \
          "\"$P/**/.claude/**\"=\"deny\"" "\"$P/**/.codex/**\"=\"deny\""; do
  case "$fs" in *"$kv"*) ;; *) die "filesystem table lacks $kv: $fs" ;; esac
done
[ "$P_REAL" = "$P" ] || case "$fs" in *"\"$P_REAL\"=\"write\""*) ;; *) die "the resolved project is writable too: $fs" ;; esac
case "$fs" in *'"/tmp"='*|*'"/private/tmp"="write"'*) die "no /tmp write: $fs" ;; esac
case "$fs" in *"\"$HOME/.cache\"=\"deny\""*|*"\"$HOME/.cache/harness\"=\"deny\""*) ;; *) die "the lean state must be denied: $fs" ;; esac
writes=$(printf '%s' "$fs" | grep -oE '"[^"]*"="write"' | wc -l | tr -d ' ')
[ "$writes" -le 3 ] || die "only the project (and its resolved path) and the session TMPDIR are writable: $fs"
ls "$st/tmp" 2>/dev/null | grep -q codex-check && die "the check's canary folder must be removed"
pass "profile: project writable, harness files and .git read-only, \$HOME entries and lean state denied, instruction globs denied, no /tmp"

# No AGENTS.md reaches the session: project docs off in the session's flags, the deny globs
# kept for commands, and the prompt probe ran with the same flags and a temp CODEX_HOME.
for k in interactive sandbox; do
  has $k 'project_doc_max_bytes=0' && has $k 'project_doc_fallback_filenames=[]' || die "$k: AGENTS.md loading must be off: $(argv_of $k | grep project_doc)"
done
for g in AGENTS.md AGENTS.override.md CLAUDE.md; do
  case "$fs" in *"\"$P/**/$g\"=\"deny\""*) ;; *) die "the deny glob on $g must stay: $fs" ;; esac
done
[ "$(n_calls debug)" = 1 ] && has debug prompt-input || die "one prompt probe (codex debug prompt-input) before the session: $(ls "$CALLS")"
[ "$(sandbox_flags debug)" = "$(sandbox_flags interactive)" ] && has debug 'project_doc_max_bytes=0' \
  || die "the probe must use the session's flags: $(diff <(sandbox_flags debug) <(sandbox_flags interactive))"
case "$(cat "$CALLS/debug.codex_home")" in */lean-session.*/codex-probe-home) ;; *) die "the probe runs with a temp CODEX_HOME: $(cat "$CALLS/debug.codex_home")" ;; esac
env_of debug | grep -qx 'OPENAI_API_KEY=' || die "the probe carries no API key"
pass "no AGENTS.md: project_doc_max_bytes=0 and no fallback names in the session and check flags, deny globs kept, a local prompt probe with the same flags and a temp CODEX_HOME"

echo "2. headless"
reset
"$A" "$P" headless - "$WORK/system.md" "Review" "$WORK/r.json" > "$WORK/out" 2>&1 || die "headless: $(cat "$WORK/out")"
for a in exec --json -o --ignore-rules 'approval_policy="never"' 'approvals_reviewer="user"' --enable network_proxy -C "$P"; do
  has exec "$a" || die "exec argv lacks $a: $(argv_of exec | head -40)"
done
has exec -m && die "no -m when the model is '-'"
no_bypass exec
jq -e '.type == "result" and .tool == "codex" and .is_error == false and .num_turns == 3
  and .session_id == "th-123" and .total_cost_usd == null and .result == "all done\n" and .exit_code == 0
  and (.duration_ms | type == "number")
  and .usage == {input_tokens: 1200, cache_read_input_tokens: 500, cache_creation_input_tokens: 3, output_tokens: 70, reasoning_output_tokens: 7}' \
  "$WORK/r.json" >/dev/null || die "result JSON: $(cat "$WORK/r.json")"
[ -f "$WORK/r.events.jsonl" ] && [ ! -e "$WORK/r.last.txt" ] || die "events kept, last-message file folded in"
jq -c '{is_error, num_turns, duration_ms, total_cost_usd}' "$WORK/r.json" >/dev/null || die "run.sh's summary line must parse"
pass "headless: exec --json, approvals never, rules ignored; tokens summed over turns, num_turns, session id, no cost"

reset; export STUB_EVENTS='{"type":"thread.started","thread_id":"t"}
{"type":"turn.failed","error":{"message":"rate limited"}}'
"$A" "$P" headless - "$WORK/system.md" "x" "$WORK/r2.json" >/dev/null 2>&1 || die "a failed turn with exit 0 still writes the result"
jq -e '.is_error == true and .errors == ["rate limited"] and .usage.input_tokens == 0' "$WORK/r2.json" >/dev/null || die "turn.failed: $(cat "$WORK/r2.json")"
reset; export STUB_EXEC_RC=1
"$A" "$P" headless - "$WORK/system.md" "x" "$WORK/r3.json" >/dev/null 2>&1 && die "a failing codex exec must fail the adapter"
jq -e '.is_error == true and .exit_code == 1' "$WORK/r3.json" >/dev/null || die "non-zero exit: $(cat "$WORK/r3.json")"
reset; export STUB_EVENTS='garbage only'
"$A" "$P" headless - "$WORK/system.md" "x" "$WORK/r4.json" >/dev/null 2>&1
jq -e '.is_error == true and .num_turns == 0' "$WORK/r4.json" >/dev/null || die "no events: $(cat "$WORK/r4.json")"
pass "headless: turn.failed, a non-zero exit or no completed turn is is_error"

echo "3. fail closed"
for mode in fail noseatbelt noproxy open readable noexec rootopen; do
  for m in interactive headless; do
    reset; export STUB_SANDBOX=$mode
    rc=0; "$A" "$P" "$m" - "$WORK/system.md" "x" "$WORK/f.json" > "$WORK/out" 2>&1 || rc=$?
    [ "$rc" = 3 ] || die "$mode/$m: expected exit 3, got $rc: $(cat "$WORK/out")"
    grep -q 'could not be confirmed, refusing to start' "$WORK/out" || die "$mode/$m message: $(cat "$WORK/out")"
    [ "$(n_calls interactive)" = 0 ] && [ "$(n_calls exec)" = 0 ] || die "$mode/$m: no session may start"
  done
done
reset; export STUB_SANDBOX=noexec
"$A" "$P" headless - "$WORK/system.md" x "$WORK/f.json" 2>&1 | grep -q 'the codex binary can not run inside the profile' || die "noexec: the reason is named"
reset; export STUB_SANDBOX=rootopen
"$A" "$P" headless - "$WORK/system.md" x "$WORK/f.json" 2>&1 | grep -q 'the rest of the toolchain cache root is readable' || die "rootopen: the reason is named"
reset; export STUB_SANDBOX=noproxy
"$A" "$P" headless - "$WORK/system.md" x "$WORK/f.json" 2>&1 | grep -q 'no network proxy' || die "the reason is named"
# The caller's own loopback proxy (Proxyman, mitmproxy, ...) must not stand in for Codex's:
# a copy of the adapter without --enable network_proxy, run with HTTPS_PROXY / HTTP_PROXY /
# CODEX_NETWORK_PROXY_ACTIVE exported, must refuse; with the flag, the session sees no
# proxy variable of the caller.
cp -R "$TOOLKIT_DIR/lean" "$WORK/lean-noproxy"
sed -i.bak 's/^common=(--enable network_proxy$/common=(/' "$WORK/lean-noproxy/adapters/codex.sh"
grep -q '^common=($' "$WORK/lean-noproxy/adapters/codex.sh" || die "test setup: the network_proxy flag was not removed"
for m in interactive headless check; do
  reset; rc=0
  HTTPS_PROXY=http://127.0.0.1:8888 HTTP_PROXY=http://127.0.0.1:8888 https_proxy=http://127.0.0.1:8888 \
    ALL_PROXY=socks5h://127.0.0.1:8888 CODEX_NETWORK_PROXY_ACTIVE=1 \
    "$WORK/lean-noproxy/adapters/codex.sh" "$P" "$m" - "$WORK/system.md" x "$WORK/f.json" > "$WORK/out" 2>&1 || rc=$?
  [ "$rc" = 3 ] && grep -q 'no network proxy' "$WORK/out" || die "inherited proxy/$m: expected exit 3 (no network proxy), got $rc: $(cat "$WORK/out")"
  [ "$(n_calls interactive)" = 0 ] && [ "$(n_calls exec)" = 0 ] || die "inherited proxy/$m: no session may start"
done
reset
HTTPS_PROXY=http://127.0.0.1:8888 no_proxy=x NPM_CONFIG_PROXY=http://u:p@127.0.0.1:8888 CODEX_SANDBOX=seatbelt \
  "$A" "$P" headless - "$WORK/system.md" x "$WORK/f.json" > "$WORK/out" 2>&1 || die "with the caller's proxy: $(cat "$WORK/out")"
for k in sandbox exec; do
  env_of $k | grep -iE '^[^=]*proxy=|^CODEX_(SANDBOX|NETWORK_)' && die "$k: a proxy variable or Codex marker of the caller reached codex"
done
# The prompt probe fails closed: Codex can't open a session with the profile (AGENTS.md denied
# to its loader, as codex-cli 0.167 without project_doc_max_bytes=0), or it loads AGENTS.md.
cp -R "$TOOLKIT_DIR/lean" "$WORK/lean-agentsmd"
sed -i.bak "/^  -c 'project_doc_max_bytes=0'$/d" "$WORK/lean-agentsmd/adapters/codex.sh"
grep -q "^  -c 'project_doc_max_bytes=0'" "$WORK/lean-agentsmd/adapters/codex.sh" && die "test setup: project_doc_max_bytes=0 was not removed"
for m in interactive headless check; do
  for how in strip fail agents; do
    reset; rc=0; a="$A"
    case "$how" in strip) a="$WORK/lean-agentsmd/adapters/codex.sh" ;; *) export STUB_DEBUG=$how ;; esac
    "$a" "$P" "$m" - "$WORK/system.md" x "$WORK/f.json" > "$WORK/out" 2>&1 || rc=$?
    [ "$rc" = 3 ] || die "AGENTS.md probe $how/$m: expected exit 3, got $rc: $(cat "$WORK/out")"
    case "$how" in
      agents) grep -q 'would load AGENTS.md instructions into the session' "$WORK/out" ;;
      *) grep -q "can't open a session with the lean profile, refusing to start: .*failed to load AGENTS.md" "$WORK/out" ;;
    esac || die "AGENTS.md probe $how/$m message: $(cat "$WORK/out")"
    [ "$(n_calls interactive)" = 0 ] && [ "$(n_calls exec)" = 0 ] || die "AGENTS.md probe $how/$m: no session may start"
  done
done
reset
"$A" "$P" check - "$WORK/system.md" - > "$WORK/out" 2>&1 || die "check mode: $(cat "$WORK/out")"
grep -q 'Codex sandbox confirmed' "$WORK/out" && [ "$(n_calls interactive)" = 0 ] && [ "$(n_calls exec)" = 0 ] || die "check runs no session"
pass "fail closed: a session Codex can't open with the profile, or AGENTS.md in the probed prompt -> exit 3, no session"
pass "fail closed: sandbox can't apply, no seatbelt, codex binary not runnable, no proxy (also with the caller's own loopback proxy), an outside write or read going through, the cache root listable -> exit 3, no session"

echo "3b. codex behind a symlink chain under ~/.codex"
REL="$HOME/.codex/packages/standalone/releases/9.9.9-test"
mkdir -p "$REL/bin" "$REL/codex-path" "$HOME/.local/bin" "$HOME/.codex/sessions"
cp "$WORK/bin/codex" "$REL/bin/codex"
ln -s releases/9.9.9-test "$HOME/.codex/packages/standalone/current"
ln -s "$HOME/.codex/packages/standalone/current/bin/codex" "$HOME/.local/bin/codex"
echo '{"token":"fake"}' > "$HOME/.codex/auth.json"; echo 'model = "x"' > "$HOME/.codex/config.toml"
reset
PATH="$HOME/.local/bin:$PATH" "$A" "$P" interactive - "$WORK/system.md" x > "$WORK/out" 2>&1 || die "codex behind links: $(cat "$WORK/out")"
fs=$(fs_table interactive)
for kv in "\"$REL\"=\"read\"" "\"$HOME/.codex\"=\"deny\""; do
  case "$fs" in *"$kv"*) ;; *) die "filesystem table lacks $kv: $fs" ;; esac
done
# Nothing readable or writable covers auth.json or config.toml: only the release folder opens.
opened=$(printf '%s' "$fs" | sed 's/"="/":"/g' | jq -r --arg h "$HOME/.codex" \
  'to_entries[] | select(.value != "deny") | .key as $k | select($k == $h or ($h | startswith($k + "/")) or ($k | startswith($h + "/"))) | $k')
[ "$opened" = "$REL" ] || die "only the release folder may open under ~/.codex: $opened"
[ "$(cat "$(ls "$CALLS"/*.interactive.self)")" = "$REL/bin/codex" ] || die "the session starts the resolved binary: $(cat "$CALLS"/*.interactive.self)"
case "$(cat "$CALLS/version.codex_home" 2>/dev/null)" in */lean-session.*/codex-home) ;;
  *) die "the check runs codex --version with a temp CODEX_HOME: $(cat "$CALLS/version.codex_home" 2>/dev/null)" ;; esac
grep -q 'denied-home' "$(ls "$CALLS"/*.sandbox.argv)" 2>/dev/null && die "test setup: the stub records argv before the stand-in"
[ -d "$CALLS/denied-home" ] || die "the check must be handed the denied Codex home to prove it unreadable"
pass "codex behind links: release folder read, ~/.codex denied, resolved binary started, --version with a temp CODEX_HOME"
# A binary directly in the Codex home: no release folder under packages/ to open, so it can't
# run inside the profile and the check refuses (the home itself is never opened).
mkdir -p "$HOME/.codex/bin" "$WORK/bin-home"
cp "$WORK/bin/codex" "$HOME/.codex/bin/codex"
ln -s "$HOME/.codex/bin/codex" "$WORK/bin-home/codex"
for m in interactive headless; do
  reset; rc=0
  PATH="$WORK/bin-home:$PATH" "$A" "$P" "$m" - "$WORK/system.md" x "$WORK/f.json" > "$WORK/out" 2>&1 || rc=$?
  [ "$rc" = 3 ] && grep -q "the codex binary can not run inside the profile: $HOME/.codex/bin/codex" "$WORK/out" \
    || die "binary in the Codex home/$m: expected exit 3, got $rc: $(cat "$WORK/out")"
  [ "$(n_calls interactive)" = 0 ] && [ "$(n_calls exec)" = 0 ] || die "binary in the Codex home/$m: no session may start"
  fs_table sandbox | grep -q "\"$HOME/.codex[^\"]*\"=\"\(read\|write\)\"" && die "binary in the Codex home/$m: nothing under ~/.codex opens"
done
rm -rf "$HOME/.codex" "$HOME/.local" "$WORK/bin-home"
pass "fail closed: a codex binary the profile can't run (in the Codex home itself) -> exit 3, ~/.codex never opened"

echo "4. environment"
reset
jq '.lean.env_passthrough = ["KEEP_ME_TOKEN"]' "$P/.harness.json" > "$WORK/h" && mv "$WORK/h" "$P/.harness.json"
FAKE_API_TOKEN=s1 DATABASE_URL=postgres://u:p@h/db KEEP_ME_TOKEN=k OPENAI_API_KEY=sk-x AWS_SECRET_ACCESS_KEY=s2 PLAIN_VAR=y \
  "$A" "$P" headless - "$WORK/system.md" x "$WORK/e.json" >/dev/null 2>&1 || die "env run"
for k in sandbox exec; do
  e=$(env_of $k)
  for v in FAKE_API_TOKEN DATABASE_URL AWS_SECRET_ACCESS_KEY; do
    printf '%s\n' "$e" | grep -q "^$v=" && die "$k: $v must be dropped"
  done
  printf '%s\n' "$e" | grep -qx 'KEEP_ME_TOKEN=k' || die "$k: env_passthrough keeps KEEP_ME_TOKEN"
  printf '%s\n' "$e" | grep -qx 'OPENAI_API_KEY=sk-x' || die "$k: Codex keeps its own OPENAI_API_KEY"
  printf '%s\n' "$e" | grep -qx 'PLAIN_VAR=y' || die "$k: ordinary variables stay"
  printf '%s\n' "$e" | grep -qx 'GIT_CONFIG_GLOBAL=/dev/null' || die "$k: GIT_CONFIG_GLOBAL"
done
has exec 'shell_environment_policy.exclude=["OPENAI_*","CODEX_API_KEY"]' || die "the commands lose OPENAI_* / CODEX_API_KEY"
argv_of exec | grep -q '^shell_environment_policy\.set\.TMPDIR="/.*/lean-session\.[^/]*/"$' || die "the commands' TMPDIR is the session folder"
pass "environment: secrets dropped, passthrough kept, OPENAI_* kept for Codex but excluded from commands"
# The session marker and LEAN_GATE_UNSANDBOXED (exported for this whole test): the marker is set
# for codex and its commands, the bypass never reaches either. codex exec has no turn cap.
reset
LEAN_MAX_TURNS=40 "$A" "$P" headless - "$WORK/system.md" x "$WORK/e.json" >/dev/null 2>&1 || die "marker run"
e=$(env_of exec)
printf '%s\n' "$e" | grep -q '^LEAN_GATE_UNSANDBOXED=' && die "LEAN_GATE_UNSANDBOXED must not reach a codex session"
printf '%s\n' "$e" | grep -qx 'LEAN_SESSION=1' || die "codex gets LEAN_SESSION=1"
has exec 'shell_environment_policy.set.LEAN_SESSION="1"' || die "the commands get LEAN_SESSION=1"
argv_of exec | grep -q -- '--max-turns' && die "codex exec has no --max-turns: $(argv_of exec | tr '\n' ' ')"
pass "environment: LEAN_SESSION=1 set, LEAN_GATE_UNSANDBOXED dropped, no turn cap flag for codex"

echo "5. run.sh roles"
P="$WORK/p2"; new_project "$P" codex:gpt-impl codex:gpt-impl
reset
(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" implement f --headless) > "$WORK/out" 2>&1 || die "run.sh implement with codex:<model>: $(cat "$WORK/out")"
has exec gpt-impl && has exec -m || die "codex:<model> passes -m <model>: $(argv_of exec | head -5)"
res=$(sed -n 's/^\[lean\] result: //p' "$WORK/out")
jq -e '.tool == "codex" and .is_error == false' "$res" >/dev/null || die "run.sh result: $res"
# The usage row from codex.sh's result JSON (canned events: input 1200 of which 500 cached).
urow=$(tail -1 "$(bash -c '. "$1/lean/lib.sh"; lean_usage_file "$2" f' _ "$TOOLKIT_DIR" "$P")" | cut -f3-)
case "$urow" in "$(printf 'implement\tnormal\tcodex\tgpt-impl\t3\t700\t500\t3\t70\t')"[0-9]*"$(printf '\t-\t')") ;;
  *) die "usage row from codex.sh's result: $urow" ;; esac
grep -q 'Implement the feature documented in docs/features/f.md' "$(ls "$CALLS"/*.exec.argv)" || die "the step prompt reaches codex"
pass "run.sh: implementer codex:<model> -> codex.sh headless with -m"

(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" freeze f) > "$WORK/out" 2>&1 || die "freeze: $(cat "$WORK/out")"
reset
(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" review f --headless) > "$WORK/out" 2>&1 && die "risk: same codex model in both roles must be refused"
grep -q 'risk mode: the reviewer must be another model than the implementer (codex:gpt-impl)' "$WORK/out" || die "same model message: $(cat "$WORK/out")"
[ "$(n_calls exec)" = 0 ] || die "no session when refused"
jq '.lean.implementer = "claude:some-model" | .lean.reviewer = "codex"' "$P/.harness.json" > "$WORK/h" && mv "$WORK/h" "$P/.harness.json"
rm -f "$(bash -c '. "$1/lean/lib.sh"; lean_state_dir "$2"' _ "$TOOLKIT_DIR" "$P")/lean/f/trusted.sha"
STUB_EXEC_SCRIPT='printf "ok\nVERDICT: approve\n" > docs/features/f.review.md' \
  bash -c 'cd "$1" && bash "$2/lean/run.sh" review f --headless' _ "$P" "$TOOLKIT_DIR" > "$WORK/out" 2>&1 || die "risk review on codex: $(cat "$WORK/out")"
has exec -m && die "plain codex passes no -m"
grep -q '\[lean\] verdict: approve' "$WORK/out" || die "risk review verdict: $(cat "$WORK/out")"
jq '.lean.implementer = "codex" | .lean.reviewer = "codex"' "$P/.harness.json" > "$WORK/h" && mv "$WORK/h" "$P/.harness.json"
rm -f "$(bash -c '. "$1/lean/lib.sh"; lean_state_dir "$2"' _ "$TOOLKIT_DIR" "$P")/lean/f/trusted.sha"
(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" review f --headless) > "$WORK/out" 2>&1 && die "risk: codex in both roles must be refused"
grep -q 'reviewer must be another model' "$WORK/out" || die "codex/codex message: $(cat "$WORK/out")"
jq '.lean.implementer = "codex:" ' "$P/.harness.json" > "$WORK/h" && mv "$WORK/h" "$P/.harness.json"
rm -f "$(bash -c '. "$1/lean/lib.sh"; lean_state_dir "$2"' _ "$TOOLKIT_DIR" "$P")/lean/f/trusted.sha"
(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" implement f --headless) > "$WORK/out" 2>&1 && die "codex: with no model must be refused"
grep -q 'unknown tool: codex:' "$WORK/out" || die "unknown tool message: $(cat "$WORK/out")"
pass "run.sh: reviewer codex (no -m) in risk mode; same tool in both roles refused across tools; 'codex:' refused"

echo "6. chain with a codex implementer"
# No lean.reviewer: the normal review opens on the implementer's tool (codex).
P="$WORK/p3"; new_project "$P" codex claude:other
jq 'del(.lean.reviewer)' "$P/.harness.json" > "$WORK/h" && mv "$WORK/h" "$P/.harness.json"
reset
export STUB_EXEC_SCRIPT='grep -q todo src/app.txt && printf "done\n" > src/app.txt; true'
(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" chain f) > "$WORK/out" 2>&1 || die "chain with codex: $(cat "$WORK/out")"
[ "$(tail -1 "$WORK/out")" = "CHAIN: PASS" ] || die "chain last line: $(cat "$WORK/out")"
grep -q '^implement ok .* turns=3$' "$WORK/out" && grep -q '^review    ok .* turns=3$' "$WORK/out" || die "step lines with turns, no cost: $(cat "$WORK/out")"
grep -q '^total: .*cost' "$WORK/out" && die "no cost total when Codex reports none: $(cat "$WORK/out")"
[ "$(n_calls exec)" = 2 ] || die "implement and review ran on codex: $(ls "$CALLS")"
pass "chain: codex implementer, implement -> review -> gate, CHAIN: PASS"

echo "7. codex-m3"
M3="$TOOLKIT_DIR/lean/adapters/codex-m3.sh"
P="$WORK/p4"; new_project "$P" codex-m3 claude:other
printf '# orchestrator instructions\n' > "$P/AGENTS.md"; g -C "$P" add AGENTS.md && g -C "$P" commit -qm agents || die "project setup: AGENTS.md"
# first2 <kind> — the first two arguments after the subcommand (interactive: the first two).
first2() { argv_of "$1" | if [ "$1" = interactive ]; then cat; else sed 1d; fi | head -2 | tr '\n' ' '; }
reset
"$M3" "$P" interactive some-model "$WORK/system.md" "Implement docs/features/f.md" > "$WORK/out" 2>&1 || die "codex-m3 interactive: $(cat "$WORK/out")"
grep -q 'real CLI called' "$WORK/out" && die "codex-m3 must not go through fish: $(cat "$WORK/out")"
[ "$(n_calls sandbox)" = 1 ] && [ "$(n_calls debug)" = 1 ] && [ "$(n_calls interactive)" = 1 ] || die "check, probe, session: $(ls "$CALLS")"
[ "$(first2 interactive)" = "--profile minimax " ] || die "the session starts with --profile minimax: $(first2 interactive)"
[ "$(first2 sandbox)" = "--profile minimax " ] || die "the sandbox check layers the profile too: $(first2 sandbox)"
has debug --profile && die "the prompt probe runs without the profile (temp CODEX_HOME): $(argv_of debug | head -3)"
case "$(cat "$CALLS/debug.codex_home")" in */lean-session.*/codex-probe-home) ;; *) die "probe CODEX_HOME: $(cat "$CALLS/debug.codex_home")" ;; esac
env_of debug | grep -qx 'OPENAI_API_KEY=' || die "the probe carries no API key"
has interactive -m && die "codex-m3 ignores the model argument: $(argv_of interactive | tr '\n' ' ')"
[ "$(cat "$(ls "$CALLS"/*.interactive.self)")" = "$WORK/bin/codex" ] || die "the session starts the resolved binary: $(cat "$CALLS"/*.interactive.self)"
for a in --enable network_proxy 'default_permissions="lean"' 'permissions.lean.extends=":read-only"' 'approval_policy="never"' \
         'approvals_reviewer="user"' 'project_doc_max_bytes=0' 'project_doc_fallback_filenames=[]' \
         'shell_environment_policy.exclude=["OPENAI_*","CODEX_API_KEY"]' 'shell_environment_policy.set.LEAN_SESSION="1"' -C "$P"; do
  has interactive "$a" || die "codex-m3 interactive argv lacks $a"
done
no_bypass interactive; no_bypass sandbox
[ "$(sandbox_flags sandbox)" = "$(sandbox_flags interactive)" ] && [ "$(sandbox_flags debug)" = "$(sandbox_flags interactive)" ] \
  || die "codex-m3: check and probe use the session's flags"
fs=$(fs_table interactive)
for kv in "\"$P\"=\"write\"" "\"$P/.git\"=\"read\"" "\"$HOME/Documents\"=\"deny\"" "\"$P/**/AGENTS.md\"=\"deny\"" "\"$P/**/.codex/**\"=\"deny\""; do
  case "$fs" in *"$kv"*) ;; *) die "codex-m3 filesystem table lacks $kv: $fs" ;; esac
done
pass "codex-m3 interactive: resolved codex with --profile minimax (session and check), not fish, no -m; profile, deny globs, no AGENTS.md, probe without the profile"

reset
FAKE_API_TOKEN=s1 KEEP_ME_TOKEN=k LEAN_CODEX_M3_PROFILE=mm-2 "$M3" "$P" headless gpt-x "$WORK/system.md" x "$WORK/m.json" > "$WORK/out" 2>&1 || die "codex-m3 headless: $(cat "$WORK/out")"
[ "$(first2 exec)" = "--profile mm-2 " ] && [ "$(first2 sandbox)" = "--profile mm-2 " ] || die "LEAN_CODEX_M3_PROFILE names the profile: $(first2 exec)"
for a in --json --ignore-rules 'approval_policy="never"'; do has exec "$a" || die "codex-m3 exec argv lacks $a"; done
has exec -m && die "codex-m3 exec: no -m"
e=$(env_of exec)
printf '%s\n' "$e" | grep -q '^FAKE_API_TOKEN=' && die "codex-m3: secrets dropped"
printf '%s\n' "$e" | grep -q '^LEAN_GATE_UNSANDBOXED=' && die "codex-m3: LEAN_GATE_UNSANDBOXED dropped"
printf '%s\n' "$e" | grep -qx 'LEAN_SESSION=1' || die "codex-m3: LEAN_SESSION=1"
jq -e '.tool == "codex-m3" and .model == "mm-2" and .total_cost_usd == null and .usage.input_tokens == 1200' "$WORK/m.json" >/dev/null \
  || die "codex-m3 result JSON (no model in the events: the profile name): $(cat "$WORK/m.json")"
reset; export STUB_EVENTS='{"type":"thread.started","thread_id":"t","model":"MiniMax-M3"}
{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":2}}'
"$M3" "$P" headless - "$WORK/system.md" x "$WORK/m2.json" >/dev/null 2>&1 || die "codex-m3 headless with a model event"
jq -e '.tool == "codex-m3" and .model == "MiniMax-M3"' "$WORK/m2.json" >/dev/null || die "the model Codex reports: $(cat "$WORK/m2.json")"
reset
rc=0; LEAN_CODEX_M3_PROFILE='x y' "$M3" "$P" headless - "$WORK/system.md" x "$WORK/m3.json" > "$WORK/out" 2>&1 || rc=$?
[ "$rc" = 2 ] && grep -q 'LEAN_CODEX_M3_PROFILE must be a Codex profile name' "$WORK/out" && [ "$(ls "$CALLS" | wc -l | tr -d ' ')" = 0 ] \
  || die "an invalid profile name is refused before any codex call: rc=$rc $(cat "$WORK/out")"
pass "codex-m3 headless: --profile on exec and check, env rules kept, result tool codex-m3, model reported else the profile, no cost"

usage_rows() { tail -n +2 "$(bash -c '. "$1/lean/lib.sh"; lean_usage_file "$2" f' _ "$TOOLKIT_DIR" "$1")" | cut -f3-7,13; }
reset
(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" implement f --headless) > "$WORK/out" 2>&1 || die "run.sh implement with codex-m3: $(cat "$WORK/out")"
[ "$(first2 exec)" = "--profile minimax " ] || die "run.sh codex-m3 -> the profile: $(first2 exec)"
[ "$(usage_rows "$P" | tail -1)" = "$(printf 'implement\tnormal\tcodex-m3\tminimax\t3\t-')" ] || die "usage row: $(usage_rows "$P" | tail -1)"
# Interactive: no result JSON, the row still names codex-m3 / minimax.
reset
(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" implement f) > "$WORK/out" 2>&1 || die "run.sh interactive codex-m3: $(cat "$WORK/out")"
[ "$(usage_rows "$P" | tail -1)" = "$(printf 'implement\tnormal\tcodex-m3\tminimax\t-\t-')" ] || die "interactive usage row: $(usage_rows "$P" | tail -1)"
# Per-mode object: the normal review on codex-m3, the implementer on claude (its stub must not run).
P="$WORK/p5"; new_project "$P" claude:impl codex-m3
jq '.lean.reviewer = {normal: "codex-m3", risk: "claude:other"}' "$P/.harness.json" > "$WORK/h" && mv "$WORK/h" "$P/.harness.json"
reset
(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" review f --headless) > "$WORK/out" 2>&1 || die "normal review on codex-m3: $(cat "$WORK/out")"
[ "$(n_calls exec)" = 1 ] && [ "$(first2 exec)" = "--profile minimax " ] || die "per-mode reviewer codex-m3: $(ls "$CALLS")"
[ "$(usage_rows "$P" | tail -1 | cut -f1-3)" = "$(printf 'review\tnormal\tcodex-m3')" ] || die "review usage row: $(usage_rows "$P")"
pass "run.sh: codex-m3 as implementer (string) and as the normal reviewer (per mode); usage rows codex-m3 / minimax, cost -"

# Risk mode: codex-m3 in both roles, or next to claude-mini (both MiniMax), is refused before any session.
P="$WORK/p6"; new_project "$P" codex-m3 codex-m3
(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" freeze f) > "$WORK/out" 2>&1 || die "freeze: $(cat "$WORK/out")"
st6="$(bash -c '. "$1/lean/lib.sh"; lean_state_dir "$2"' _ "$TOOLKIT_DIR" "$P")/lean/f/trusted.sha"
for pair in 'codex-m3 codex-m3' 'codex-m3 {"risk":"codex-m3"}' 'claude-mini codex-m3' 'codex-m3 claude-mini'; do
  read -r i r <<<"$pair"
  jq --arg i "$i" --argjson r "$(jq -R 'fromjson? // .' <<<"$r")" '.lean.implementer = $i | .lean.reviewer = $r' "$P/.harness.json" > "$WORK/h" && mv "$WORK/h" "$P/.harness.json"
  rm -f "$st6"; reset
  (cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" review f --headless) > "$WORK/out" 2>&1 && die "risk: $pair must be refused"
  grep -q 'risk mode: the reviewer must be another model than the implementer' "$WORK/out" || die "risk $pair message: $(cat "$WORK/out")"
  [ "$(n_calls exec)" = 0 ] && [ "$(n_calls sandbox)" = 0 ] || die "risk $pair: no session"
done
grep -q 'both run MiniMax' "$WORK/out" || die "the MiniMax pair is named: $(cat "$WORK/out")"
jq '.lean.implementer = "codex-m3" | .lean.reviewer = "codex"' "$P/.harness.json" > "$WORK/h" && mv "$WORK/h" "$P/.harness.json"
rm -f "$st6"; reset
STUB_EXEC_SCRIPT='printf "ok\nVERDICT: approve\n" > docs/features/f.review.md' \
  bash -c 'cd "$1" && bash "$2/lean/run.sh" review f --headless' _ "$P" "$TOOLKIT_DIR" > "$WORK/out" 2>&1 || die "risk: codex reviewing codex-m3: $(cat "$WORK/out")"
has exec --profile && die "the plain codex reviewer runs without the MiniMax profile"
jq '.lean.implementer = "codex-m3:big"' "$P/.harness.json" > "$WORK/h" && mv "$WORK/h" "$P/.harness.json"
rm -f "$st6"; reset
(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" implement f --headless) > "$WORK/out" 2>&1 && die "codex-m3:<model> must be refused"
grep -q 'unknown tool: codex-m3:big' "$WORK/out" || die "codex-m3:<model> message: $(cat "$WORK/out")"
pass "risk mode: codex-m3 in both roles (string or per mode) and next to claude-mini refused; plain codex may review it; codex-m3:<model> unknown"

echo "all $PASS checks passed"
