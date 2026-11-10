#!/usr/bin/env bash
# lean_codex_adapter_test.sh — lean/adapters/codex.sh and the `codex` roles in lean/run.sh,
# against a STUB `codex` on PATH (it records its argv and environment and emits canned
# output; no model is ever called, no real sandbox runs).
#
#   1. interactive argv: the permission profile, the network proxy, approvals by the user, the
#      system prompt as developer_instructions, the model; no bypass flag; the profile's
#      filesystem table (project writable, harness-owned files and .git read-only, $HOME
#      entries and the lean state denied, instruction files denied by glob, no /tmp).
#   2. headless: `codex exec --json`, approvals never, --ignore-rules; the result JSON
#      (tokens summed over turns, num_turns, session_id, duration, total_cost_usd null);
#      a failed turn or a non-zero exit is is_error; a junk line is skipped.
#   3. fail closed: the self-check failing (sandbox can't apply, no seatbelt, no network
#      proxy, a caller's own loopback proxy standing in for Codex's, a write or read of the
#      lean state that goes through) refuses before any session (exit 3); the caller's proxy
#      variables never reach codex.
#   4. environment: secret-looking variables dropped, lean.env_passthrough kept, OPENAI_*
#      kept for Codex but excluded from the commands.
#   5. run.sh: `codex` / `codex:<model>` for implementer and reviewer; risk mode still refuses
#      the same tool in both roles; an unknown tool is refused.
#   6. chain with a codex implementer (no lean.reviewer: it reviews too): CHAIN: PASS, turns on
#      the step line, no cost.
#
# Usage: bash tests/lean_codex_adapter_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }
g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

mkdir -p "$WORK/home/Documents" "$WORK/bin"
echo private > "$WORK/home/Documents/p.txt"
export HOME="$WORK/home" LEAN_GATE_UNSANDBOXED=1 GIT_CONFIG_GLOBAL=/dev/null
export LEAN_CLAUDE_TMP="$WORK/no-claude-tmp"
export CALLS="$WORK/calls"
A="$TOOLKIT_DIR/lean/adapters/codex.sh"

# The stub: each call gets $CALLS/<n>.<kind>.argv (NUL-separated) and .env (env -0).
# sandbox: runs the self-check script as the real one would see it (CODEX_SANDBOX=seatbelt,
# the canary folder unreadable and unwritable; with --enable network_proxy, Codex's proxy:
# HTTP(S)_PROXY on loopback and CODEX_NETWORK_PROXY_ACTIVE=1; without it the caller's
# environment passes through unchanged, as the real codex does), unless STUB_SANDBOX says
# otherwise: fail (exit 71 like sandbox-exec), noseatbelt, noproxy (the proxy feature not
# taking effect), open (canary left writable), readable (canary readable, not writable). exec: prints $STUB_EVENTS (default: canned events), writes the -o file, runs
# $STUB_EXEC_SCRIPT in the current dir, exits $STUB_EXEC_RC. Otherwise (interactive): exit 0.
cat > "$WORK/bin/codex" <<'SH'
#!/usr/bin/env bash
mkdir -p "$CALLS"
n=$(ls "$CALLS" | grep -c '\.argv$')
kind=interactive
case "${1:-}" in sandbox) kind=sandbox ;; exec) kind=exec ;; esac
printf '%s\0' "$@" > "$CALLS/$n.$kind.argv"
env -0 > "$CALLS/$n.$kind.env"
case "$kind" in
  sandbox)
    [ "${STUB_SANDBOX:-}" != fail ] || { echo "sandbox-exec: sandbox_apply: Operation not permitted" >&2; exit 71; }
    proxy=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
      [ "$1 ${2:-}" != "--enable network_proxy" ] || [ "${STUB_SANDBOX:-}" = noproxy ] \
        || proxy=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 CODEX_NETWORK_PROXY_ACTIVE=1)
      shift
    done; shift
    # "$@" = /bin/sh -c <script> sh <canary> <session tmp>
    canary="$5"
    case "${STUB_SANDBOX:-}" in open) ;; readable) chmod 555 "$canary" ;; *) chmod 000 "$canary" ;; esac
    seat=seatbelt
    [ "${STUB_SANDBOX:-}" != noseatbelt ] || seat=""
    rc=0; env CODEX_SANDBOX="$seat" ${proxy[@]+"${proxy[@]}"} "$@" || rc=$?
    chmod 700 "$canary"
    exit "$rc" ;;
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

reset() { rm -rf "$CALLS"; mkdir -p "$CALLS"; unset STUB_SANDBOX STUB_EVENTS STUB_EXEC_RC STUB_EXEC_SCRIPT; }
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
for mode in fail noseatbelt noproxy open readable; do
  for m in interactive headless; do
    reset; export STUB_SANDBOX=$mode
    rc=0; "$A" "$P" "$m" - "$WORK/system.md" "x" "$WORK/f.json" > "$WORK/out" 2>&1 || rc=$?
    [ "$rc" = 3 ] || die "$mode/$m: expected exit 3, got $rc: $(cat "$WORK/out")"
    grep -q 'could not be confirmed, refusing to start' "$WORK/out" || die "$mode/$m message: $(cat "$WORK/out")"
    [ "$(n_calls interactive)" = 0 ] && [ "$(n_calls exec)" = 0 ] || die "$mode/$m: no session may start"
  done
done
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
reset
"$A" "$P" check - "$WORK/system.md" - > "$WORK/out" 2>&1 || die "check mode: $(cat "$WORK/out")"
grep -q 'Codex sandbox confirmed' "$WORK/out" && [ "$(n_calls interactive)" = 0 ] && [ "$(n_calls exec)" = 0 ] || die "check runs no session"
pass "fail closed: sandbox can't apply, no seatbelt, no proxy (also with the caller's own loopback proxy), an outside write or read going through -> exit 3, no session"

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

echo "5. run.sh roles"
P="$WORK/p2"; new_project "$P" codex:gpt-impl codex:gpt-impl
reset
(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" implement f --headless) > "$WORK/out" 2>&1 || die "run.sh implement with codex:<model>: $(cat "$WORK/out")"
has exec gpt-impl && has exec -m || die "codex:<model> passes -m <model>: $(argv_of exec | head -5)"
res=$(sed -n 's/^\[lean\] result: //p' "$WORK/out")
jq -e '.tool == "codex" and .is_error == false' "$res" >/dev/null || die "run.sh result: $res"
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

echo "all $PASS checks passed"
