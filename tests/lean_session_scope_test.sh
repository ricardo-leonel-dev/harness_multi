#!/usr/bin/env bash
# lean_session_scope_test.sh — what a lean session may do, and how long it may run: a throwaway
# project, a temp HOME, stub adapters / a stub `claude` on PATH (no model, no real CLI is
# ever called).
#
#   1. turn cap: run.sh hands each headless step its cap (defaults implement 120, review 40,
#      fix 60; .harness.json::lean.max_turns overrides per key); interactive steps get none;
#      lean/adapters/claude.sh passes it as `claude -p --max-turns <n>` (never interactive).
#   2. an invalid lean.max_turns (over 10000 included) exits 2 before any session, for every
#      step and the chain.
#   3. a session that hits the cap: the chain stops with "max turns (<n>) reached", the usage
#      row is still recorded (note max_turns); without run.sh's cap line, "max turns reached".
#   4. prompts: implement, review and fix carry the boundaries (no reads of the harness's own
#      files, the project's other scripts/ and the plan's Files allowed, no ./init.sh, gate or
#      full suite); the review names its scope (git diff <base>, Files, the document; risk mode:
#      the risk-question file); the system prompt has the "Boundaries" section.
#   5. LEAN_GATE_UNSANDBOXED in a session: claude.sh drops it and sets LEAN_SESSION=1;
#      lean_sandbox_prepare ignores it with LEAN_SESSION=1 or when the lean state is unreadable
#      (sandbox-exec, when available), and keeps honouring it outside a session; the gate run
#      inside a session refuses without running the suite; lean_sandboxed's commands never see it.
#   6. with a lean feature open in a harness project: ./init.sh and harness.sh test refuse inside
#      a session without running the suite; outside one, with the lean state folder missing,
#      they run it as before.
#
# Usage: bash tests/lean_session_scope_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }
g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

mkdir -p "$WORK/home" "$WORK/bin"
export HOME="$WORK/home" LEAN_GATE_UNSANDBOXED=1 GIT_CONFIG_GLOBAL=/dev/null
export LEAN_CLAUDE_TMP="$WORK/no-claude-tmp" LEAN_DB_SOCK_DIR="$WORK/socks"
unset LEAN_SESSION LEAN_MAX_TURNS

# The toolkit's lean/ with a stub for every adapter: it records "<step> <mode> <LEAN_MAX_TURNS>",
# copies the prompt and the system prompt, runs $SCN/<step> when present and writes $STUB_JSON
# (default: a plain successful result) as the result.
L="$WORK/lean"; cp -R "$TOOLKIT_DIR/lean" "$L"
export CALLS="$WORK/calls" SCN="$WORK/scn" PROMPTS="$WORK/prompts" STUB_JSON=""
cat > "$L/adapters/claude.sh" <<'SH'
#!/usr/bin/env bash
project="$1" mode="$2" system="$4" prompt="$5" result="${6:-}"
st=$(basename "${result:-x.interactive.json}"); st="${st#*.}"; st="${st%%.*}"
[ "$mode" = headless ] || st=interactive
echo "$st $mode ${LEAN_MAX_TURNS:-none}" >> "$CALLS"
mkdir -p "$PROMPTS"; printf '%s\n' "$prompt" > "$PROMPTS/$st.prompt"; cp "$system" "$PROMPTS/$st.system"
cd "$project" || exit 1
[ -f "$SCN/$st" ] && . "$SCN/$st"
[ "$mode" = headless ] || exit 0
if [ -n "$STUB_JSON" ]; then cp "$STUB_JSON" "$result"
else printf '{"type":"result","is_error":false,"num_turns":3,"total_cost_usd":0.1}\n' > "$result"; fi
SH
chmod +x "$L/adapters/claude.sh"
cp "$L/adapters/claude.sh" "$L/adapters/claude-mini.sh"; cp "$L/adapters/claude.sh" "$L/adapters/codex.sh"

