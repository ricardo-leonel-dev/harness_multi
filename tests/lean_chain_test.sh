#!/usr/bin/env bash
# lean_chain_test.sh — lean/run.sh chain against a throwaway project, with a stub adapter in
# place of claude (no model is ever called) and the suite run unsandboxed
# (LEAN_GATE_UNSANDBOXED=1).
#
#   1. normal mode: implement -> review -> gate, CHAIN: PASS, exit 0, no fix; a failed gate
#      gets one fix round and a second gate; a fix that doesn't help stops at the gate (fix
#      ran once); the output stays short (gate headings, not the suite's lines).
#   2. the first failing step stops the chain: is_error, a missing result JSON.
#   3. risk mode: freeze -> implement -> review -> gate; verdict `changes` -> fix -> gate; no
#      VERDICT line, a review that changed files, or a reviewer that is the implementer,
#      stops at review.
#   4. with scripts/harness.sh: a risk feature without its manifest and a plan awaiting
#      approval are refused before any step; each step is append-logged; a PASS prints a
#      `next:` log-out --lean line (the gate's files, shell-quoted) right before CHAIN: PASS,
#      never without the harness or on FAIL.
#   5. the per-step cap (lean.step_minutes, --step-minutes) kills the step's processes and
#      reports it.
#   6. a lean/chain.sh changed after the pin is refused before run.sh sources it.
#   7. who opens the review: normal mode uses lean.reviewer when set (any adapter, may fix,
#      even the implementer's tool), else the implementer; fix stays on the implementer; risk
#      mode without lean.reviewer uses its default; the object form {normal, risk} picks one
#      per mode (a missing key falls back, .risk = implementer is refused); any other type
#      exits 2 naming the key before a session opens.
#
# Usage: bash tests/lean_chain_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }
g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

mkdir -p "$WORK/home"
export HOME="$WORK/home" LEAN_GATE_UNSANDBOXED=1 GIT_CONFIG_GLOBAL=/dev/null
export LEAN_CLAUDE_TMP="$WORK/no-claude-tmp"
# The toolkit's lean/ with a stub adapter: it records the step (from the result file's name),
# runs $SCN/<step> in the project when present (it may set IS_ERROR / NO_RESULT), and writes
# a result JSON like claude -p's.
L="$WORK/lean"; cp -R "$TOOLKIT_DIR/lean" "$L"
# Every adapter (claude, claude-mini, codex) gets the stub; it also records "<step> <adapter>:<model>"
# in $TOOLS, so a test can tell which tool opened each session. The codex one writes
# total_cost_usd null, as the real adapter does.
export CALLS="$WORK/calls" SCN="$WORK/scn" TOOLS="$WORK/tools"
cat > "$L/adapters/claude.sh" <<'SH'
#!/usr/bin/env bash
project="$1" model="$3" result="${6:-}"
adapter=$(basename "$0" .sh)
st=$(basename "$result"); st="${st#*.}"; st="${st%%.*}"
echo "$st" >> "$CALLS"
echo "$st $adapter:$model" >> "$TOOLS"
cd "$project" || exit 1
IS_ERROR=false NO_RESULT=""
[ -f "$SCN/$st" ] && . "$SCN/$st"
cost=0.25; [ "$adapter" != codex ] || cost=null
[ -n "$NO_RESULT" ] || printf '{"is_error":%s,"num_turns":3,"total_cost_usd":%s}\n' "$IS_ERROR" "$cost" > "$result"
SH
chmod +x "$L/adapters/claude.sh"
cp "$L/adapters/claude.sh" "$L/adapters/claude-mini.sh"; cp "$L/adapters/claude.sh" "$L/adapters/codex.sh"

