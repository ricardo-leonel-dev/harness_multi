#!/usr/bin/env bash
# lean_mode_test.sh — end-to-end check of the lean flow's harness pieces in
# scripts/harness.sh, run against a throwaway project (with lean/ copied in).
#
#   1. Older harness.db files gain the mode columns; add-feature --mode /
#      --approval and set-mode record them, refuse invalid values, and set-mode
#      is refused once the plan is approved.
#   2. claim refuses a risk feature, or a normal one with --approval, until
#      approve-plan; a normal one without it claims at once; a feature without a
#      mode claims and closes exactly as before (and refuses log-out --lean).
#   3. approve-plan refuses what it can't approve and, in risk mode, freezes the
#      acceptance tests into the feature and into ~/.cache/harness/<slug>/frozen.
#   4. log-out --lean closes a normal feature only when lean/gate.sh passes,
#      logging each refusal; a feature with a mode refuses the plain and --quick
#      log-out.
#   5. Risk mode also needs the review report, a reviewer that changed nothing,
#      the frozen acceptance tests untouched and the ~/.cache manifest unchanged.
#   6. The close path follows the mode: --quick is refused for a small feature
#      with a mode; set-mode is refused after a reviewer verdict or on hold and
#      clears a quick/lean pass; --lean refuses requested changes; a lean pass
#      never closes a feature without a mode.
#
# Usage: bash tests/lean_mode_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

