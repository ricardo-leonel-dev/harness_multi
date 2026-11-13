#!/usr/bin/env bash
# lean_leader_actions_test.sh — the plan's **Leader actions** section (what a session needs and
# only the leader or the user can do) against a throwaway project with the real scripts/harness.sh,
# lean/ copied in with a stub adapter in place of claude (no model is ever called) and the suite
# run unsandboxed (LEAN_GATE_UNSANDBOXED=1).
#
#   1. a session appends an unchecked item: chain prints it in a `leader actions` block before the
#      `next:` line (CHAIN: PASS stays last), the step logs it; log-out --lean refuses, listing it,
#      logged, the feature stays open; once the leader checks it off (with a note) the plan's pinned
#      lists don't move (the gate passes, no PLAN LISTS CHANGED) and log-out --lean closes it.
#   2. a feature without the section: no block, log-out --lean closes it as before.
#   3. what a session does to the section during the chain is printed even when nothing is left
#      open: an item it added and checked itself, a leader's item it checked off, a leader's item
#      it removed; items the leader had checked before the chain are not repeated.
#   4. the motivating case, a `.harness.json` change (tracked in git): after the leader's edit every
#      step and log-out --lean stop at the changed hashes, naming lean/run.sh accept-config (never
#      "undo" / "delete"; log-out says it once, with the content diff, without running the gate);
#      accept-config is refused inside a session, prints the file, re-pins and
#      logs; the gate then leaves .harness.json out of the **Files** check, a later unaccepted
#      change to it still fails the gate; with the item checked off log-out --lean closes.
#   5. an item in the review report (docs/features/<name>.review.md) is printed and refused naming
#      that file.
#   6. accept-config with no session open shows the content diff and is recorded as a feature note.
#   7. a stub session rewrites verify_command to `true` during the chain: the chain fails saying a
#      session changed a harness file, with the content diff, and tells the leader to restore it
#      (no accept-config hint); on the approved plan accept-config is refused without --by (and
#      with --by user), then accepted and logged with --by <name>.
#   8. lean_mask (the config diff's masking), JSON (jq) and non-JSON (perl) alike: secret-named keys,
#      URL passwords (also with an empty user, `redis://:pw@h`), NAME=value with a secret-looking
#      NAME (a quoted value with spaces masked whole), `Bearer <token>` in any case; ordinary text
#      (a URL with a port, the word "password") is left alone.
#
# Usage: bash tests/lean_leader_actions_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

mkdir -p "$WORK/home"
export HOME="$WORK/home" LEAN_GATE_UNSANDBOXED=1 GIT_CONFIG_GLOBAL=/dev/null
export LEAN_CLAUDE_TMP="$WORK/no-claude-tmp"
PATH=$(printf '%s\n' "$PATH" | tr ':' '\n' | grep -vF "$HOME/" | paste -sd: -)