# new_project <dir> [harness] — a git repository whose suite passes once src/app.txt says done.
new_project() {
  local p="$1"
  mkdir -p "$p/src" "$p/tests" "$p/docs/features" "$p/acceptance"
  echo '{"verify_command":"bash run_tests.sh","lean":{"implementer":"claude","reviewer":"claude:other"}}' > "$p/.harness.json"
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
  if [ "${2:-}" = harness ]; then
    mkdir -p "$p/scripts"
    cat > "$p/scripts/harness.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  status) cat "$WORK/status.txt" 2>/dev/null ;;
  append-log) printf '%s\n' "\$2" >> "$WORK/applog" ;;
esac
exit 0
SH
  fi
  printf '.harness.json\nscripts/\n' > "$p/.gitignore"   # the user's config, as in a project
  g -C "$p" init -q && g -C "$p" add -A && g -C "$p" commit -qm base || die "project setup: $p"
}
scn() { mkdir -p "$SCN"; printf '%s\n' "$2" > "$SCN/$1"; }
reset() { rm -rf "$SCN" "$CALLS" "$TOOLS"; : > "$CALLS"; : > "$TOOLS"; }
tools() { tr '\n' ',' < "$TOOLS" | sed 's/,$//'; }
# lean_conf <project> <jq filter> — edit the project's .harness.json (before its first step: the
# pin covers it).
lean_conf() { jq "$2" "$1/.harness.json" > "$WORK/h" && mv "$WORK/h" "$1/.harness.json"; }
chain() { (cd "$P" && bash "$L/run.sh" chain f "$@") > "$WORK/out" 2>&1; }
out() { cat "$WORK/out"; }
calls() { tr '\n' ' ' < "$CALLS" | sed 's/ $//'; }
steps() { awk '$2 == "ok" || $2 == "fail" { printf "%s:%s ", $1, $2 }' "$WORK/out" | sed 's/ $//'; }

echo "1. normal mode"
P="$WORK/n1"; new_project "$P"
reset; scn implement 'printf "done\n" > src/app.txt'
chain || die "normal pass should exit 0: $(out)"
[ "$(steps)" = "implement:ok review:ok gate:ok" ] || die "normal order: $(steps) / $(out)"
[ "$(calls)" = "implement review" ] || die "normal sessions: $(calls)"
[ "$(tools)" = "implement claude:-,review claude:other" ] || die "normal review opens with lean.reviewer when set: $(tools)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: PASS" ] || die "last line: $(out)"
grep -q '^implement ok .* turns=3 cost=\$0.25' "$WORK/out" || die "step line with turns and cost: $(out)"
grep -q '^  ALL CHECKS PASS' "$WORK/out" && grep -q '^  full report: ' "$WORK/out" || die "gate summary: $(out)"
grep -q "M src/app.txt$" "$WORK/out" || die "git status: $(out)"
grep -q 'log-out' "$CALLS" && die "chain must not log out"
grep -q '^next:' "$WORK/out" && die "no next: line without scripts/harness.sh: $(out)"
pass "normal: implement -> review -> gate, CHAIN: PASS, exit 0"

g -C "$P" checkout -q -- src/app.txt
reset; scn fix 'printf "done\n" > src/app.txt'
chain || die "a fix that helps should pass: $(out)"
[ "$(steps)" = "implement:ok review:ok gate:fail fix:ok gate:ok" ] || die "fix round: $(steps) / $(out)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: PASS" ] || die "fix round last line: $(out)"
pass "normal: a failed gate gets one fix and a second gate"

g -C "$P" checkout -q -- src/app.txt
reset
chain && die "a fix that doesn't help must fail: $(out)"
[ "$(steps)" = "implement:ok review:ok gate:fail fix:ok gate:fail" ] || die "fix once: $(steps) / $(out)"
[ "$(grep -c '^fix$' "$CALLS")" = 1 ] || die "fix ran more than once: $(calls)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: FAIL at gate (gate failed)" ] || die "fail line: $(out)"
grep -q '^  SUITE FAILS:' "$WORK/out" || die "gate heading: $(out)"
grep -q 'app_test expects done' "$WORK/out" && die "the chain must not print the gate's full report: $(out)"
grep -q '^next:' "$WORK/out" && die "no next: line on FAIL: $(out)"
grep -q 'app_test expects done' "$(sed -n 's/^  full report: //p' "$WORK/out")" || die "the full report should be in the gate log"
[ "$(wc -l < "$WORK/out")" -le 20 ] || die "output should stay compact: $(out)"
pass "normal: fix runs at most once; the gate's report stays in its log (output $(wc -l < "$WORK/out" | tr -d ' ') lines)"

