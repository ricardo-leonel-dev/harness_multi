#!/usr/bin/env bash
# hide_harness_test.sh — .harness.json::hide_harness in a throwaway repository:
#
#   1. install.sh --hide-harness sets the flag and excludes the project-owned
#      harness files, specs/ and a test folder git tracks nothing in; a test
#      folder with tracked files stays the project's.
#   2. hide-check passes on clean changes, lists a harness file, word or id
#      (in a change or in --message), and is a no-op with the flag off.
#   3. log-out warns about harness traces in its --changes.
#
# Usage: bash tests/hide_harness_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

P="$WORK/p"
mkdir -p "$P/src" "$P/tests" "$P/test"
g() { git -C "$P" -c user.email=t@t -c user.name=t "$@"; }
H() { (cd "$P" && HOME="$WORK/home" HARNESS_AGENT=implementer ANTHROPIC_MODEL= bash scripts/harness.sh "$@") 2>&1; }
visible() { g status --porcelain --untracked-files=all | cut -c4-; }

echo "1. install --hide-harness"
g init -q
printf 'export const a = 1;\n' > "$P/src/app.js"
printf 'kept\n' > "$P/test/own.test.js"
g add src test && g commit -qm base || die "git setup"
printf 'agent test\n' > "$P/tests/app.test.js"
(cd "$P" && bash "$TOOLKIT_DIR/install.sh" --slug hide --human-user Tester --verify-command true --hide-harness) > "$WORK/install.log" 2>&1 \
  || die "install: $(tail -5 "$WORK/install.log")"
[ "$(jq -r .hide_harness "$P/.harness.json")" = true ] || die "install must set hide_harness"
out=$(visible)
for f in .harness.json CHECKPOINTS.md docs/architecture.md specs/README.md tests/app.test.js AGENTS.md; do
  grep -qxF "$f" <<<"$out" && die "$f must be hidden from git: $out"
done
printf 'more\n' >> "$P/test/own.test.js"
visible | grep -qxF test/own.test.js || die "a test folder git tracks stays visible"
g checkout -q -- test
pass "install hides the project-owned harness files, specs/ and an untracked test folder"

echo "2. hide-check"
H hide-check >/dev/null || die "clean tree should pass: $(H hide-check)"
printf 'export const a = 2; // R3: keep the old value\n' > "$P/src/app.js"
out=$(H hide-check) && die "a requirement id in a change must fail"
grep -q 'src/app.js: export const a = 2; // R3' <<<"$out" || die "should quote the line: $out"
printf 'export const a = 2;\n' > "$P/src/app.js"
H hide-check >/dev/null || die "a reworded change should pass: $(H hide-check)"
out=$(H hide-check --message "feat(F15): add totals") && die "an id in the message must fail"
grep -q 'message: feat(F15)' <<<"$out" || die "should quote the message: $out"
out=$(H hide-check --message "fix: Harness notes") && die "a harness word in any case must fail"
H hide-check --message "feat: add campaign totals with HTTP2 support" >/dev/null || die "ordinary text must pass"
printf 'notes\n' > "$P/CHECKPOINTS.md.bak"; mkdir -p "$P/specs/x" && printf 'R1\n' > "$P/specs/x/requirements.md"
H hide-check >/dev/null || die "excluded harness files and unrelated names must pass: $(H hide-check)"
rm -f "$P/CHECKPOINTS.md.bak"
printf 'var x="%s R1";\n' "$(printf 'a%.0s' $(seq 1 320))" > "$P/src/bundle.min.js"
H hide-check >/dev/null || die "a minified line over 300 characters must be skipped: $(H hide-check)"
rm -f "$P/src/bundle.min.js"
printf 'leak\n' > "$P/progress.txt"; g add -f -- "$P/.harness.json" 2>/dev/null
out=$(H hide-check) && die "a force-added harness file must fail"
grep -q 'harness file visible to git: .harness.json' <<<"$out" || die "should name the visible harness file: $out"
g rm -q --cached .harness.json && rm -f "$P/progress.txt"
jq '.hide_harness = false' "$P/.harness.json" > "$WORK/hj" && cp "$WORK/hj" "$P/.harness.json"
printf '// R9\n' >> "$P/src/app.js"
out=$(H hide-check) || die "with the flag off hide-check is a no-op: $out"
grep -q 'hide_harness is off' <<<"$out" || die "should say the flag is off: $out"
jq '.hide_harness = true' "$P/.harness.json" > "$WORK/hj" && cp "$WORK/hj" "$P/.harness.json"
pass "hide-check lists harness files, words and ids in changes and messages, and passes otherwise"

echo "3. log-out warning"
g add src && g commit -qm wip >/dev/null
H add-feature --name totals --title Totals >/dev/null && H claim totals >/dev/null || die "claim"
printf 'export const b = 1; // T2\n' >> "$P/src/app.js"
H record-init pass >/dev/null && H record-review approved --by human:tester >/dev/null
out=$(H log-out --changes src/app.js --verification v --closure c) || die "log-out: $out"
grep -q 'hide_harness: these changes show the harness' <<<"$out" && grep -q 'src/app.js: export const b = 1; // T2' <<<"$out" \
  || die "log-out should warn with the line: $out"
pass "log-out warns about harness traces in its changes"

echo "all $PASS checks passed"