# new_project <dir> — a git repository whose suite passes once src/app.txt says done.
new_project() {
  local p="$1"
  mkdir -p "$p/src" "$p/tests" "$p/docs/features"
  echo '{"verify_command":"bash run_tests.sh","lean":{"implementer":"claude","reviewer":"claude:other"}}' > "$p/.harness.json"
  printf 'touch "%s/suite.ran"\nfor f in tests/*_test.sh; do bash "$f" || exit 1; done\n' "$WORK" > "$p/run_tests.sh"
  printf 'grep -q done src/app.txt || { echo "FAIL: app_test expects done"; exit 1; }\n' > "$p/tests/app_test.sh"
  printf 'todo\n' > "$p/src/app.txt"
  printf '# f\n\n**Files**\n- `src/app.txt`\n' > "$p/docs/features/f.md"
  printf '.harness.json\n' > "$p/.gitignore"
  g -C "$p" init -q && g -C "$p" add -A && g -C "$p" commit -qm base || die "project setup: $p"
}
lean_conf() { jq "$2" "$1/.harness.json" > "$WORK/h" && mv "$WORK/h" "$1/.harness.json"; }
state_of() { bash -c '. "$1/lean/lib.sh"; lean_state_dir "$2"' _ "$TOOLKIT_DIR" "$1"; }
repin() { rm -f "$(state_of "$1")/lean/f/trusted.sha"; }
run() { (cd "$P" && bash "$L/run.sh" "$@") > "$WORK/out" 2>&1; }
out() { cat "$WORK/out"; }
reset() { rm -rf "$SCN" "$PROMPTS" "$CALLS"; : > "$CALLS"; STUB_JSON=""; }
cap_of() { awk -v s="$1" '$1 == s { c = $3 } END { print c }' "$CALLS"; }