echo "2. the first failing step stops the chain"
reset; scn implement 'IS_ERROR=true'
chain && die "is_error must fail: $(out)"
[ "$(steps)" = "implement:fail" ] && [ "$(calls)" = implement ] || die "is_error stops: $(steps) / $(calls)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: FAIL at implement (the session reported is_error)" ] || die "is_error line: $(out)"
reset; scn review 'NO_RESULT=1'
chain && die "a missing result must fail: $(out)"
[ "$(steps)" = "implement:ok review:fail" ] || die "no result stops: $(steps) / $(out)"
tail -1 "$WORK/out" | grep -q '^CHAIN: FAIL at review (no result JSON from the session' || die "no result line: $(out)"
pass "is_error and a missing result JSON stop the chain at that step, exit non-zero"

echo "3. risk mode"
P="$WORK/r1"; new_project "$P"
(cd "$P" && bash "$L/run.sh" freeze f) > "$WORK/freeze.out" 2>&1 || die "freeze by hand: $(cat "$WORK/freeze.out")"
reset; scn implement 'printf "done\n" > src/app.txt'
scn review 'printf "fine\nVERDICT: approve\n" > docs/features/f.review.md'
chain || die "risk pass: $(out)"
[ "$(steps)" = "freeze:ok implement:ok review:ok gate:ok" ] || die "risk order: $(steps) / $(out)"
grep -q '^freeze .*(before implementing: 1 fail)' "$WORK/out" && grep -q '^review .*verdict=approve' "$WORK/out" || die "risk details: $(out)"
grep -q '^lean chain: f (risk mode' "$WORK/out" && [ "$(tail -1 "$WORK/out")" = "CHAIN: PASS" ] || die "risk header/last: $(out)"
[ "$(tools)" = "implement claude:-,review claude:other" ] || die "risk review opens with lean.reviewer: $(tools)"
pass "risk: freeze -> implement -> review -> gate"

g -C "$P" checkout -q -- src/app.txt
reset; scn review 'printf "no\nVERDICT: changes\n" > docs/features/f.review.md'; scn fix 'printf "done\n" > src/app.txt'
chain || die "risk changes then fix: $(out)"
[ "$(steps)" = "freeze:ok implement:ok review:ok fix:ok gate:ok" ] || die "risk changes order: $(steps) / $(out)"
g -C "$P" checkout -q -- src/app.txt
reset; scn review 'printf "no\nVERDICT: changes\n" > docs/features/f.review.md'
chain && die "risk: a fix after changes that still fails the gate must fail: $(out)"
[ "$(steps)" = "freeze:ok implement:ok review:ok fix:ok gate:fail" ] && [ "$(grep -c '^fix$' "$CALLS")" = 1 ] || die "risk fix once: $(steps) / $(calls)"
pass "risk: verdict changes -> fix -> gate, fix at most once"

reset; scn review 'printf "no verdict\n" > docs/features/f.review.md'
chain && die "risk without verdict must fail: $(out)"
[ "$(steps)" = "freeze:ok implement:ok review:fail" ] || die "no verdict: $(steps) / $(out)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: FAIL at review (no VERDICT line in docs/features/f.review.md)" ] || die "no verdict line: $(out)"
reset; scn review 'printf "fine\nVERDICT: approve\n" > docs/features/f.review.md; printf "done\n" > src/app.txt'
chain && die "risk: a review that changed files must fail: $(out)"
[ "$(steps)" = "freeze:ok implement:ok review:fail" ] && [ "$(calls)" = "implement review" ] || die "reviewer changed files: $(steps) / $(calls)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: FAIL at review (the reviewer changed files (it must only report))" ] || die "reviewer changed files line: $(out)"
g -C "$P" checkout -q -- src/app.txt
pass "risk: a review that changed files stops the chain at review, no fix or gate"