P="$WORK/p"
mkdir -p "$P/scripts" "$P/src" "$P/tests" "$P/docs/features" "$WORK/home"
cp "$TOOLKIT_DIR"/scripts/*.sh "$TOOLKIT_DIR/scripts/agent_usage.py" "$P/scripts/"
cp -R "$TOOLKIT_DIR/lean" "$P/lean"
echo '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state","verify_command":"bash run_tests.sh"}' > "$P/.harness.json"
sqlite3 "$P/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql"
sqlite3 "$P/harness.db" "INSERT INTO projects (id, slug) VALUES ('p1','t');"

# A tiny suite the gate can run: every tests/*_test.sh, or the files given.
cat > "$P/run_tests.sh" <<'SH'
assert() { "$@" >/dev/null 2>&1 || { echo "FAIL: $*"; exit 1; }; }
[ $# -gt 0 ] || set -- tests/*_test.sh
rc=0
for f in "$@"; do ( . "./$f" ) || rc=1; done
[ "$rc" = 0 ] && echo "suite passes"
exit "$rc"
SH
printf 'hello\n' > "$P/src/app.txt"
# Indented: lean/gate.sh's removed-assertion pattern needs a character before the keyword.
printf '  assert grep -q hello src/app.txt\n  assert test -f run_tests.sh\n' > "$P/tests/app_test.sh"
printf 'progress/\nharness.db\nscripts/\nstate/\n.harness.json\nlean/\n' > "$P/.gitignore"

# Mirror sync stub: counts calls (log-out syncs after every close).
SYNCS="$WORK/syncs"; : > "$SYNCS"
printf '#!/usr/bin/env bash\necho sync >> "%s"\n' "$SYNCS" > "$P/scripts/sync_postgres.sh"
syncs() { wc -l < "$SYNCS" | tr -d ' '; }
CACHE="$WORK/home/.cache/harness/t"
H() { (cd "$P" && HOME="$WORK/home" HARNESS_AGENT=implementer ANTHROPIC_MODEL= HARNESS_HUMAN_USER= bash scripts/harness.sh "$@") 2>&1; }
q() { sqlite3 "$P/harness.db" "$1"; }
g() { (cd "$P" && git -c user.email=t@t -c user.name=t "$@"); }
doc() { # doc <name> <files...> [-- <changed tests...>]
  local name="$1"; shift
  { echo "# $name"; echo; echo "**Files**"
    while [ $# -gt 0 ] && [ "$1" != -- ]; do echo "- \`$1\`: why"; shift; done
    echo; echo "**Changed tests**"
    [ $# -gt 0 ] && shift
    while [ $# -gt 0 ]; do echo "- \`$1\`: why"; shift; done
  } > "$P/docs/features/$name.md"
}
lean_out() { H log-out --lean --changes src/app.txt --verification v --closure c; }
refused() { # refused <pattern> <what> — log-out --lean must refuse, saying <pattern>
  local out; out=$(lean_out) && die "$2: log-out --lean should refuse"
  grep -q -- "$1" <<<"$out" || die "$2: expected '$1' in: $out"
}
g init -q && g add -A && g commit -qm base || die "git setup"

echo "1. schema and mode"
q "ALTER TABLE features DROP COLUMN mode; ALTER TABLE features DROP COLUMN plan_approval;
   ALTER TABLE features DROP COLUMN plan_approved_by; ALTER TABLE features DROP COLUMN plan_approved_at;
   ALTER TABLE features DROP COLUMN plan_frozen;"
H status >/dev/null || die "status on an old db"
q "SELECT mode, plan_approval, plan_approved_by, plan_approved_at, plan_frozen FROM features LIMIT 0;" \
  || die "the migration should add the mode columns"
pass "older harness.db gains the mode columns"
H add-feature --name plain --title Plain >/dev/null || die "add plain"
H add-feature --name n1 --title N1 --mode normal >/dev/null || die "add n1"
H add-feature --name n2 --title N2 --mode normal --approval >/dev/null || die "add n2"
H add-feature --name r0 --title R0 --mode risk >/dev/null || die "add r0"
H add-feature --name r1 --title R1 --mode risk >/dev/null || die "add r1"
H add-feature --name m --title M >/dev/null || die "add m"
[ "$(q "SELECT group_concat(COALESCE(mode,'-') || plan_approval, ',') FROM (SELECT mode, plan_approval FROM features ORDER BY id);")" \
  = "-0,normal0,normal1,risk1,risk1,-0" ] || die "modes not recorded: $(q "SELECT name, mode, plan_approval FROM features;")"
out=$(H add-feature --name r2 --title R2 --mode risk --approval 2>&1) || die "add-feature --mode risk --approval should warn, not refuse: $out"
grep -q '^\[WARN\].*risk always requires approval; --approval ignored' <<<"$out" || die "risk + --approval should warn: $out"
[ "$(q "SELECT mode || plan_approval FROM features WHERE name='r2';")" = risk1 ] || die "risk + --approval should store what --mode risk stores"
q "DELETE FROM features WHERE name='r2';"
for bad in "--mode fast" "--approval" "--mode normal --sdd" "--sdd --mode risk"; do
  # shellcheck disable=SC2086
  out=$(H add-feature --name bad --title Bad $bad) && die "add-feature $bad should be refused"
done
[ -z "$(q "SELECT 1 FROM features WHERE name='bad';")" ] || die "a refused add-feature left a row"
H set-mode m risk >/dev/null && [ "$(q "SELECT mode || plan_approval FROM features WHERE name='m';")" = risk1 ] || die "set-mode risk"
H set-mode m normal --approval >/dev/null && [ "$(q "SELECT mode || plan_approval FROM features WHERE name='m';")" = normal1 ] || die "set-mode normal --approval"
H set-mode m none >/dev/null && [ "$(q "SELECT COALESCE(mode,'-') || plan_approval FROM features WHERE name='m';")" = -0 ] || die "set-mode none"
out=$(H set-mode m bogus) && die "set-mode bogus should be refused"
out=$(H set-mode m risk --approval 2>&1) || die "set-mode risk --approval should warn, not refuse: $out"
grep -q '^\[WARN\].*--approval ignored' <<<"$out" && [ "$(q "SELECT mode || plan_approval FROM features WHERE name='m';")" = risk1 ] \
  || die "set-mode risk --approval: $out"
H set-mode m none >/dev/null || die "set-mode none after risk"
out=$(H set-mode m none --approval) && die "set-mode none --approval should be refused"
out=$(H status)
grep -q 'lean mode' <<<"$out" && grep -q 'plan approval pending' <<<"$out" && grep -q 'no plan approval needed' <<<"$out" \
  || die "status should show modes: $out"
pass "add-feature --mode/--approval and set-mode round-trip; invalid values refused; status shows them"

echo "2. claim"
out=$(H claim r0) && die "a risk feature must not claim before approve-plan"
grep -q 'approve-plan r0' <<<"$out" || die "risk refusal should name approve-plan: $out"
out=$(H claim n2) && die "a normal --approval feature must not claim before approve-plan"
grep -q 'approve-plan n2' <<<"$out" || die "normal refusal should name approve-plan: $out"
[ "$(q "SELECT count(*) FROM features WHERE status='in_progress';")" = 0 ] || die "a refused claim changed a status"
H claim plain >/dev/null || die "a feature without a mode should claim"
out=$(H log-out --lean --changes src/app.txt --verification v --closure c) && die "--lean must refuse a feature without a mode"
grep -q 'only for features with a lean mode' <<<"$out" || die "mode-less --lean reason: $out"
H record-review approved --by human:tester >/dev/null && H record-init pass >/dev/null
H log-out --changes src/app.txt --verification v --closure c >/dev/null || die "a mode-less feature should close as before"
H claim n1 >/dev/null || die "a normal feature without --approval should claim at once"
H block n1 parked by the test >/dev/null || die "block n1"
pass "claim waits for approve-plan on risk and normal --approval; others claim as before"

echo "3. approve-plan"
out=$(H approve-plan m --by Tester) && die "approve-plan on a feature without a mode"
grep -q 'no lean mode' <<<"$out" || die "no-mode reason: $out"
out=$(H approve-plan n1 --by Tester) && die "approve-plan on a normal feature without --approval"
grep -q 'without plan approval' <<<"$out" || die "no-approval reason: $out"
out=$(H approve-plan n2 --by Tester) && die "approve-plan without the plan document"
grep -q 'docs/features/n2.md is missing' <<<"$out" || die "missing-doc reason: $out"
doc n2 src/app.txt
out=$(H approve-plan n2) && die "approve-plan without a human name"
grep -q 'needs the approving human' <<<"$out" || die "no-name reason: $out"
out=$(H approve-plan n2 --by user) && die "approve-plan --by user"
q "UPDATE features SET status='blocked' WHERE name='n2';"
out=$(H approve-plan n2 --by Tester) && die "approve-plan on a feature that is not pending"
grep -q 'is blocked' <<<"$out" || die "not-pending reason: $out"
q "UPDATE features SET status='pending' WHERE name='n2';"
H approve-plan n2 --by Tester >/dev/null || die "approve-plan n2"
[ "$(q "SELECT plan_approved_by || ':' || (plan_approved_at IS NOT NULL) || ':' || (plan_frozen IS NULL) FROM features WHERE name='n2';")" = "Tester:1:1" ] \
  || die "approval not recorded on n2"
out=$(H approve-plan n2 --by Tester) && die "a second approve-plan"
grep -q 'already approved' <<<"$out" || die "already-approved reason: $out"
out=$(H set-mode n2 none) && die "set-mode after approval"
grep -q 'void that approval' <<<"$out" || die "set-mode-after-approval reason: $out"
grep -q 'plan approved by Tester' <<<"$(H status)" || die "status should show the approver"
doc r1 src/app.txt
out=$(H approve-plan r1 --by Tester) && die "risk approve-plan without acceptance tests"
grep -q 'no acceptance tests for r1' <<<"$out" || die "no-acceptance reason: $out"
mkdir -p "$P/acceptance" && printf 'assert grep -q risk src/app.txt\n' > "$P/acceptance/r1.test.sh"
H approve-plan r1 --by Tester >/dev/null || die "approve-plan r1"
expected=$(cd "$P" && shasum -a 256 acceptance/r1.test.sh)
[ "$(q "SELECT plan_frozen FROM features WHERE name='r1';")" = "$expected" ] || die "plan_frozen should hold the manifest"
[ "$(cat "$CACHE/frozen/r1.sha")" = "$expected" ] || die "the manifest should be written under ~/.cache"
H snapshot >/dev/null && grep -q '^mode: risk' "$P/state/features/005-r1.md" && grep -q '^plan: approved by Tester' "$P/state/features/005-r1.md" \
  && ! grep -q '^mode:' "$P/state/features/001-plain.md" || die "snapshot should show the mode only where set"
g add -A && g commit -qm plans >/dev/null
pass "approve-plan refuses what it can't approve; risk freezes the acceptance tests (DB and ~/.cache)"

echo "4. log-out --lean, normal mode"
H claim n2 >/dev/null || die "an approved normal --approval feature should claim"
printf 'hello world\n' > "$P/src/app.txt"
refused_from=$(syncs)   # every close refused below (plain, --quick, --lean) must not sync
out=$(H log-out --changes src/app.txt --verification v --closure c) && die "a mode feature must refuse the reviewer path"
grep -q "close it with 'log-out --lean'" <<<"$out" || die "plain refusal: $out"
out=$(H log-out --quick --changes src/app.txt --verification v --closure c) && die "a mode feature must refuse --quick"
grep -q "close it with 'log-out --lean'" <<<"$out" || die "--quick refusal: $out"
mv "$P/lean/gate.sh" "$P/lean/gate.sh.off"
refused 'the lean gate is missing' "no gate"
mv "$P/lean/gate.sh.off" "$P/lean/gate.sh"
mv "$P/docs/features/n2.md" "$WORK/n2.md"
refused 'MISSING: docs/features/n2.md' "missing doc"
mv "$WORK/n2.md" "$P/docs/features/n2.md"
grep -q 'LEAN: refused' <<<"$(q "SELECT entry FROM session_log_entries;")" || die "a refusal must be logged"
printf 'bye\n' > "$P/src/app.txt"
refused 'SUITE FAILS' "failing suite"
printf 'hello world\n' > "$P/src/app.txt"; printf 'x\n' > "$P/src/extra.txt"
refused 'src/extra.txt' "file outside **Files**"
rm "$P/src/extra.txt"
printf '  assert grep -q hello src/app.txt\n' > "$P/tests/app_test.sh"
refused 'ASSERTION LINES REMOVED FROM tests/app_test.sh' "removed assertion not listed"
doc n2 src/app.txt tests/app_test.sh -- tests/app_test.sh
out=$(lean_out) && die "closing without ./init.sh in the session"
grep -q 'lean gate passed' <<<"$out" && grep -q 'init.sh has not run' <<<"$out" || die "gate pass then init refusal expected: $out"
[ "$(syncs)" = "$refused_from" ] || die "a refused close (plain, --quick, --lean) must not sync the mirror"
H record-init pass >/dev/null
before=$(syncs)
out=$(lean_out) || die "a clean change with the removed assertion listed should close: $out"
[ "$(syncs)" = $((before + 1)) ] || die "log-out --lean should sync the mirror once"
[ "$(q "SELECT review_status || '|' || reviewed_by FROM session_log WHERE feature_id=(SELECT id FROM features WHERE name='n2');")" = "lean|harness (lean gate)" ] \
  || die "review_status should be lean"
grep -q 'LEAN: passed (mode normal) — ALL CHECKS PASS' <<<"$(q "SELECT entry FROM session_log_entries;")" || die "the pass and the gate's last line must be logged"
[ "$(q "SELECT status FROM features WHERE name='n2';")" = done ] || die "n2 should be done"
g add -A && g commit -qm n2 >/dev/null
pass "log-out --lean refuses each failing check (logged) and closes once the gate and ./init.sh pass"

echo "5. log-out --lean, risk mode"
H claim r1 >/dev/null || die "an approved risk feature should claim"
printf 'hello risk\n' > "$P/src/app.txt"
H record-init pass >/dev/null
refused 'r1.review.md' "missing review report"
printf 'Findings: none\n' > "$P/docs/features/r1.review.md"
refused "has no 'VERDICT" "review without a verdict"
printf 'Findings: none\nNO VERDICT: approve yet\n' > "$P/docs/features/r1.review.md"
refused "has no 'VERDICT" "verdict text not at the start of a line"
printf 'Findings: one\nVERDICT: changes\n' > "$P/docs/features/r1.review.md"
mkdir -p "$CACHE/lean" && echo '{"verdict":"changes","reviewer_changed_files":true}' > "$CACHE/lean/r1.review.json"
refused 'reviewer changed files' "reviewer_changed_files"
echo '{"verdict":"changes","reviewer_changed_files":false}' > "$CACHE/lean/r1.review.json"
printf '# tampered\n' >> "$P/acceptance/r1.test.sh"
refused 'FROZEN ACCEPTANCE TESTS CHANGED' "tampered acceptance file"
g checkout -q -- acceptance/r1.test.sh
(cd "$P" && printf '# tampered\n' >> acceptance/r1.test.sh && shasum -a 256 acceptance/r1.test.sh > "$CACHE/frozen/r1.sha")
g checkout -q -- acceptance/r1.test.sh                    # the files are intact; only the manifest was rewritten
refused 'someone rewrote it' "rewritten ~/.cache manifest"
(cd "$P" && shasum -a 256 acceptance/r1.test.sh > "$CACHE/frozen/r1.sha")
H record-init pass >/dev/null
out=$(lean_out) || die "risk mode with everything in order should close: $out"
[ "$(q "SELECT status FROM features WHERE name='r1';")" = done ] || die "r1 should be done"
pass "risk mode also needs the review report, an unchanged tree from the reviewer and the frozen tests intact"

echo "6. close path tied to the mode"
g add -A && g commit -qm r1 >/dev/null
H add-feature --name s1 --title S1 --size small --mode normal >/dev/null || die "add s1"
H add-feature --name x1 --title X1 >/dev/null || die "add x1"
H add-feature --name x2 --title X2 --mode normal >/dev/null || die "add x2"
doc s1 src/app.txt; doc x1 src/app.txt; doc x2 src/app.txt
g add -A && g commit -qm docs >/dev/null
H claim s1 >/dev/null || die "claim s1"
printf 'hello small\n' > "$P/src/app.txt"
H record-init pass >/dev/null
out=$(H log-out --quick --changes src/app.txt --verification v --closure c) && die "a small feature with a mode must refuse --quick"
grep -q "close it with 'log-out --lean'" <<<"$out" || die "small --quick refusal should be about the mode: $out"
H block s1 parked by the test >/dev/null || die "block s1"
g checkout -q -- src/app.txt
pass "a small feature with a mode refuses --quick because of its mode"

H claim x1 >/dev/null || die "claim x1"
printf 'hello x1\n' > "$P/src/app.txt"
H record-review changes-requested --by human:tester >/dev/null || die "record changes-requested on x1"
out=$(H set-mode x1 normal) && die "set-mode after a reviewer verdict must be refused"
grep -q "already recorded 'changes_requested'" <<<"$out" || die "set-mode-after-verdict reason: $out"
[ -z "$(q "SELECT mode FROM features WHERE name='x1';")" ] || die "a refused set-mode changed the mode"
q "UPDATE features SET mode='normal' WHERE name='x1';"        # as if the mode slipped in anyway
H record-init pass >/dev/null
out=$(lean_out) && die "log-out --lean must refuse a session with requested changes"
grep -q 'a reviewer already requested changes' <<<"$out" || die "--lean changes-requested reason: $out"
[ "$(q "SELECT status FROM features WHERE name='x1';")" = in_progress ] || die "x1 must stay open"
q "UPDATE features SET mode=NULL WHERE name='x1';"
H hold the user rejected an escalation >/dev/null || die "hold x1"
q "UPDATE session_log SET review_status=NULL WHERE feature_id=(SELECT id FROM features WHERE name='x1');"
out=$(H set-mode x1 normal) && die "set-mode on a held session must be refused"
grep -q 'is on hold' <<<"$out" || die "set-mode-on-hold reason: $out"
H unhold >/dev/null && H block x1 parked by the test >/dev/null || die "park x1"
g checkout -q -- src/app.txt
pass "set-mode refuses after a reviewer verdict or on hold; --lean refuses requested changes"

H claim x2 >/dev/null || die "claim x2"
printf 'hello x2\n' > "$P/src/app.txt"
out=$(lean_out) && die "x2 closing without ./init.sh"
grep -q 'lean gate passed' <<<"$out" || die "x2 gate should pass first: $out"
printf 'unreviewed\n' > "$P/src/other.txt"
H set-mode x2 none >/dev/null || die "set-mode x2 none"
[ -z "$(q "SELECT review_status FROM session_log WHERE feature_id=(SELECT id FROM features WHERE name='x2');")" ] \
  || die "set-mode should clear the stale lean pass"
H record-init pass >/dev/null
out=$(H log-out --changes src/app.txt src/other.txt --verification v --closure c) && die "a cleared lean pass must not close x2"
grep -q 'no recorded reviewer approval' <<<"$out" || die "cleared-pass reason: $out"
q "UPDATE session_log SET review_status='lean' WHERE feature_id=(SELECT id FROM features WHERE name='x2');"   # a stale pass left behind
out=$(H log-out --changes src/app.txt src/other.txt --verification v --closure c) && die "a stale lean pass must not close a mode-less feature"
grep -q "doesn't apply to feature x2" <<<"$out" || die "stale-lean reason: $out"
[ "$(q "SELECT status FROM features WHERE name='x2';")" = in_progress ] || die "x2 must stay open"
pass "set-mode clears a gate pass from the other path; a lean pass never closes a mode-less feature"

H block x2 parked by the test >/dev/null || die "park x2"
rm -f "$P/src/other.txt"; g checkout -q -- src/app.txt
H add-feature --name x3 --title X3 >/dev/null || die "add x3"
doc x3 src/app.txt; g add -A && g commit -qm docs-x3 >/dev/null
H claim x3 >/dev/null || die "claim x3"
printf 'hello x3\n' > "$P/src/app.txt"
for args in "normal --approval" "risk"; do
  out=$(H set-mode x3 $args) && die "set-mode x3 $args on an in_progress feature must be refused"
  grep -q 'can only be set on a pending feature' <<<"$out" || die "set-mode x3 $args reason: $out"
done
[ -z "$(q "SELECT mode FROM features WHERE name='x3';")" ] || die "a refused set-mode changed x3's mode"
H set-mode x3 normal >/dev/null || die "set-mode x3 normal (no approval) should still work after the claim"
q "UPDATE features SET plan_approval=1 WHERE name='x3';"   # as if the approval requirement slipped in anyway
H record-init pass >/dev/null
out=$(lean_out) && die "log-out --lean must refuse an approval-required feature without an approved plan"
grep -q 'needs an approved plan and has none' <<<"$out" || die "unapproved-plan reason: $out"
q "UPDATE features SET mode='risk', plan_approval=0 WHERE name='x3';"
out=$(lean_out) && die "log-out --lean must refuse a risk feature without an approved plan"
grep -q 'needs an approved plan and has none' <<<"$out" || die "unapproved-risk reason: $out"
[ "$(q "SELECT status FROM features WHERE name='x3';")" = in_progress ] || die "x3 must stay open"
pass "an approval-requiring mode can't be added after the claim, and --lean never closes it unapproved"

echo "all $PASS checks passed"
