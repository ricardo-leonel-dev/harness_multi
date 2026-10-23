#!/usr/bin/env bash
# quick_path_test.sh — end-to-end check of the quick path, hold and learnings
# in scripts/harness.sh, run against a throwaway project in a temp dir.
#
#   1. Older harness.db files gain features.size, session_log.held_at and the
#      learnings table; add-feature --size / set-size record the size.
#   2. log-out --quick closes a small feature without a reviewer only when every
#      quick-gate signal is clean (files already uncommitted at claim count only what changed since), refuses (and logs why) otherwise, never
#      applies to normal features and never bypasses requested changes. A
#      normal close needs the approval and ./init.sh green on the exact tree it
#      closes (contents, so a commit doesn't invalidate either).
#      Tests kept out of git (.git/info/exclude) count toward that tree too.
#   3. hold keeps the slot: claim and log-out refuse until unhold.
#   4. learn caps notes at 300 characters; recall returns at most 5 ranked
#      matches; forget hides a note.
#
# Usage: bash tests/quick_path_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

P="$WORK/p"
mkdir -p "$P/scripts"
cp "$TOOLKIT_DIR"/scripts/*.sh "$TOOLKIT_DIR/scripts/agent_usage.py" "$P/scripts/"
echo '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state"}' > "$P/.harness.json"
sqlite3 "$P/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql"
sqlite3 "$P/harness.db" "INSERT INTO projects (id, slug) VALUES ('p1','t');"

H() { (cd "$P" && HOME="$WORK/home" HARNESS_AGENT=implementer ANTHROPIC_MODEL= bash scripts/harness.sh "$@") 2>&1; }
q() { sqlite3 "$P/harness.db" "$1"; }
g() { (cd "$P" && git -c user.email=t@t -c user.name=t "$@"); }
handoff() { mkdir -p "$P/progress/$1"; printf 'Cambio: %s\nArchivos: %s\nRisk: %s\nMotivo: test\n' "$2" "$3" "$4" > "$P/progress/$1/quick.md"; }

echo "1. schema and size"
q "ALTER TABLE features DROP COLUMN size; ALTER TABLE session_log DROP COLUMN held_at; DROP TABLE learnings;"
H status >/dev/null || die "status on an old db"
q "SELECT size FROM features LIMIT 0; SELECT held_at FROM session_log LIMIT 0; SELECT note FROM learnings LIMIT 0;" \
  || die "migration should add size, held_at and learnings"
pass "older harness.db gains size, held_at and learnings"
H add-feature --name tiny --title Tiny --size small >/dev/null || die "add-feature --size small"
H add-feature --name big --title Big >/dev/null || die "add-feature"
H add-feature --name other --title Other >/dev/null || die "add-feature other"
out=$(H add-feature --name bad --title Bad --size huge) && die "--size huge should be refused"
[ "$(q "SELECT group_concat(size) FROM (SELECT size FROM features ORDER BY id);")" = small,normal,normal ] || die "sizes not recorded"
H set-size big small >/dev/null && H set-size big normal >/dev/null || die "set-size"
[ "$(q "SELECT size FROM features WHERE name='big';")" = normal ] || die "set-size did not apply"
pass "add-feature --size and set-size record the size"

echo "2. log-out --quick"
g init -q && mkdir -p "$P/src" "$P/progress" && printf 'a\nb\n' > "$P/src/app.ts" && printf 'x\n' > "$P/src/other.ts"
printf 'progress/\nharness.db\nscripts/\nstate/\n.harness.json\n' > "$P/.gitignore"
g add -A && g commit -qm base || die "git setup"
H claim big >/dev/null || die "claim big"
out=$(H log-out --quick --changes src/app.ts --verification v --closure c) && die "--quick must refuse a normal feature"
grep -q 'only for features marked small' <<<"$out" || die "wrong refusal for a normal feature: $out"
pass "--quick refuses a normal-size feature"
printf 'a\nb\nc\n' > "$P/src/app.ts"
H record-review approved --by human:tester >/dev/null || die "record-review big"
out=$(H log-out --changes src/app.ts --verification v --closure c) && die "an approval without ./init.sh must not close"
grep -q 'init.sh has not run in this session' <<<"$out" || die "missing-init reason: $out"
H record-init fail >/dev/null
out=$(H log-out --changes src/app.ts --verification v --closure c) && die "an approval over a failed ./init.sh must not close"
grep -q 'the last ./init.sh failed' <<<"$out" || die "failed-init reason: $out"
H record-init pass >/dev/null && printf 'a\nb\n' > "$P/src/app.ts"
out=$(H log-out --changes src/app.ts --verification v --closure c) && die "changes after the approval must not close"
grep -q 'files changed after the reviewer approved them' <<<"$out" || die "stale-review reason: $out"
H record-review approved --by human:tester >/dev/null
out=$(H log-out --changes src/app.ts --verification v --closure c) && die "changes after the passing ./init.sh must not close"
grep -q 'files changed after the last passing ./init.sh' <<<"$out" || die "stale-init reason: $out"
H record-init none >/dev/null
out=$(H log-out --changes src/app.ts --verification v --closure c) || die "no verify_command should close with a warning: $out"
grep -q 'no verify_command' <<<"$out" || die "no-verify warning missing: $out"
pass "a normal close needs the approval and ./init.sh green on the exact tree it closes"

g add -A && g commit -qm big >/dev/null
H add-feature --name committed --title Committed >/dev/null && H claim committed >/dev/null || die "claim committed"
printf 'k\n' >> "$P/src/other.ts"
H record-init pass >/dev/null && H record-review approved --by human:tester >/dev/null
g add src/other.ts && g commit -qm wip >/dev/null
out=$(H log-out --changes src/other.ts --verification v --closure c) || die "committing the approved code must not invalidate init or the approval: $out"
g add -A && g commit -qm committed >/dev/null; printf 'x\nlocal\n' > "$P/src/other.ts"
H add-feature --name legacy --title Legacy >/dev/null && H claim legacy >/dev/null || die "claim legacy"
H record-init pass >/dev/null && H record-review approved --by human:tester >/dev/null
q "DELETE FROM session_log_entries WHERE entry LIKE '[harness] REVIEW: %';"
out=$(H log-out --changes src/other.ts --verification v --closure c) || die "an approval without a fingerprint should close with a warning: $out"
grep -q 'predates review fingerprints' <<<"$out" || die "legacy approval warning missing: $out"
pass "commits keep init and the approval valid; an older approval closes with a warning"

g add -A && g commit -qm legacy >/dev/null
H add-feature --name sandboxed --title Sandboxed >/dev/null && H claim sandboxed >/dev/null || die "claim sandboxed"
printf 'sandbox\n' >> "$P/src/other.ts"; printf 'new\n' > "$P/src/sandboxed.ts"
chmod -R a-w "$P/.git"                                    # Codex sandbox: .git is read-only
H record-init pass >/dev/null && H record-review approved --by human:tester >/dev/null
fp_ro=$(q "SELECT entry FROM session_log_entries WHERE entry LIKE '[harness] REVIEW: %' ORDER BY id DESC LIMIT 1;")
chmod -R u+w "$P/.git"
grep -q "fp=$(g rev-parse HEAD^{tree})" <<<"$fp_ro" && die "a read-only .git must not fingerprint the last commit instead of the files: $fp_ro"
out=$(H log-out --changes src/other.ts src/sandboxed.ts --verification v --closure c) \
  || die "init and approval recorded with a read-only .git must stay valid with a writable one: $out"
pass "fingerprints are the same with a read-only .git (Codex sandbox)"

mkdir -p "$P/tests" && printf 'one\n' > "$P/tests/app.test.ts" && printf '/tests/\n' >> "$P/.git/info/exclude"
H add-feature --name hidden_tests --title Hidden >/dev/null && H claim hidden_tests >/dev/null || die "claim hidden_tests"
printf 'hidden\n' >> "$P/src/other.ts"
H record-init pass >/dev/null && H record-review approved --by human:tester >/dev/null
printf 'two\n' > "$P/tests/app.test.ts"
out=$(H log-out --changes src/other.ts --verification v --closure c) && die "a git-ignored test changed after the approval must not close"
grep -q 'files changed after the reviewer approved them' <<<"$out" || die "stale-review reason for an ignored test: $out"
H record-init pass >/dev/null && H record-review approved --by human:tester >/dev/null
H log-out --changes src/other.ts --verification v --closure c >/dev/null || die "re-approved hidden_tests should close"
[ -z "$(g status --porcelain -- tests)" ] || die "the fingerprint must not make ignored tests visible to git"
g add -A && g commit -qm hidden >/dev/null
pass "a git-ignored test changed after the approval invalidates it, and stays out of git"

printf 'pre\n' > "$P/src/pre.ts"; printf 'x\nlocal\n' > "$P/src/other.ts"   # uncommitted before the claim
H claim tiny >/dev/null || die "claim tiny"
printf 'a\nB\n' > "$P/src/app.ts"
out=$(H log-out --quick --changes src/app.ts --verification v --closure c) && die "--quick without handoff/init must refuse"
grep -q 'handoff progress/tiny/quick.md is missing' <<<"$out" && grep -q 'init.sh has not passed' <<<"$out" \
  || die "missing reasons: $out"
grep -q 'QUICK: refused' <<<"$(q "SELECT entry FROM session_log_entries;")" || die "refusal must be logged"
pass "refuses without handoff or a passing init, and logs why"
handoff tiny "fix" "src/app.ts" "low"
H record-init pass >/dev/null
out=$(H log-out --quick --changes src/app.ts --verification v --closure c) && die "Risk: low must refuse"
grep -q "Risk: low" <<<"$out" || die "Risk reason missing: $out"
handoff tiny "fix" "src/app.ts" "none"
printf 'y\n' >> "$P/src/other.ts"
out=$(H log-out --quick --changes src/app.ts --verification v --closure c) && die "undeclared/changed-after-init must refuse"
grep -q 'not declared in progress/tiny/quick.md: src/other.ts' <<<"$out" || die "undeclared reason missing: $out"
grep -q 'changed after the last passing ./init.sh' <<<"$out" || die "stale init reason missing: $out"
pass "refuses Risk other than none, undeclared files and a tree changed after init"
printf 'x\nlocal\n' > "$P/src/other.ts"
echo '{}' > "$P/package.json"
handoff tiny "fix" "src/app.ts, package.json" "none"
H record-init pass >/dev/null
out=$(H log-out --quick --changes src/app.ts --verification v --closure c) && die "dependency change must refuse"
grep -q 'dependency file changed: package.json' <<<"$out" || die "dependency reason missing: $out"
rm "$P/package.json"
printf 'l\n%.0s' $(seq 1 90) >> "$P/src/app.ts"
H record-init pass >/dev/null
out=$(H log-out --quick --changes src/app.ts --verification v --closure c) && die "over 80 lines must refuse"
grep -q 'changed lines > quick_max_diff_lines=80' <<<"$out" || die "size reason missing: $out"
pass "refuses dependency changes and diffs over quick_max_diff_lines"
printf 'a\nB\n' > "$P/src/app.ts"; printf 'n\n' > "$P/src/n1.ts"; printf 'n\n' > "$P/src/n2.ts"
handoff tiny "fix" "src/app.ts, src/n1.ts, src/n2.ts" "none"
jq '. + {quick_max_files: 2}' "$P/.harness.json" > "$P/h.json" && mv "$P/h.json" "$P/.harness.json"
H record-init pass >/dev/null
out=$(H log-out --quick --changes src/app.ts --verification v --closure c) && die "quick_max_files=2 must refuse 3 files"
grep -q '3 changed files > quick_max_files=2' <<<"$out" || die "configured file limit not applied: $out"
jq 'del(.quick_max_files)' "$P/.harness.json" > "$P/h.json" && mv "$P/h.json" "$P/.harness.json"
rm "$P/src/n1.ts" "$P/src/n2.ts"
pass "quick_max_files is read from .harness.json"
printf 'a\nB\n' > "$P/src/app.ts"
handoff tiny "fix" "\`src/app.ts\`" "none"
H record-init fail >/dev/null
out=$(H log-out --quick --changes src/app.ts --verification v --closure c) && die "a failed init must refuse"
grep -q 'last ./init.sh failed' <<<"$out" || die "failed-init reason missing: $out"
H record-init pass >/dev/null
out=$(H log-out --quick --changes src/app.ts --verification v --closure c) || die "clean quick close should pass: $out"
grep -q 'quick gate passed: 2 lines, 1 files' <<<"$out" || die "pass summary missing: $out"
[ "$(q "SELECT status FROM features WHERE name='tiny';")" = done ] || die "quick close must mark done"
[ "$(q "SELECT review_status FROM session_log ORDER BY id DESC LIMIT 1;")" = quick ] || die "review_status should be quick"
[ ! -e "$P/progress/tiny" ] || die "log-out must delete the work folder progress/tiny/"
pass "clean small change closes without a reviewer, ignoring files already uncommitted at claim"

g add -A && g commit -qm tiny >/dev/null
H set-size other small >/dev/null && H claim other >/dev/null || die "claim other"
printf 'z\n' >> "$P/src/other.ts"
handoff other "fix" "src/other.ts" "none"
H record-init pass >/dev/null
H record-review changes-requested --by human:tester >/dev/null
out=$(H log-out --quick --changes src/other.ts --verification v --closure c) && die "--quick must not bypass requested changes"
grep -q 'already requested changes' <<<"$out" || die "wrong refusal: $out"
printf 'l\n%.0s' $(seq 1 90) >> "$P/src/other.ts"
H record-review approved --by human:tester >/dev/null
H record-init pass >/dev/null
H log-out --quick --changes src/other.ts --verification v --closure c >/dev/null || die "a reviewer approval should win over the gate"
pass "requested changes block --quick; an existing approval closes it"

printf 'l\n%.0s' $(seq 1 200) > "$P/src/wip.ts"; printf 'w\n%.0s' $(seq 1 150) >> "$P/src/app.ts"   # earlier feature, uncommitted
H add-feature --name small2 --title Small2 --size small >/dev/null && H claim small2 >/dev/null || die "claim small2"
printf 'extra\n' >> "$P/src/wip.ts"; printf 'extra\n' >> "$P/src/app.ts"
handoff small2 "fix" "src/wip.ts, src/app.ts" "none"
H record-init pass >/dev/null
out=$(H log-out --quick --changes src/wip.ts src/app.ts --verification v --closure c) || die "edits on files left uncommitted by an earlier feature should count only this session's lines: $out"
grep -q 'quick gate passed: 2 lines, 2 files' <<<"$out" || die "gate should count 2 lines: $out"
grep -q 'DIFF: code=2 lines' <<<"$out" || die "DIFF should count 2 lines: $out"
pass "files uncommitted at claim count only the lines changed since the claim"
g add -A && g commit -qm small2 >/dev/null
H add-feature --name small3 --title Small3 --size small >/dev/null && H claim small3 >/dev/null || die "claim small3"
printf 'l\n%.0s' $(seq 1 90) >> "$P/src/wip.ts"
H cancel-session --force "$(q "SELECT id FROM session_log WHERE closed_at IS NULL;")" "slot" >/dev/null || die "cancel small3"
H claim small3 >/dev/null || die "resume small3"
handoff small3 "fix" "src/wip.ts" "none"
H record-init pass >/dev/null
out=$(H log-out --quick --changes src/wip.ts --verification v --closure c) && die "a resumed session must still count the feature's earlier work"
grep -q '90 changed lines > quick_max_diff_lines=80' <<<"$out" || die "resume should measure from the original claim: $out"
H record-review approved --by human:tester >/dev/null && H log-out --quick --changes src/wip.ts --verification v --closure c >/dev/null || die "close small3"
pass "a resumed session measures from the cancelled session's claim"

echo "3. hold"
H add-feature --name held --title Held >/dev/null && H add-feature --name next --title Next >/dev/null
H claim held >/dev/null || die "claim held"
H hold "user rejected the escalation" >/dev/null || die "hold"
out=$(H claim next) && die "claim must refuse while a session is held"
grep -q 'on hold' <<<"$out" || die "claim refusal should mention hold: $out"
H record-init pass >/dev/null && H record-review approved --by human:tester >/dev/null
out=$(H log-out --changes src/app.ts --verification v --closure c) && die "log-out must refuse a held session"
grep -q 'on hold' <<<"$out" || die "log-out refusal should mention hold: $out"
H status | grep -q 'held_at' || die "status should show held_at"
H unhold "user approved after all" >/dev/null || die "unhold"
H log-out --changes src/app.ts --verification v --closure c >/dev/null || die "log-out after unhold"
grep -q 'UNHOLD: user approved after all' <<<"$(q "SELECT entry FROM session_log_entries;")" || die "unhold not logged"
pass "hold keeps the slot (claim and log-out refuse) until unhold"

echo "4. learnings"
out=$(H learn "$(printf 'x%.0s' $(seq 1 301))") && die "notes over 300 characters must be refused"
for i in 1 2 3 4 5 6; do H learn --feature held "canDeactivate lesson $i" >/dev/null || die "learn $i"; done
H learn "i18n keys go through jq" >/dev/null || die "learn i18n"
out=$(H recall canDeactivate)
[ "$(wc -l <<<"$out" | tr -d ' ')" = 5 ] || die "recall should cap at 5: $out"
head -1 <<<"$out" | grep -q '^#6 \[held\] canDeactivate lesson 6$' || die "newest match first with its feature: $out"
H recall i18n jq | head -1 | grep -q 'i18n keys go through jq' || die "the note matching more terms ranks first"
H forget 7 >/dev/null || die "forget"
H recall i18n | grep -q 'i18n' && die "forgotten note must not be recalled"
pass "learn caps at 300 chars, recall returns <= 5 ranked notes, forget hides one"

echo "all $PASS checks passed"