jq '.lean.reviewer = "claude"' "$P/.harness.json" > "$WORK/h" && mv "$WORK/h" "$P/.harness.json"
rm -f "$(bash -c '. "$1/lib.sh"; lean_state_dir "$2"' _ "$L" "$P")/lean/f/trusted.sha"   # the user's own edit
reset
chain && die "risk with reviewer = implementer must fail: $(out)"
[ "$(steps)" = "freeze:ok implement:ok review:fail" ] || die "same reviewer: $(steps) / $(out)"
tail -1 "$WORK/out" | grep -q '^CHAIN: FAIL at review (exit 2: risk mode: the reviewer must be another model' || die "same reviewer line: $(out)"
pass "risk: no VERDICT line, or a step refusing (exit 2), stops at review"

echo "4. with scripts/harness.sh"
P="$WORK/h1"; new_project "$P" harness
printf -- '--- lean mode (close with log-out --lean; lean/README.md) ---\nfeature_number  name  mode  plan\n--------------  ----  ----  ----\n1               f     risk  plan approved by u\n--- open session ---\n' > "$WORK/status.txt"
reset; : > "$WORK/applog"
chain && die "risk without a manifest must be refused: $(out)"
[ -z "$(steps)" ] && [ ! -s "$CALLS" ] || die "nothing should run: $(steps) / $(calls)"
tail -1 "$WORK/out" | grep -q '^CHAIN: FAIL at start (risk mode: no frozen manifest' || die "no manifest line: $(out)"
sed -i.bak 's/risk  plan approved by u/normal  plan approval pending/' "$WORK/status.txt"
chain && die "a plan awaiting approval must be refused: $(out)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: FAIL at start (the plan is not approved (approve-plan first))" ] || die "approval line: $(out)"
[ ! -s "$WORK/applog" ] || die "a refusal before any step logs nothing: $(cat "$WORK/applog")"
sed -i.bak 's/normal  plan approval pending/normal  no plan approval needed/' "$WORK/status.txt"
reset; scn implement 'printf "done\n" > src/app.txt'
chain || die "normal with the harness: $(out)"
grep -q '^lean chain: implement ok .* turns=3' "$WORK/applog" && grep -q '^lean chain: review ok' "$WORK/applog" \
  && grep -q '^lean chain: gate ok' "$WORK/applog" && grep -qx 'lean chain: PASS' "$WORK/applog" || die "append-log: $(cat "$WORK/applog")"
pass "risk without a manifest and a pending approval are refused before any step; each step is append-logged"

# On PASS with the harness: the log-out --lean line to run, before the last line, listing the
# files the gate checked (relative to the project, shell-quoted; progress/ and state/ left out).
# Names with a space or a quote only pass the gate under docs/features/ (its **Files** list
# holds plain paths), so the plan's notes there carry them.
g -C "$P" checkout -q -- src/app.txt
reset; scn implement 'printf "done\n" > src/app.txt; echo a > "docs/features/f notes.md"; echo b > "docs/features/f'"'"'s.md"; mkdir -p progress/f state; echo h > progress/f/impl.md; echo s > state/x.md'
chain || die "harness pass with more files: $(out)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: PASS" ] || die "CHAIN: PASS stays the last line: $(out)"
next=$(sed -n 's/^next: //p' "$WORK/out")
[ "$(tail -2 "$WORK/out" | head -1)" = "next: $next" ] || die "the next: line comes right before CHAIN: PASS: $(out)"
case "$next" in
  'scripts/harness.sh log-out --lean --changes '*' --verification "lean chain PASS: implement, review, gate ok, gate ALL CHECKS PASS" --closure "<fill in>"') ;;
  *) die "next: line shape: $next" ;;