echo "1. turn cap per step"
P="$WORK/p1"; new_project "$P"
reset
for s in implement review fix; do run "$s" f --headless || die "$s: $(out)"; done
[ "$(cap_of implement) $(cap_of review) $(cap_of fix)" = "120 40 60" ] || die "default caps: $(cat "$CALLS")"
grep -q '^\[lean\] max turns: 60$' "$WORK/out" || die "run.sh logs the cap: $(out)"
run implement f || die "interactive implement: $(out)"
[ "$(cap_of interactive)" = none ] || die "an interactive session has no cap: $(cat "$CALLS")"
lean_conf "$P" '.lean.max_turns = {"implement": 7, "review": 3}'; repin "$P"
reset
for s in implement review fix; do run "$s" f --headless || die "$s with lean.max_turns: $(out)"; done
[ "$(cap_of implement) $(cap_of review) $(cap_of fix)" = "7 3 60" ] || die "configured caps (fix keeps its default): $(cat "$CALLS")"
# The real claude adapter, with a stub `claude` that records its argv and environment.
cat > "$WORK/bin/claude" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/claude.argv"; env > "$WORK/claude.env"
echo '{"type":"result","is_error":false,"num_turns":1}'
SH
chmod +x "$WORK/bin/claude"; printf 'sys\n' > "$WORK/sys.md"
adapt() { (cd "$P" && PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/adapters/claude.sh" "$P" "$@" "$WORK/sys.md" go "$WORK/r.json") >/dev/null 2>"$WORK/err"; }
rm -f "$WORK/claude.argv"
LEAN_MAX_TURNS=40 adapt headless - || die "claude.sh headless: $(cat "$WORK/err")"
grep -A1 -x -- '--max-turns' "$WORK/claude.argv" | tail -1 | grep -qx 40 || die "claude -p gets --max-turns 40: $(tr '\n' ' ' < "$WORK/claude.argv")"
grep -qx -- '-p' "$WORK/claude.argv" || die "headless is claude -p"
adapt headless - || die "claude.sh without a cap: $(cat "$WORK/err")"
grep -qx -- '--max-turns' "$WORK/claude.argv" && die "no cap given: no --max-turns"
LEAN_MAX_TURNS=40 adapt interactive - || die "claude.sh interactive: $(cat "$WORK/err")"
grep -qx -- '--max-turns' "$WORK/claude.argv" && die "interactive sessions get no --max-turns"
rm -f "$WORK/claude.argv"
LEAN_MAX_TURNS=4x adapt headless -; rc=$?
[ "$rc" = 2 ] && [ ! -e "$WORK/claude.argv" ] || die "a malformed LEAN_MAX_TURNS exits 2 before claude: rc=$rc $(cat "$WORK/err")"
pass "caps: 120/40/60 by default, lean.max_turns per key, none interactive; claude -p --max-turns <n>"

echo "2. an invalid lean.max_turns"
for bad in '"40"' '40' '[]' '{"implement": 0}' '{"review": 1.5}' '{"review": "40"}' '{"other": 3}' '{"fix": -1}' '{"implement": 10001}' '{"review": 1e300}'; do
  lean_conf "$P" ".lean.max_turns = $bad"; repin "$P"
  for s in implement chain; do
    reset
    if [ "$s" = chain ]; then run chain f; else run "$s" f --headless; fi; rc=$?
    [ "$rc" = 2 ] || die "lean.max_turns = $bad, $s: exit 2 expected, got $rc: $(out)"
    grep -q 'invalid .harness.json::lean.max_turns' "$WORK/out" || die "lean.max_turns = $bad, $s: the message names the key: $(out)"
    [ ! -s "$CALLS" ] || die "lean.max_turns = $bad, $s: no session may open: $(cat "$CALLS")"
  done
done
lean_conf "$P" 'del(.lean.max_turns)'; repin "$P"
pass "an invalid lean.max_turns exits 2 naming the key, before any session (steps and chain)"

echo "3. the cap reached"
P="$WORK/p3"; new_project "$P"
lean_conf "$P" '.lean.max_turns = {"review": 5}'
reset
printf 'printf "done\\n" > src/app.txt\n' > "$WORK/impl.scn"; mkdir -p "$SCN"; cp "$WORK/impl.scn" "$SCN/implement"
printf '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":6,"total_cost_usd":0.2,"errors":["Reached maximum number of turns (5)"]}\n' > "$WORK/maxed.json"
printf 'STUB_JSON=%s\n' "$WORK/maxed.json" > "$SCN/review"
run chain f && die "a capped review must fail the chain: $(out)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: FAIL at review (max turns (5) reached)" ] || die "the chain names the cap: $(out)"
grep -q '^review .*fail' "$WORK/out" || die "the review's step line: $(out)"
urow=$(awk -F'\t' '$3 == "review"' "$(state_of "$P")/lean/f/usage.tsv" | tail -1)
[ "$(cut -f7 <<<"$urow")" = 6 ] && [ "$(cut -f14 <<<"$urow")" = max_turns ] || die "the usage row is recorded with note max_turns: $urow"
grep -q '^  review .*max_turns$' "$WORK/out" || die "the chain's usage table shows it: $(out)"
log=$(sed -n 's/^logs: \([^ ]*\) .*/\1/p' "$WORK/out")
grep -q '^\[lean\] max turns (5) reached' "$log"/*-review.log || die "run.sh logs the cap reached"
# A step log without run.sh's "max turns: <n>" line (an older run.sh): no empty count.
P="$WORK/p3b"; new_project "$P"
L0="$L"; L="$WORK/lean-old"; cp -R "$L0" "$L"
grep -q '^ *log "max turns: \$max_turns"$' "$L/run.sh" || die "run.sh logs its cap line"
sed -i.bak '/^ *log "max turns: \$max_turns"$/d' "$L/run.sh"
reset
mkdir -p "$SCN"; cp "$WORK/impl.scn" "$SCN/implement"; printf 'STUB_JSON=%s\n' "$WORK/maxed.json" > "$SCN/review"
run chain f && die "a capped review must fail the chain (old run.sh): $(out)"
L="$L0"
[ "$(tail -1 "$WORK/out")" = "CHAIN: FAIL at review (max turns reached)" ] || die "without the cap line: $(out)"
pass "cap reached: CHAIN: FAIL at review (max turns (5) reached), usage row recorded (note max_turns); no count logged: max turns reached"

echo "4. prompts"
P="$WORK/p4"; new_project "$P"
reset
for s in implement review fix; do run "$s" f --headless || die "$s: $(out)"; done
base=$(g -C "$P" rev-parse HEAD)
for s in implement review fix; do
  for want in "do not read lean/, harness/, the harness's own scripts (scripts/harness.sh, scripts/lib.sh," \
      "the files under **Files**, the code and tests they touch and any file this prompt names are always fine to read" 'do not run ./init.sh, lean/gate.sh, scripts/harness.sh or the full test suite' "Run the feature's own tests"; do
    grep -qF "$want" "$PROMPTS/$s.prompt" || die "$s prompt: '$want' missing: $(cat "$PROMPTS/$s.prompt")"
  done
  grep -q '^## Boundaries$' "$PROMPTS/$s.system" || die "$s system prompt: Boundaries section"
  grep -qF 'LEAN_GATE_UNSANDBOXED` has no effect' "$PROMPTS/$s.system" || die "$s system prompt: the bypass is named"
  grep -qF 'The files under **Files**, and the code and tests they touch, are' "$PROMPTS/$s.system" || die "$s system prompt: Files are allowed"
  grep -qF 'lean/, scripts/' "$PROMPTS/$s.prompt" "$PROMPTS/$s.system" && die "$s: the project's own scripts/ must not be banned"
done
grep -qF "Review only: the change (git diff $base, plus the untracked files git status --short lists), the files under **Files** in docs/features/f.md, and docs/features/f.md itself." "$PROMPTS/review.prompt" \
  || die "review scope: $(cat "$PROMPTS/review.prompt")"
grep -qF 'risk questions' "$PROMPTS/review.prompt" && die "normal review: no risk-question file"
grep -qF 'Rerun the tests the report names as failing' "$PROMPTS/fix.prompt" || die "fix: targeted reruns"
# Risk mode: the frozen manifest makes the feature risky; its review adds the question file.
mkdir -p "$P/acceptance"; printf 'true\n' > "$P/acceptance/f.test.sh"
st=$(state_of "$P"); mkdir -p "$st/frozen"; (cd "$P" && shasum -a 256 acceptance/f.test.sh) > "$st/frozen/f.sha"
run review f --headless || die "risk review: $(out)"
grep -qF ", and the risk questions in $L/risk-questions/backend.md." "$PROMPTS/review.prompt" || die "risk review scope: $(cat "$PROMPTS/review.prompt")"
grep -qF 'report only, in docs/features/f.review.md' "$PROMPTS/review.prompt" || die "risk review still reports only"
pass "prompts: boundaries in every step; review scoped to the diff, Files and the document (risk: the questions)"

echo "5. LEAN_GATE_UNSANDBOXED in a session"
P="$WORK/p5"; new_project "$P"
(cd "$P" && LEAN_SESSION=1 FAKE_TOKEN=x adapt headless -) || die "claude.sh: $(cat "$WORK/err")"
grep -q '^LEAN_GATE_UNSANDBOXED=' "$WORK/claude.env" && die "claude.sh must drop LEAN_GATE_UNSANDBOXED"
grep -qx 'LEAN_SESSION=1' "$WORK/claude.env" || die "claude.sh sets LEAN_SESSION=1"
prep() { bash -c '. "$1/lean/lib.sh"; lean_sandbox_prepare "$2"; echo "$LEAN_SANDBOX"' _ "$TOOLKIT_DIR" "$P"; }
[ "$(LEAN_GATE_UNSANDBOXED=1 prep)" = "unsandboxed: LEAN_GATE_UNSANDBOXED=1" ] || die "outside a session it is honoured: $(prep)"
LEAN_SESSION=1 LEAN_GATE_UNSANDBOXED=1 prep | grep -q '^session: inside a lean session' || die "with LEAN_SESSION=1 it is ignored: $(LEAN_SESSION=1 prep)"
st=$(state_of "$P"); mkdir -p "$st/lean"
if command -v sandbox-exec >/dev/null 2>&1 && sandbox-exec -p '(version 1)(allow default)' true 2>/dev/null; then
  r=$(sandbox-exec -p "(version 1)(allow default)(deny file-read* (subpath \"$st\"))" env -u LEAN_SESSION LEAN_GATE_UNSANDBOXED=1 \
    bash -c '. "$1/lean/lib.sh"; lean_sandbox_prepare "$2"; echo "$LEAN_SANDBOX"' _ "$TOOLKIT_DIR" "$P" 2>&1)
  grep -q '^session: ' <<<"$r" || die "with the lean state unreadable (LEAN_SESSION unset) it is ignored: $r"
else
  echo "  skip sandbox-exec not available (unreadable-state detection)"
fi
rm -f "$WORK/suite.ran"
out=$(cd "$P" && LEAN_SESSION=1 LEAN_GATE_UNSANDBOXED=1 bash "$TOOLKIT_DIR/lean/gate.sh" "$P" f 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q '^SANDBOX UNAVAILABLE: inside a lean session' <<<"$out" || die "the gate refuses inside a session: rc=$rc $out"
grep -q 'set LEAN_GATE_UNSANDBOXED=1' <<<"$out" && die "inside a session the gate must not suggest the bypass: $out"
[ ! -e "$WORK/suite.ran" ] || die "the suite must not run inside a session"
r=$(bash -c '. "$1/lean/lib.sh"; lean_sandbox_prepare "$2"; lean_sandboxed "$2" "env"' _ "$TOOLKIT_DIR" "$P" 2>&1) || die "lean_sandboxed: $r"
grep -q '^LEAN_GATE_UNSANDBOXED=' <<<"$r" && die "the gate's commands must not see LEAN_GATE_UNSANDBOXED"
pass "LEAN_GATE_UNSANDBOXED: dropped from sessions and the gate's commands, ignored inside a session (marker or unreadable state), honoured outside"

echo "6. ./init.sh and harness.sh test with a lean feature open"
P="$WORK/p6"; new_project "$P"
mkdir -p "$P/scripts"; cp "$TOOLKIT_DIR"/scripts/*.sh "$TOOLKIT_DIR/scripts/agent_usage.py" "$P/scripts/"
cp -R "$TOOLKIT_DIR/lean" "$P/lean"; cp "$TOOLKIT_DIR/init.sh" "$P/init.sh"
for f in docs/architecture.md docs/conventions.md docs/verification.md CHECKPOINTS.md; do printf '# x\n' > "$P/$f"; done
printf '#!/usr/bin/env bash\nexit 0\n' > "$P/scripts/sync_postgres.sh"
printf '.harness.json\nharness.db\nprogress/\nstate/\nscripts/\nlean/\n' > "$P/.gitignore"
printf 'done\n' > "$P/src/app.txt"; g -C "$P" add -A && g -C "$P" commit -qm done || die "p6 setup"
echo '{"project_slug":"t6","db_path":"harness.db","snapshot_path":"state","verify_command":"bash run_tests.sh"}' > "$P/.harness.json"
sqlite3 "$P/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql" && sqlite3 "$P/harness.db" "INSERT INTO projects (id, slug) VALUES ('p6','t6');" || die "p6 db"
H6() { (cd "$P" && HARNESS_AGENT=implementer ANTHROPIC_MODEL= HARNESS_HUMAN_USER= bash scripts/harness.sh "$@") 2>&1; }
H6 add-feature --name f --title F --mode normal >/dev/null && H6 claim f >/dev/null || die "p6: claim a normal lean feature: $(H6 status)"
for how in init test test-file; do
  rm -f "$WORK/suite.ran"
  case "$how" in
    init) out=$(cd "$P" && LEAN_SESSION=1 LEAN_GATE_UNSANDBOXED=1 bash init.sh 2>&1) ;;
    test) out=$(LEAN_SESSION=1 LEAN_GATE_UNSANDBOXED=1 H6 test) ;;
    test-file) out=$(LEAN_SESSION=1 LEAN_GATE_UNSANDBOXED=1 H6 test tests/app_test.sh) ;;
  esac && die "$how inside a session must fail: $out"
  grep -q 'lean feature f .*inside a lean session' <<<"$out" || die "$how inside a session names the refusal: $out"
  grep -q 'set LEAN_GATE_UNSANDBOXED=1' <<<"$out" && die "$how inside a session must not suggest the bypass: $out"
  [ ! -e "$WORK/suite.ran" ] || die "$how inside a session must not run the suite"
done
st=$(state_of "$P"); [ -d "$st" ] || die "p6: claim keeps the lean state in $st"; rm -rf "$st"
for how in init test; do
  rm -f "$WORK/suite.ran"
  case "$how" in
    init) out=$(cd "$P" && LEAN_GATE_UNSANDBOXED=1 bash init.sh 2>&1) ;;
    test) out=$(LEAN_GATE_UNSANDBOXED=1 H6 test) ;;
  esac || die "$how outside a session, lean state missing, must run and pass: $out"
  grep -q 'inside a lean session' <<<"$out" && die "$how outside a session is not taken for one: $out"
  [ -e "$WORK/suite.ran" ] || die "$how outside a session runs the suite: $out"
done
pass "lean feature open: init.sh and harness.sh test refuse inside a session (suite not run), run outside it with no lean state"

echo "lean_session_scope_test: $PASS passed"
