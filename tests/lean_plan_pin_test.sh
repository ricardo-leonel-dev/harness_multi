#!/usr/bin/env bash
# lean_plan_pin_test.sh — the plan's **Files** / **Changed tests** pinned outside the project
# (<lean state>/lean/<name>/plan.lists, lean/lib.sh lean_plan_pin), against throwaway projects
# (temp HOME, temp git repositories, a stub adapter: no model is ever called; the suite runs
# unsandboxed, LEAN_GATE_UNSANDBOXED=1).
#
#   1. normal mode: a session that adds a path to **Files** (and changes that file) fails the
#      gate, which names the added path; appending another section (Decisions while
#      implementing) doesn't; a path added to **Changed tests** with an assertion removed fails too.
#   2. lean/run.sh replan: refused inside a session (LEAN_SESSION=1, plan.lists unchanged);
#      run by the leader it pins the lists afresh and the gate passes.
#   3. before the first session the leader may still edit the plan: the next run.sh step pins it
#      again; once a session ran, a pin never rewrites it.
#   4. a feature whose sessions ran without plan.lists (older version, lost file): the gate
#      fails closed (NO PINNED PLAN LISTS), no pin creates one, replan does.
#   5. risk mode without the harness: run.sh freeze pins the lists as approved; a pin never
#      rewrites them; replan needs --by (not "user") and records it.
#   6. with the harness: approve-plan pins the approved lists (claim keeps them); replan of an
#      approved plan needs --by; log-out --lean, supersede, delete-feature and set-mode none
#      remove plan.lists.
#   7. set-mode none -> normal, and a reused name: the gate and log-out --lean fail closed (M1).
#   8. claim restores an approved plan's approval after a lost state folder (L2).
#   9. approve-plan of a normal --approval plan adopts the legacy slug state first (L1).
#  10. run.sh freeze after sessions ran approves the pinned lists, not the document (L3).
#
# Usage: bash tests/lean_plan_pin_test.sh   (exits non-zero on the first failure)

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
unset LEAN_SESSION
export CALLS="$WORK/calls" SCN="$WORK/scn"
mkdir -p "$SCN"