esac
# Its --changes, read back the way the user's shell would, is exactly the gate's set.
got=$(eval "set -- ${next%% --verification*}"'; shift 3; for a; do [ "$a" = --changes ] || printf "%s\n" "$a"; done')
want=$(printf '%s\n' "docs/features/f notes.md" "docs/features/f's.md" src/app.txt)
[ "$got" = "$want" ] || die "next: --changes should be the gate's files, quoted: got [$got] from: $next"
grep -q 'progress/\|state/' <<<"$next" && die "progress/ and state/ stay out of --changes: $next"
rm -rf "$P/progress" "$P/state" "$P/docs/features/f notes.md" "$P/docs/features/f's.md"
pass "on PASS with the harness a next: line holds the log-out --lean command for the gate's files, quoted"

echo "5. per-step time cap"
g -C "$P" checkout -q -- src/app.txt
jq '.lean.step_minutes = 0.05' "$P/.harness.json" > "$WORK/h" && mv "$WORK/h" "$P/.harness.json"
rm -f "$(bash -c '. "$1/lib.sh"; lean_state_dir "$2"' _ "$L" "$P")/lean/f/trusted.sha"
reset; : > "$WORK/applog"; scn implement "echo \$\$ > '$WORK/stub.pid'; sleep 60 & echo \$! > '$WORK/sleep.pid'; wait"
SECONDS=0
chain && die "a step past its cap must fail: $(out)"
el=$SECONDS
[ "$el" -lt 20 ] || die "the cap should stop the step in about 3 s, took ${el}s"
[ "$(tail -1 "$WORK/out")" = "CHAIN: FAIL at implement (timed out after 0.05m)" ] || die "timeout line: $(out)"
[ "$(steps)" = "implement:fail" ] || die "timeout stops: $(steps)"
for f in stub.pid sleep.pid; do
  pid=$(cat "$WORK/$f"); ! kill -0 "$pid" 2>/dev/null || { kill "$pid"; die "the step's $f process should be killed"; }
done
grep -q '^lean chain: implement fail (timed out' "$WORK/applog" || die "timeout append-log: $(cat "$WORK/applog")"
reset; scn implement 'sleep 2; printf "done\n" > src/app.txt'
chain --step-minutes 1 || die "--step-minutes overrides lean.step_minutes: $(out)"
(cd "$P" && bash "$L/run.sh" chain f --step-minutes x) > "$WORK/out" 2>&1 && die "a bad --step-minutes must fail"
(cd "$P" && bash "$L/run.sh" implement f --step-minutes 1) > "$WORK/out" 2>&1 && die "--step-minutes is chain only"
pass "the step cap kills the step's processes and reports it; --step-minutes overrides the config"

echo "6. trusted files are checked before chain.sh runs"
# lean/ inside the project, as installed, so the pin covers lean/chain.sh.
P="$WORK/t1"; new_project "$P"; cp -R "$L" "$P/lean"
bash -c '. "$1/lean/lib.sh"; lean_pin "$1" f' _ "$P" 2>/dev/null || die "pin"
grep -q '  lean/chain.sh$' "$(bash -c '. "$1/lib.sh"; lean_state_dir "$2"' _ "$L" "$P")/lean/f/trusted.sha" || die "the pin should cover lean/chain.sh"
printf 'touch "%s/chain.marker"; exit 7\n' "$WORK" >> "$P/lean/chain.sh"
reset; rc=0; (cd "$P" && bash lean/run.sh chain f) > "$WORK/out" 2>&1 || rc=$?
[ "$rc" = 3 ] || die "a changed chain.sh after the pin must be refused with exit 3 (got $rc): $(out)"
[ ! -e "$WORK/chain.marker" ] || die "the changed chain.sh must not run"
[ ! -s "$CALLS" ] || die "no step should run: $(calls)"
grep -q 'lean/chain.sh' "$WORK/out" || die "the refusal should name lean/chain.sh: $(out)"
# Without the pin the same file runs: the marker above is a real signal.
rm -f "$(bash -c '. "$1/lib.sh"; lean_state_dir "$2"' _ "$L" "$P")/lean/f/trusted.sha"
rc=0; (cd "$P" && bash lean/run.sh chain f) > "$WORK/out" 2>&1 || rc=$?
[ "$rc" = 7 ] && [ -e "$WORK/chain.marker" ] || die "unpinned, the changed chain.sh should run (rc $rc): $(out)"
pass "a chain.sh changed after the pin is refused before it is sourced (exit 3, nothing ran)"