P="$WORK/p"
mkdir -p "$P/scripts" "$P/src" "$P/tests" "$P/docs/features"
cp "$TOOLKIT_DIR"/scripts/*.sh "$TOOLKIT_DIR/scripts/agent_usage.py" "$P/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$P/scripts/sync_postgres.sh"   # no mirror
cp -R "$TOOLKIT_DIR/lean" "$P/lean"
echo '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state","verify_command":"bash run_tests.sh","lean":{"implementer":"claude","reviewer":"claude:other"}}' > "$P/.harness.json"
sqlite3 "$P/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql"
sqlite3 "$P/harness.db" "INSERT INTO projects (id, slug) VALUES ('p1','t');"

# The stub adapter (every tool): runs $SCN/<step> in the project when present and writes a result
# JSON like claude -p's.
export SCN="$WORK/scn"
cat > "$P/lean/adapters/claude.sh" <<'SH'
#!/usr/bin/env bash
project="$1" result="${6:-}"
st=$(basename "$result"); st="${st#*.}"; st="${st%%.*}"
cd "$project" || exit 1
[ -f "$SCN/$st" ] && . "$SCN/$st"
printf '{"is_error":false,"num_turns":3,"total_cost_usd":0.25}\n' > "$result"
SH
chmod +x "$P/lean/adapters/claude.sh"
cp "$P/lean/adapters/claude.sh" "$P/lean/adapters/claude-mini.sh"

cat > "$P/run_tests.sh" <<'SH'
[ $# -gt 0 ] || set -- tests/*_test.sh
rc=0
for f in "$@"; do bash "$f" || rc=1; done
[ "$rc" = 0 ] && echo "suite passes"
exit "$rc"
SH
printf 'todo\n' > "$P/src/app.txt"
printf '  grep -q . src/app.txt || exit 1\n' > "$P/tests/app_test.sh"
printf 'progress/\nharness.db\nscripts/\nstate/\n.harness.json\nlean/\n' > "$P/.gitignore"

H() { (cd "$P" && HARNESS_AGENT=implementer ANTHROPIC_MODEL= HARNESS_HUMAN_USER= bash scripts/harness.sh "$@") 2>&1; }
q() { sqlite3 "$P/harness.db" "$1"; }
g() { git -C "$P" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
scn() { rm -rf "$SCN"; mkdir -p "$SCN"; printf '%s\n' "$2" > "$SCN/$1"; }
chain() { (cd "$P" && bash lean/run.sh chain "$1") > "$WORK/out" 2>&1; }
out() { cat "$WORK/out"; }
lean_out() { H log-out --lean --changes src/app.txt "docs/features/$1.md" --verification v --closure c; }
# plan <name> [extra markdown] — the plan: **Files** then whatever follows.
plan() { printf '# %s\n\n**Files**\n- `src/app.txt`\n%s' "$1" "${2:-}" > "$P/docs/features/$1.md"; }

g init -q && g add -A && g commit -qm base || die "git setup"

echo "1. a session asks the leader for something"
H add-feature --name a --title A --mode normal >/dev/null || die "add a"
plan a
H claim --agent leader a >/dev/null || die "claim a: $(H claim --agent leader a)"
# The item names paths and sits right after **Files**: it must not read as part of that list.
scn implement 'printf "done a\n" > src/app.txt
printf "\n## Decisions while implementing\n- added tests\n\n## Leader actions\n- [ ] add tests/new_test.sh to verify_command in .harness.json\n" >> docs/features/a.md'
chain a || die "chain a should pass: $(out)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: PASS" ] || die "CHAIN: PASS stays last: $(out)"
tail -2 "$WORK/out" | head -1 | grep -q '^next: scripts/harness.sh log-out --lean' || die "next: right before CHAIN: PASS: $(out)"
grep -q '^leader actions (docs/features/a.md): .*log-out --lean refuses while one is open' "$WORK/out" || die "leader actions header: $(out)"
grep -qxF '  - [ ] add tests/new_test.sh to verify_command in .harness.json' "$WORK/out" || die "the open item: $(out)"
[ "$(grep -n '^leader actions' "$WORK/out" | cut -d: -f1)" -lt "$(grep -n '^next:' "$WORK/out" | cut -d: -f1)" ] || die "block before next: $(out)"
grep -q 'PLAN LISTS CHANGED' "$WORK/out" && die "the section must not move the pinned lists: $(out)"
logs=$(sed -n 's/^logs: \([^ ]*\) .*/\1/p' "$WORK/out")
grep -q '\[lean\] leader actions open in docs/features/a.md' "$logs"/*-implement.log || die "the step logs the open items: $(cat "$logs"/*-implement.log)"
pass "chain prints the session's open item before next: (and the step logs it)"

out=$(lean_out a) && die "log-out --lean must refuse with an open leader action: $out"
grep -q 'open \*\*Leader actions\*\*' <<<"$out" && grep -qF -- '- [ ] add tests/new_test.sh to verify_command in .harness.json' <<<"$out" \
  && grep -q "mark it '- \[x\]'" <<<"$out" || die "refusal message: $out"
grep -q 'lean gate passed' <<<"$out" && die "the gate should not run on that refusal: $out"
q "SELECT entry FROM session_log_entries;" | grep -q 'LEAN: refused — leader actions open: add tests/new_test.sh' || die "the refusal must be logged"
[ "$(q "SELECT status FROM features WHERE name='a';")" = in_progress ] || die "a must stay open"
pass "log-out --lean refuses while an item is open, listing it (logged)"

sed -i.bak 's/^- \[ \] add tests/- [x] add tests/; s/\.harness\.json$/.harness.json (done: verify_command runs it)/' "$P/docs/features/a.md" && rm -f "$P/docs/features/a.md.bak"
grep -q '^- \[x\] add tests' "$P/docs/features/a.md" || die "test setup: check-off"
out=$( (cd "$P" && bash lean/run.sh gate a) 2>&1) || die "the gate after the check-off: $out"
grep -q 'PLAN LISTS CHANGED' <<<"$out" && die "checking an item off must not trip the plan pin: $out"
out=$(lean_out a) || die "log-out --lean once every item is checked: $out"
grep -q 'lean gate passed' <<<"$out" || die "close a: $out"
[ "$(q "SELECT status FROM features WHERE name='a';")" = done ] || die "a should be done"
g add -A && g commit -qm a >/dev/null
pass "once the leader checks it off (with a note) the pin holds and log-out --lean closes"

echo "2. no section: unchanged"
H add-feature --name b --title B --mode normal >/dev/null || die "add b"
plan b
H claim --agent leader b >/dev/null || die "claim b"
scn implement 'printf "done b\n" > src/app.txt'
chain b || die "chain b: $(out)"
grep -qi 'leader actions' "$WORK/out" && die "no block without the section: $(out)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: PASS" ] || die "b last line: $(out)"
out=$(lean_out b) || die "log-out --lean without the section: $out"
[ "$(q "SELECT status FROM features WHERE name='b';")" = done ] || die "b should be done"
g add -A && g commit -qm b >/dev/null
pass "a plan without **Leader actions** chains and closes as before"

echo "3. what a session checks off or removes during the chain is still printed"
H add-feature --name c --title C --mode normal >/dev/null || die "add c"
plan c '
## Leader actions
- [ ] install libfoo
- [ ] create the staging bucket
- [x] already settled before (done: leader)
'
H claim --agent leader c >/dev/null || die "claim c"
scn implement 'printf "done c\n" > src/app.txt
sed -i.bak "s/^- \[ \] install libfoo/- [x] install libfoo/; /staging bucket/d" docs/features/c.md && rm -f docs/features/c.md.bak
printf -- "- [x] set lean.acceptance_command\n" >> docs/features/c.md'
chain c || die "chain c: $(out)"
grep -q '^leader actions (docs/features/c.md)' "$WORK/out" || die "block when nothing is left open but sessions touched it: $(out)"
grep -qxF '  - [x] set lean.acceptance_command  (checked during this chain by a session: check it yourself)' "$WORK/out" || die "added and checked by the session: $(out)"
grep -qxF '  - [x] install libfoo  (checked during this chain by a session: check it yourself)' "$WORK/out" || die "checked off by the session: $(out)"
grep -qxF '  - removed during this chain by a session: create the staging bucket' "$WORK/out" || die "removed by the session: $(out)"
grep -q 'already settled before' "$WORK/out" && die "an item checked before the chain is not repeated: $(out)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: PASS" ] || die "c last line: $(out)"
pass "items a session added-and-checked, checked off or removed during the chain are printed"
out=$(lean_out c) || die "close c: $out"
g add -A && g commit -qm c >/dev/null

echo "4. the leader edits .harness.json for an item: accept-config"
sed -i.bak '/^\.harness\.json$/d' "$P/.gitignore" && rm -f "$P/.gitignore.bak"
g add -A && g commit -qm "track .harness.json" >/dev/null || die "track .harness.json"
H add-feature --name d --title D --mode normal >/dev/null || die "add d"
plan d
out=$(H claim --agent leader d) || die "claim d: $out"
pin="$(cd "$P" && bash -c '. lean/lib.sh; lean_state_dir "$(pwd)"')/lean/d/trusted.sha"
[ -f "$pin" ] || die "claim pins the trusted hashes: $pin"
scn implement 'printf "done d\n" > src/app.txt
printf "\n## Leader actions\n- [ ] run tests/app_test.sh explicitly in verify_command\n" >> docs/features/d.md'
chain d || die "chain d: $(out)"
grep -qxF '  - [ ] run tests/app_test.sh explicitly in verify_command' "$WORK/out" || die "d item: $(out)"
# The leader does it: a deliberate .harness.json edit, then checks the item off.
jq '.verify_command = "bash run_tests.sh tests/app_test.sh"' "$P/.harness.json" > "$WORK/hj" && cp "$WORK/hj" "$P/.harness.json"
sed -i.bak 's/^- \[ \] run tests/- [x] run tests/; s/verify_command$/verify_command (done: set it)/' "$P/docs/features/d.md" && rm -f "$P/docs/features/d.md.bak"
out=$( (cd "$P" && bash lean/run.sh gate d) 2>&1); rc=$?
[ "$rc" = 3 ] || die "a step stops at the changed hashes (exit 3): $rc $out"
grep -q 'lean/run.sh accept-config d' <<<"$out" || die "the step names accept-config: $out"
out=$(lean_out d) && die "log-out --lean before accept-config must refuse: $out"
grep -q 'harness-owned files changed' <<<"$out" && grep -q 'lean/run.sh accept-config d' <<<"$out" || die "refusal names accept-config: $out"
grep -qi 'undo\|delete ' <<<"$out" && die "no refusal tells the leader to undo or delete anything: $out"
grep -q 'CHANGED BUT NOT LISTED' <<<"$out" && die ".harness.json is not a **Files** matter: $out"
# Said once: the gate (itself a harness-owned file) isn't run to repeat it.
[ "$(grep -c 'accept-config d' <<<"$out")" = 1 ] && ! grep -q 'HARNESS-OWNED FILES CHANGED' <<<"$out" || die "the refusal is said once: $out"
grep -qF -- '+  "verify_command": "bash run_tests.sh tests/app_test.sh",' <<<"$out" || die "the refusal shows the content change: $out"
pass "after the leader's .harness.json edit: steps and log-out stop, naming accept-config (no undo)"

cp "$pin" "$WORK/pin.before"
out=$( (cd "$P" && LEAN_SESSION=1 bash lean/run.sh accept-config d) 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q 'inside a lean session' <<<"$out" || die "accept-config inside a session is refused: $rc $out"
cmp -s "$pin" "$WORK/pin.before" || die "a refused accept-config leaves the pin as it was"
out=$( (cd "$P" && bash lean/run.sh accept-config d) 2>&1) || die "accept-config: $out"
grep -qxF '  .harness.json' <<<"$out" || die "accept-config prints the changed file: $out"
cmp -s "$pin" "$WORK/pin.before" && die "accept-config re-pins"
q "SELECT entry FROM session_log_entries;" | grep -q 'lean accept-config d: .harness.json' || die "accept-config is logged"
out=$( (cd "$P" && bash lean/run.sh accept-config d) 2>&1) && grep -q 'nothing to accept' <<<"$out" || die "a second accept-config: nothing to accept: $out"
pass "accept-config: refused inside a session; prints, re-pins and logs the change"

out=$( (cd "$P" && bash lean/run.sh gate d) 2>&1) || die "the gate after accept-config: $out"
grep -q 'CHANGED BUT NOT LISTED' <<<"$out" && die "an accepted .harness.json is left out of the **Files** check: $out"
# A change nobody accepted (as if a session got past the write-deny) still fails the gate itself.
cp "$P/.harness.json" "$WORK/hj.accepted"
jq '.verify_command = "true"' "$WORK/hj.accepted" > "$P/.harness.json"
out=$( (cd "$P" && bash lean/gate.sh "$P" d) 2>&1) && die "the gate must fail on an unaccepted harness-owned change: $out"
grep -q 'HARNESS-OWNED FILES CHANGED SINCE PINNED' <<<"$out" && grep -qxF '  .harness.json' <<<"$out" || die "the gate names it: $out"
grep -q 'CHANGED BUT NOT LISTED' <<<"$out" && die "reported as harness-owned, not as a **Files** matter: $out"
cp "$WORK/hj.accepted" "$P/.harness.json"
out=$(lean_out d) || die "log-out --lean after accept-config: $out"
grep -q 'lean gate passed' <<<"$out" || die "close d: $out"
[ "$(q "SELECT status FROM features WHERE name='d';")" = done ] || die "d should be done"
g add -A && g commit -qm d >/dev/null
pass "after accept-config the gate passes; an unaccepted change still fails it; log-out --lean closes"

echo "5. an item in the review report names that file"
H add-feature --name e --title E --mode normal >/dev/null || die "add e"
plan e
H claim --agent leader e >/dev/null || die "claim e"
scn implement 'printf "done e\n" > src/app.txt
printf "# review\n\n## Leader actions\n- [ ] check the staging rows\n\nVERDICT: approve\n" > docs/features/e.review.md'
chain e || die "chain e: $(out)"
grep -qxF '  - [ ] check the staging rows  (in docs/features/e.review.md)' "$WORK/out" || die "chain names the review report: $(out)"
out=$(lean_out e) && die "log-out --lean must refuse: $out"
grep -qF -- '- [ ] check the staging rows  (in docs/features/e.review.md)' <<<"$out" || die "refusal names the review report: $out"
sed -i.bak 's/^- \[ \] check/- [x] check/' "$P/docs/features/e.review.md" && rm -f "$P/docs/features/e.review.md.bak"
out=$(H log-out --lean --changes src/app.txt docs/features/e.md docs/features/e.review.md --verification v --closure c) || die "close e: $out"
[ "$(q "SELECT status FROM features WHERE name='e';")" = done ] || die "e should be done"
pass "an item in the review report is printed and refused with its file"

echo "6. accept-config with no session open: recorded as a note on the feature"
jq '.lean.step_minutes = 20' "$P/.harness.json" > "$WORK/hj" && cp "$WORK/hj" "$P/.harness.json"
out=$( (cd "$P" && bash lean/run.sh accept-config d) 2>&1) || die "accept-config on a closed feature: $out"
grep -qF '+    "step_minutes": 20' <<<"$out" || die "accept-config shows the content change: $out"
q "SELECT entry FROM feature_notes;" | grep -q 'lean accept-config d: .harness.json' || die "logged as a feature note without a session: $(q 'SELECT entry FROM feature_notes;')"
g checkout -q -- .harness.json && (cd "$P" && bash lean/run.sh accept-config d) >/dev/null 2>&1 || die "restore d's pin"
pass "accept-config without an open session leaves a note on the feature"

echo "7. a session rewrites verify_command during the chain; an approved plan needs --by"
H add-feature --name f --title F --mode normal --approval >/dev/null || die "add f"
plan f
out=$(H approve-plan f --by Tester) || die "approve f: $out"
out=$(H claim --agent leader f) || die "claim f: $out"
fpin="$(dirname "$pin")/../f/trusted.sha"
[ -f "$fpin" ] && [ -f "$(dirname "$fpin")/pinned/.harness.json" ] || die "claim keeps a copy of .harness.json beside the pin"
cp "$fpin" "$WORK/fpin.before"
scn implement 'printf "done f\n" > src/app.txt
jq ".verify_command = \"true\"" .harness.json > .hj.tmp && mv .hj.tmp .harness.json'
chain f && die "chain f must fail: $(out)"
tail -1 "$WORK/out" | grep -q '^CHAIN: FAIL at review (a session changed harness-owned files during this chain: restore them' || die "the FAIL line names the session's change: $(out)"
grep -q '^harness-owned files changed during this chain (found at review): a session wrote them' "$WORK/out" || die "the session wording: $(out)"
grep -qxF '  .harness.json' "$WORK/out" || die "names the file: $(out)"
grep -qF -- '-  "verify_command": "bash run_tests.sh tests/app_test.sh",' "$WORK/out" && grep -qF -- '+  "verify_command": "true",' "$WORK/out" || die "shows the content diff: $(out)"
grep -q 'Restore them' "$WORK/out" || die "tells the leader to restore: $(out)"
grep -q 'If you or the user changed them on purpose' "$WORK/out" && die "no generic accept-config hint for a session's change: $(out)"
tail -1 "$WORK/out" | grep -q 'accept-config' && die "the FAIL line must not suggest accept-config: $(out)"
pass "a session's harness-file change during the chain: named as such, diff shown, restore (not accept)"

out=$(lean_out f) && die "log-out --lean must refuse while .harness.json differs from the pin: $out"
grep -qF -- '+  "verify_command": "true",' <<<"$out" || die "the refusal shows the content diff on the terminal: $out"
rec=$(q "SELECT entry FROM session_log_entries WHERE entry LIKE '[harness] LEAN: refused%' ORDER BY id DESC LIMIT 1;")
grep -qxF '  .harness.json' <<<"$rec" && grep -q 'content not recorded here' <<<"$rec" || die "the record names the file: $rec"
grep -q 'verify_command' <<<"$rec" && die "the record keeps no config content: $rec"
pass "log-out --lean on a harness-file change: diff on the terminal, only the paths in the record"

out=$( (cd "$P" && bash lean/run.sh accept-config f) 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'the plan of f was approved' <<<"$out" && grep -q 'accept-config f --by' <<<"$out" || die "accept-config on an approved plan without --by is refused: $rc $out"
grep -qF -- '+  "verify_command": "true",' <<<"$out" || die "the refusal shows the change first: $out"
out=$( (cd "$P" && bash lean/run.sh accept-config f --by user) 2>&1) && die "--by user is refused: $out"
cmp -s "$fpin" "$WORK/fpin.before" || die "a refused accept-config leaves the pin as it was"
out=$( (cd "$P" && bash lean/run.sh accept-config f --by Tester) 2>&1) || die "accept-config --by on an approved plan: $out"
cmp -s "$fpin" "$WORK/fpin.before" && die "accept-config --by re-pins"
grep -q '"verify_command": "true"' "$(dirname "$fpin")/pinned/.harness.json" || die "accept-config refreshes the kept copy"
q "SELECT entry FROM session_log_entries;" | grep -q 'lean accept-config f: .harness.json (approved by Tester)' || die "accept-config --by is logged with the approver"
pass "accept-config on an approved plan: refused without --by (or with 'user'), accepted and logged with it"

echo "8. lean_mask: the config diff never shows common secret shapes"
cat > "$WORK/m.json" <<'J'
{"verify_command":"REDIS_URL=redis://:rpw1@h:6379 DB_PASS='a sq1' API_TOKEN=\"b dq1\" curl -H \"Authorization: Bearer btok1\" postgres://u:upw1@h/db PGPASSWORD=pg1 bash run.sh","nested":{"x":["mongodb+srv://u:mpw1@h"]},"api_key":"kv1","note":"see http://example.com:8080/path and the password policy"}
J
printf '%s\n' "run redis://:rpw2@h DB_PASS=\"c dq2\" X_SECRET='d sq2'" "Authorization: bearer btok2 x" "url=postgres://u:upw2@h" "token: tk2" "plain http://example.com:8080/p" > "$WORK/m.txt"
for f in m.json m.txt; do
  out=$(. "$P/lean/lib.sh" && lean_mask "$WORK/$f") || die "lean_mask $f: $out"
  for s in rpw1 sq1 dq1 btok1 upw1 pg1 mpw1 kv1 rpw2 dq2 sq2 btok2 upw2 tk2; do
    grep -qF -- "$s" <<<"$out" && die "lean_mask $f shows $s: $out"
  done
  grep -qF 'example.com:8080/p' <<<"$out" || die "lean_mask $f keeps ordinary text: $out"
done
out=$(. "$P/lean/lib.sh" && lean_mask "$WORK/m.json")
grep -qF 'redis://:<masked>@h:6379 DB_PASS=<masked> API_TOKEN=<masked> curl -H \"Authorization: Bearer <masked>\"' <<<"$out" && grep -qF 'the password policy' <<<"$out" || die "lean_mask json shape: $out"
out=$(. "$P/lean/lib.sh" && lean_mask "$WORK/m.txt")
grep -qxF 'run redis://:<masked>@h DB_PASS=<masked> X_SECRET=<masked>' <<<"$out" && grep -qxF 'Authorization: bearer <masked> x' <<<"$out" || die "lean_mask text shape: $out"
pass "lean_mask: empty-user URL passwords, quoted values with spaces and Bearer tokens are masked (jq and perl)"

echo "PASS: $PASS checks"