# new_project <dir> [harness] — lean/ (and with harness, scripts/ and harness.db) inside the
# project, git-ignored; the stub adapter runs $SCN/<step> in the project for each session.
new_project() {
  local p="$1"
  mkdir -p "$p/src" "$p/tests" "$p/docs/features" "$p/acceptance"
  cp -R "$TOOLKIT_DIR/lean" "$p/lean"
  cat > "$p/lean/adapters/claude.sh" <<'SH'
#!/usr/bin/env bash
project="$1" result="${6:-}"
st=$(basename "$result"); st="${st#*.}"; st="${st%%.*}"
echo "$st" >> "$CALLS"
cd "$project" || exit 1
[ -f "$SCN/$st" ] && . "$SCN/$st"
[ -z "$result" ] || printf '{"is_error":false,"num_turns":1,"total_cost_usd":0.01}\n' > "$result"
SH
  chmod +x "$p/lean/adapters/claude.sh"
  echo '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state","verify_command":"bash run_tests.sh","lean":{"implementer":"claude","reviewer":"claude:other"}}' > "$p/.harness.json"
  cat > "$p/run_tests.sh" <<'T'
[ $# -gt 0 ] || set -- tests/*_test.sh
rc=0
for f in "$@"; do bash "$f" || rc=1; done
exit "$rc"
T
  printf '  assert_done() { grep -q done src/app.txt; }\n  assert_done || { echo "FAIL: app_test"; exit 1; }\n' > "$p/tests/app_test.sh"
  printf 'grep -q done src/app.txt || { echo "FAIL: acceptance"; exit 1; }\n' > "$p/acceptance/f.test.sh"
  printf 'todo\n' > "$p/src/app.txt"
  plan "$p"
  printf '.harness.json\nlean/\nscripts/\nharness.db\nstate/\nprogress/\n' > "$p/.gitignore"
  if [ "${2:-}" = harness ]; then
    mkdir -p "$p/scripts"
    cp "$TOOLKIT_DIR"/scripts/*.sh "$TOOLKIT_DIR/scripts/agent_usage.py" "$p/scripts/"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$p/scripts/sync_postgres.sh"
    sqlite3 "$p/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql"
    sqlite3 "$p/harness.db" "INSERT INTO projects (id, slug) VALUES ('p1','t');"
  fi
  g -C "$p" init -q && g -C "$p" add -A && g -C "$p" commit -qm base || die "project setup: $p"
}
# plan <dir> [<extra Files path>...] — docs/features/f.md: Files (src/app.txt and the extras),
# Changed tests none, then Steps (Files is not the last section).
plan() {
  local p="$1"; shift
  { printf '# f\n\n## Decisions\n- keep it small\n\n## Files\n- `src/app.txt`: the change\n'
    for x in "$@"; do printf -- '- `%s`: needed\n' "$x"; done
    printf '\n## Changed tests\nnone\n\n## Steps\n1. write done\n'
  } > "$p/docs/features/f.md"
}
RUN() { (cd "$P" && bash lean/run.sh "$@") > "$WORK/out" 2>&1; }
gate() { RUN gate f; }
out() { cat "$WORK/out"; }
lib() { (cd "$P" && bash -c '. lean/lib.sh; "$@"' _ "$@"); }
PL() { printf '%s/lean/f/plan.lists\n' "$(lib lean_state_dir "$P")"; }

echo "1. a session can't widen the plan"
P="$WORK/p1"; new_project "$P"
# The implement session does the work, writes an out-of-scope helper and lists it under
# **Files** itself, and appends its decisions (another section).
cat > "$SCN/implement" <<'S'
printf 'done\n' > src/app.txt
printf 'helper\n' > tests/common.sh
awk '{ print } /^- `src\/app.txt`/ { print "- `tests/common.sh`: the environment needed it" }' docs/features/f.md > f.tmp && mv f.tmp docs/features/f.md
printf '\n## Decisions while implementing\n- used src/app.txt as is\n' >> docs/features/f.md
S
RUN implement f --headless || die "implement: $(out)"
grep -q 'tests/common.sh' "$P/docs/features/f.md" || die "the stub session should have edited the plan"
[ -f "$(PL)" ] || die "the first session's pin must write plan.lists"
grep -q 'tests/common.sh' "$(PL)" && die "plan.lists must hold the plan as it was before the session: $(cat "$(PL)")"
gate && die "a path the session added to Files must fail the gate: $(out)"
grep -q 'PLAN LISTS CHANGED SINCE PINNED' "$WORK/out" || die "drift heading: $(out)"
grep -qx '  + Files: tests/common.sh' "$WORK/out" || die "the added path must be named: $(out)"
grep -A2 'CHANGED BUT NOT LISTED' "$WORK/out" | grep -qx 'tests/common.sh' || die "the file stays outside the pinned Files: $(out)"
grep -q 'lean/run.sh replan f' "$WORK/out" || die "the report tells the leader how to accept it: $(out)"
grep -q 'Decisions while implementing' "$WORK/out" && die "the appended section is not drift: $(out)"
pass "a path added to Files by a session fails the gate, named; the pinned list still applies"

# The session puts the plan back: the appended Decisions section alone doesn't fail.
awk '!/tests\/common.sh/' "$P/docs/features/f.md" > "$WORK/f.md" && cp "$WORK/f.md" "$P/docs/features/f.md"
rm "$P/tests/common.sh"
gate || die "an appended section with the lists unchanged must pass: $(out)"
grep -q 'Decisions while implementing' "$P/docs/features/f.md" || die "setup: the section stays"
pass "appending another section (Decisions while implementing) doesn't fail the gate"

# A removed assertion listed under Changed tests by a session counts as not listed.
cp "$P/docs/features/f.md" "$WORK/f.good"
printf '  true\n' > "$P/tests/app_test.sh"
awk '{ if ($0 == "none" && prev ~ /Changed tests/) print "- `tests/app_test.sh`: relaxed"; else print; prev = $0 }' \
  "$P/docs/features/f.md" > "$WORK/f.md" && cp "$WORK/f.md" "$P/docs/features/f.md"
gate && die "Changed tests widened by a session must fail: $(out)"
grep -qx '  + Changed tests: tests/app_test.sh' "$WORK/out" || die "the added test path must be named: $(out)"
grep -q 'ASSERTION LINES REMOVED FROM tests/app_test.sh' "$WORK/out" || die "the pinned Changed tests apply: $(out)"
pass "a path added to Changed tests by a session fails the gate (and the removed assertion counts)"
g -C "$P" checkout -q -- tests/app_test.sh
cp "$WORK/f.good" "$P/docs/features/f.md"
gate || die "back as pinned: $(out)"

echo "2. replan"
printf 'helper\n' > "$P/tests/common.sh"
awk '{ print } /^- `src\/app.txt`/ { print "- `tests/common.sh`: the leader accepts it" }' "$P/docs/features/f.md" > "$WORK/f.md" && cp "$WORK/f.md" "$P/docs/features/f.md"
cp "$(PL)" "$WORK/pl.before"
(cd "$P" && LEAN_SESSION=1 bash lean/run.sh replan f) > "$WORK/out" 2>&1; rc=$?
[ "$rc" = 2 ] || die "replan inside a session must exit 2 (got $rc): $(out)"
grep -q 'inside a lean session' "$WORK/out" || die "replan refusal message: $(out)"
cmp -s "$(PL)" "$WORK/pl.before" || die "a refused replan must leave plan.lists as it was"
pass "replan is refused inside a session (LEAN_SESSION=1), plan.lists unchanged"
gate && die "still failing before replan: $(out)"
RUN replan f || die "replan by the leader: $(out)"
grep -q '+ Files: tests/common.sh' "$WORK/out" || die "replan shows what it accepts: $(out)"
grep -q 'tests/common.sh' "$(PL)" || die "replan must pin the new list: $(cat "$(PL)")"
gate || die "after replan the gate passes: $(out)"
RUN replan f || die "replan again: $(out)"
grep -q 'nothing to accept' "$WORK/out" || die "replan with nothing changed: $(out)"
pass "the leader's replan pins the lists afresh and the gate passes"

echo "3. leader edits before the first session; pins after one"
P="$WORK/p3"; new_project "$P"
: > "$SCN/implement"
lib lean_pin "$P" f 2>/dev/null || die "pin (claim)"
grep -q 'src/app.txt' "$(PL)" || die "the claim pin writes plan.lists: $(cat "$(PL)")"
plan "$P" src/extra.txt     # the leader edits the plan after the claim, before any session
cat > "$SCN/implement" <<'S'
printf 'done\n' > src/app.txt; printf 'x\n' > src/extra.txt
S
RUN implement f --headless || die "implement: $(out)"
grep -q 'src/extra.txt' "$(PL)" || die "the pin before the first session takes the leader's edit: $(cat "$(PL)")"
gate || die "the leader's edit before the first session is the plan: $(out)"
plan "$P" src/extra.txt src/more.txt
lib lean_pin "$P" f 2>/dev/null; lib lean_pin "$P" f --again 2>/dev/null
grep -q 'src/more.txt' "$(PL)" && die "a pin (or a later claim) after a session must not rewrite plan.lists"
gate && die "an edit after the first session needs replan: $(out)"
pass "pins rewrite plan.lists only until the first session; after it, only replan"

echo "4. a feature whose sessions ran without plan.lists fails closed"
rm "$(PL)"
printf 'y\n' > "$P/src/more.txt"
gate && die "sessions ran but nothing pinned: the gate must fail, not trust the document: $(out)"
grep -q 'NO PINNED PLAN LISTS' "$WORK/out" || die "fail-closed heading: $(out)"
grep -q 'lean/run.sh replan f' "$WORK/out" || die "the report tells the leader to replan: $(out)"
lib lean_pin "$P" f 2>/dev/null || die "pin of such a feature must not fail"
RUN review f --headless || die "a step of such a feature: $(out)"
[ ! -f "$(PL)" ] || die "no pin may create plan.lists once sessions ran: $(cat "$(PL)")"
RUN replan f || die "replan creates the lists: $(out)"
grep -q '+ Files: src/more.txt' "$WORK/out" || die "replan without lists shows what it pins: $(out)"
gate || die "after replan the gate passes: $(out)"
pass "no plan.lists after sessions ran: the gate fails closed, no pin creates it, replan does"

echo "5. risk mode without the harness: freeze pins the approved lists"
P="$WORK/p5"; new_project "$P"
RUN freeze f || die "freeze: $(out)"
head -1 "$(PL)" | grep -q '^# approved by run.sh freeze' || die "freeze pins the lists as approved: $(cat "$(PL)")"
plan "$P" src/extra.txt     # an edit after the approval, even before any session
lib lean_pin "$P" f 2>/dev/null
grep -q 'src/extra.txt' "$(PL)" && die "a pin must not rewrite approved lists"
RUN replan f; [ $? = 1 ] || die "replan of an approved plan without --by must exit 1: $(out)"
grep -q 'needs the user.s approval again' "$WORK/out" || die "approval message: $(out)"
RUN replan f --by user && die "--by user is no approver: $(out)"
grep -q 'src/extra.txt' "$(PL)" && die "a refused replan must not pin"
RUN replan f --by Ana || die "replan --by: $(out)"
head -1 "$(PL)" | grep -q '^# approved by Ana at ' || die "replan --by records the approver: $(cat "$(PL)")"
grep -q 'src/extra.txt' "$(PL)" || die "replan --by pins the change"
pass "risk: freeze pins approved lists; a pin keeps them; replan needs --by (not user) and records it"

echo "6. with the harness"
P="$WORK/p6"; new_project "$P" harness
H() { (cd "$P" && HARNESS_AGENT=implementer HARNESS_HUMAN_USER= bash scripts/harness.sh "$@") 2>&1; }
CACHE=$(lib lean_state_dir "$P")
for f in f k1 k2 k3 k4; do H add-feature --name "$f" --title "$f" --mode risk >/dev/null || die "add $f"; done
H set-mode k4 normal >/dev/null || die "set-mode k4 normal"
out=$(H approve-plan f --by Ana) || die "approve-plan: $out"
head -1 "$CACHE/lean/f/plan.lists" | grep -q '^# approved by Ana at ' || die "approve-plan pins the approved lists: $(cat "$CACHE/lean/f/plan.lists" 2>&1)"
out=$(H claim f) || die "claim: $out"
head -1 "$CACHE/lean/f/plan.lists" | grep -q '^# approved by Ana' || die "claim keeps the approved lists"
[ -f "$CACHE/lean/f/dirty.sha" ] || die "plan.lists from approve-plan must not stop the first claim's dirty.sha"
cat > "$SCN/implement" <<'S'
printf 'done\n' > src/app.txt; printf 'h\n' > src/helper.txt
awk '{ print } /^- `src\/app.txt`/ { print "- `src/helper.txt`: needed" }' docs/features/f.md > f.tmp && mv f.tmp docs/features/f.md
S
RUN implement f --headless || die "implement: $(out)"
printf 'VERDICT: approve\n' > "$P/docs/features/f.review.md"
out=$(H log-out --lean --changes src/app.txt src/helper.txt docs/features/f.md docs/features/f.review.md --verification v --closure c) \
  && die "log-out --lean must refuse a widened plan: $out"
grep -q 'src/helper.txt' <<<"$out" || die "log-out --lean names the path: $out"
RUN replan f; [ $? = 1 ] || die "replan of an approved plan needs --by: $(out)"
RUN replan f --by Ana || die "replan --by: $(out)"
out=$(H log-out --lean --changes src/app.txt src/helper.txt docs/features/f.md docs/features/f.review.md --verification v --closure c) \
  || die "log-out --lean after replan: $out"
[ ! -e "$CACHE/lean/f/plan.lists" ] || die "log-out --lean must remove plan.lists"
for f in k1 k2 k3 k4; do mkdir -p "$CACHE/lean/$f" && : > "$CACHE/lean/$f/plan.lists"; done
H supersede k1 --by k2 --reason test >/dev/null || die "supersede k1"
H delete-feature k3 >/dev/null || die "delete k3"
H set-mode k4 none >/dev/null || die "set-mode k4 none"
[ ! -e "$CACHE/lean/k1/plan.lists" ] && [ ! -e "$CACHE/lean/k3/plan.lists" ] && [ ! -e "$CACHE/lean/k4/plan.lists" ] \
  && [ -f "$CACHE/lean/k2/plan.lists" ] || die "supersede, delete-feature and set-mode none must remove that feature's plan.lists only"
pass "harness: approve-plan pins approved lists, claim keeps them; log-out --lean, supersede, delete, set-mode none remove them"

echo "7. set-mode none -> normal and a reused name: fail closed (review M1)"
P="$WORK/p7"; new_project "$P" harness
CACHE=$(lib lean_state_dir "$P")
H add-feature --name f --title f --mode normal >/dev/null || die "add f"
H claim f >/dev/null || die "claim f"
cat > "$SCN/implement" <<'S'
printf 'done\n' > src/app.txt
S
RUN implement f --headless || die "implement: $(out)"
[ -f "$CACHE/lean/f/plan.lists" ] || die "setup: plan.lists pinned"
H set-mode f none >/dev/null || die "set-mode none"
[ ! -e "$CACHE/lean/f/plan.lists" ] || die "setup: set-mode none removes plan.lists"
H set-mode f normal >/dev/null || die "set-mode normal"
cat > "$SCN/fix" <<'S'
printf 'h\n' > src/helper.txt
awk '{ print } /^- `src\/app.txt`/ { print "- `src/helper.txt`: needed" }' docs/features/f.md > f.tmp && mv f.tmp docs/features/f.md
S
RUN fix f --headless || die "fix: $(out)"
gate && die "after set-mode none -> normal a session-widened Files must not pass: $(out)"
grep -q 'NO PINNED PLAN LISTS' "$WORK/out" || die "fail-closed heading: $(out)"
printf 'VERDICT: approve\n' > "$P/docs/features/f.review.md"
out=$(H log-out --lean --changes src/app.txt src/helper.txt docs/features/f.md docs/features/f.review.md --verification v --closure c) \
  && die "log-out --lean must refuse it too: $out"
pass "set-mode none -> normal: the gate (and log-out --lean) fail closed instead of reading the widened document"
sid=$(sqlite3 "$P/harness.db" "SELECT id FROM session_log WHERE closed_at IS NULL AND deleted_at IS NULL LIMIT 1;")
H cancel-session --force "$sid" test >/dev/null || die "cancel session $sid"
H delete-feature f >/dev/null || die "delete f"
g -C "$P" checkout -q -- . && rm -f "$P/src/helper.txt" "$P/docs/features/f.review.md"
H add-feature --name f --title f --mode normal >/dev/null || die "re-add f"
H claim f >/dev/null || die "claim the reused name: $(H claim f)"
RUN fix f --headless || die "fix: $(out)"
gate && die "a reused name with the old sessions' markers must not trust the document: $(out)"
grep -q 'NO PINNED PLAN LISTS' "$WORK/out" || die "fail-closed heading (reused name): $(out)"
pass "a reused feature name: the gate fails closed"

echo "8. an approved plan stays approved across a lost state folder (review L2)"
P="$WORK/p8"; new_project "$P" harness
CACHE=$(lib lean_state_dir "$P")
H add-feature --name f --title f --mode normal --approval >/dev/null || die "add f"
H approve-plan f --by Ana >/dev/null || die "approve-plan"
rm -rf "$CACHE/lean/f"
H claim f >/dev/null || die "claim"
head -1 "$CACHE/lean/f/plan.lists" | grep -q '^# approved by Ana' || die "claim restores the approval before any session: $(cat "$CACHE/lean/f/plan.lists" 2>&1)"
grep -q 'src/app.txt' "$CACHE/lean/f/plan.lists" || die "and pins the lists from the document then"
: > "$SCN/implement"; : > "$SCN/fix"
RUN implement f --headless || die "implement: $(out)"
rm -f "$CACHE/lean/f/plan.lists"
sid=$(sqlite3 "$P/harness.db" "SELECT id FROM session_log WHERE closed_at IS NULL AND deleted_at IS NULL LIMIT 1;")
H cancel-session --force "$sid" test >/dev/null || die "cancel session $sid"
out=$(H claim f) || die "claim again (resume): $out"
head -1 "$CACHE/lean/f/plan.lists" | grep -q '^# approved by Ana' || die "claim after sessions marks the approval: $(cat "$CACHE/lean/f/plan.lists" 2>&1)"
grep -q 'src/app.txt' "$CACHE/lean/f/plan.lists" && die "after sessions the document is never re-read into approved lists"
gate && die "approval line alone: the gate names every path until replan --by: $(out)"
RUN replan f; [ $? = 1 ] || die "replan of the restored approved plan needs --by: $(out)"
RUN replan f --by Ana || die "replan --by: $(out)"
pass "claim restores an approved plan's approval; after sessions only the approval line, replan needs --by"

echo "9. legacy slug state survives approve-plan of a normal --approval plan (review L1)"
P="$WORK/p9"; new_project "$P" harness
CACHE=$(lib lean_state_dir "$P")
mkdir -p "$HOME/.cache/harness/t/frozen" && printf 'abc  acceptance/old.test.sh\n' > "$HOME/.cache/harness/t/frozen/old.sha"
H add-feature --name f --title f --mode normal --approval >/dev/null || die "add f"
H approve-plan f --by Ana >/dev/null || die "approve-plan"
[ -f "$CACHE/frozen/old.sha" ] || die "approve-plan must adopt the legacy state before creating the folder"
[ -f "$CACHE/lean/f/plan.lists" ] || die "and still pin the lists"
pass "approve-plan (normal --approval) adopts the legacy slug state first"

echo "10. run.sh freeze after sessions ran approves the pinned lists, not the widened document (review L3)"
P="$WORK/p10"; new_project "$P"
cat > "$SCN/implement" <<'S'
awk '{ print } /^- `src\/app.txt`/ { print "- `src/wide.txt`: wider" }' docs/features/f.md > f.tmp && mv f.tmp docs/features/f.md
S
RUN implement f --headless || die "implement: $(out)"
RUN freeze f
head -1 "$(PL)" | grep -q '^# approved by run.sh freeze' || die "freeze marks the lists approved: $(cat "$(PL)")"
grep -q 'src/wide.txt' "$(PL)" && die "freeze after a session must not approve the session's widening: $(cat "$(PL)")"
grep -q '+ Files: src/wide.txt' "$WORK/out" || die "freeze prints the drift: $(out)"
pass "freeze after sessions approves the lists as pinned and shows the drift"

echo "all $PASS checks passed"