echo "7. who opens the review"
# Normal mode, lean.reviewer unset: the implementer reviews, as before.
P="$WORK/w1"; new_project "$P"; lean_conf "$P" 'del(.lean.reviewer)'
reset; scn implement 'printf "done\n" > src/app.txt'
chain || die "normal without lean.reviewer: $(out)"
[ "$(tools)" = "implement claude:-,review claude:-" ] || die "unset lean.reviewer: the implementer reviews: $(tools)"
pass "normal: without lean.reviewer the implementer's tool opens the review"

# Normal mode, a reviewer on another adapter: codex reviews (and may fix: the gate passes on its
# change), fix stays on the implementer; each step's line still reads its result JSON (no cost
# from codex).
P="$WORK/w2"; new_project "$P"; lean_conf "$P" '.lean = {implementer: "claude-mini", reviewer: "codex:gpt-x"}'
reset; scn review 'printf "done\n" > src/app.txt'
chain || die "normal with a codex reviewer that fixes: $(out)"
[ "$(steps)" = "implement:ok review:ok gate:ok" ] || die "codex review order: $(steps) / $(out)"
[ "$(tools)" = "implement claude-mini:-,review codex:gpt-x" ] || die "codex reviewer: $(tools)"
grep -Eq '^review +ok +[0-9]+m[0-9]+s turns=3$' "$WORK/out" || die "codex review line (turns, no cost): $(out)"
grep -q '^total: .*cost \$0.25' "$WORK/out" || die "total cost counts the claude-mini step only: $(out)"
g -C "$P" checkout -q -- src/app.txt
reset; scn fix 'printf "done\n" > src/app.txt'
chain || die "normal with a codex reviewer, fix round: $(out)"
[ "$(tools)" = "implement claude-mini:-,review codex:gpt-x,fix claude-mini:-" ] || die "fix stays on the implementer: $(tools)"
pass "normal: lean.reviewer (codex:<model>) opens the review and may fix; fix stays on the implementer"

# Normal mode, the reviewer set to the implementer's tool: no "must differ" refusal.
P="$WORK/w3"; new_project "$P"; lean_conf "$P" '.lean.reviewer = "claude"'
reset; scn implement 'printf "done\n" > src/app.txt'
chain || die "normal with reviewer = implementer must run: $(out)"
[ "$(tools)" = "implement claude:-,review claude:-" ] || die "same tool in normal mode: $(tools)"
pass "normal: a reviewer equal to the implementer is accepted (the must-differ check is risk only)"

# Risk mode, lean.reviewer unset: the default reviewer, as before.
P="$WORK/w4"; new_project "$P"; lean_conf "$P" 'del(.lean.reviewer)'
(cd "$P" && bash "$L/run.sh" freeze f) > "$WORK/freeze.out" 2>&1 || die "freeze by hand: $(cat "$WORK/freeze.out")"
reset; scn implement 'printf "done\n" > src/app.txt'
scn review 'printf "fine\nVERDICT: approve\n" > docs/features/f.review.md'
chain || die "risk with the default reviewer: $(out)"
[ "$(tools)" = "implement claude:-,review claude:claude-haiku-5-5" ] || die "risk default reviewer: $(tools)"
pass "risk: without lean.reviewer the default claude:claude-haiku-5-5 reviews"

# lean.reviewer per mode: {"normal": ..., "risk": ...}, each key optional. (The string form
# serving both modes is covered above: n1 and r1 both review with "claude:other".)
# risk_chain <project> — freeze it, then a passing risk chain.
risk_chain() {
  (cd "$1" && bash "$L/run.sh" freeze f) > "$WORK/freeze.out" 2>&1 || die "freeze by hand: $(cat "$WORK/freeze.out")"
  reset; scn implement 'printf "done\n" > src/app.txt'
  scn review 'printf "fine\nVERDICT: approve\n" > docs/features/f.review.md'
  chain
}
P="$WORK/o1"; new_project "$P"; lean_conf "$P" '.lean.reviewer = {normal: "codex:n", risk: "claude:r"}'
reset; scn implement 'printf "done\n" > src/app.txt'
chain || die "object reviewer, normal: $(out)"
[ "$(tools)" = "implement claude:-,review codex:n" ] || die "object reviewer, normal key: $(tools)"
P="$WORK/o2"; new_project "$P"; lean_conf "$P" '.lean.reviewer = {normal: "codex:n", risk: "claude:r"}'
risk_chain "$P" || die "object reviewer, risk: $(out)"
[ "$(tools)" = "implement claude:-,review claude:r" ] || die "object reviewer, risk key: $(tools)"
pass "object lean.reviewer: normal mode uses .normal, risk mode uses .risk"

P="$WORK/o3"; new_project "$P"; lean_conf "$P" '.lean.reviewer = {risk: "claude:r"}'
reset; scn implement 'printf "done\n" > src/app.txt'
chain || die "object with risk only, normal: $(out)"
[ "$(tools)" = "implement claude:-,review claude:-" ] || die "no .normal: the implementer reviews: $(tools)"
P="$WORK/o4"; new_project "$P"; lean_conf "$P" '.lean.reviewer = {normal: "codex:n", risk: ""}'
risk_chain "$P" || die "object with normal only, risk: $(out)"
[ "$(tools)" = "implement claude:-,review claude:claude-haiku-5-5" ] || die "no .risk: the default reviews: $(tools)"
pass "object lean.reviewer: a missing/empty key falls back (normal: implementer, risk: claude:claude-haiku-5-5)"

P="$WORK/o5"; new_project "$P"; lean_conf "$P" '.lean.reviewer = {normal: "codex:n", risk: "claude"}'
risk_chain "$P" && die "object .risk = implementer must fail: $(out)"
[ "$(steps)" = "freeze:ok implement:ok review:fail" ] || die "object same reviewer: $(steps) / $(out)"
tail -1 "$WORK/out" | grep -q '^CHAIN: FAIL at review (exit 2: risk mode: the reviewer must be another model' || die "object same reviewer line: $(out)"
pass "object lean.reviewer: .risk equal to the implementer is refused"

n=0
for bad in '3' '["claude"]' '{normal: "claude", other: "x"}' '{risk: 1}' '{normal: null}' 'false'; do
  n=$((n + 1)); P="$WORK/bad$n"; new_project "$P"; lean_conf "$P" ".lean.reviewer = $bad"
  reset
  rc=0; chain || rc=$?
  [ "$rc" = 2 ] || die "invalid lean.reviewer $bad: chain exit $rc, want 2: $(out)"
  grep -q 'invalid .harness.json::lean.reviewer' "$WORK/out" || die "invalid lean.reviewer $bad: message: $(out)"
  [ ! -s "$CALLS" ] || die "invalid lean.reviewer $bad: no session may open: $(calls)"
  rc=0; (cd "$P" && bash "$L/run.sh" review f --headless) > "$WORK/out" 2>&1 || rc=$?
  [ "$rc" = 2 ] && grep -q 'invalid .harness.json::lean.reviewer' "$WORK/out" || die "invalid lean.reviewer $bad: review step rc $rc: $(out)"
done
pass "invalid lean.reviewer (number, array, unknown key, non-string value, false): exit 2 naming the key, no session"

echo "lean_chain_test: $PASS passed"
