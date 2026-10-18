#!/usr/bin/env bash
# scope_discipline_test.sh — end-to-end check of the scope and test-discipline
# mechanics in scripts/harness.sh, run against a throwaway project in a temp dir.
#
#   1. mark-spec-ready refuses more than spec_max_requirements (default 15) and
#      accepts the limit; approve-spec refuses a spec edited above it; 0 disables.
#   2. test runs test_targeted_command with {files}, keeps output in
#      progress/test_last.log, propagates the exit status, falls back to
#      verify_command.
#   3. log-out logs DIFF code/test line counts (lockfiles and prose excluded)
#      and warns, without blocking, above review_budget_lines.
#   4. record-usage warns once the active feature reaches token_warn_percent
#      of token_quota, and stays quiet below it or without a quota.
#
# Usage: bash tests/scope_discipline_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

# new_project <dir> <config-json> — minimal installed project with 2 features (alpha is sdd=1).
new_project() {
  local dir="$1" cfg="$2"
  mkdir -p "$dir/scripts"
  cp "$TOOLKIT_DIR"/scripts/*.sh "$TOOLKIT_DIR/scripts/agent_usage.py" "$dir/scripts/"
  jq -n --argjson extra "$cfg" '{project_slug:"t", db_path:"harness.db", snapshot_path:"state"} + $extra' \
    > "$dir/.harness.json"
  sqlite3 "$dir/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql"
  sqlite3 "$dir/harness.db" "INSERT INTO projects (id, slug) VALUES ('p1','t');
INSERT INTO features (project_id, feature_number, name, title, sdd) VALUES
  ('p1',1,'alpha','Alpha',1), ('p1',2,'beta','Beta',0);"
}

H() { (cd "$P" && HOME="$WORK/home" HARNESS_AGENT=implementer ANTHROPIC_MODEL= bash scripts/harness.sh "$@") 2>&1; }
q() { sqlite3 "$P/harness.db" "$1"; }

# write_spec <n_requirements> — specs/alpha with n EARS requirements and one task each.
write_spec() {
  local n="$1" i
  mkdir -p "$P/specs/alpha"
  : > "$P/specs/alpha/requirements.md"
  : > "$P/specs/alpha/tasks.md"
  for i in $(seq 1 "$n"); do
    printf '## R%s — Rule %s\nThe system SHALL do %s.\n\n' "$i" "$i" "$i" >> "$P/specs/alpha/requirements.md"
    printf -- '- [ ] T%s (R%s) Do %s.\n' "$i" "$i" "$i" >> "$P/specs/alpha/tasks.md"
  done
  printf '## P1 — Keep it\nUnchanged.\n' >> "$P/specs/alpha/requirements.md"
  echo "# design" > "$P/specs/alpha/design.md"
}

echo "1. spec_max_requirements gate"
P="$WORK/p1"; new_project "$P" '{}'
H claim-spec alpha >/dev/null || die "claim-spec alpha"
write_spec 16
out=$(H mark-spec-ready) && die "mark-spec-ready should refuse 16 requirements"
grep -q 'spec_max_requirements=15' <<<"$out" || die "refusal should name the limit: $out"
[ "$(q "SELECT status FROM features WHERE name='alpha';")" = spec_drafting ] || die "refused spec must stay spec_drafting"
pass "16 requirements refused, feature stays spec_drafting"
write_spec 15
H mark-spec-ready >/dev/null || die "mark-spec-ready with 15: $(H mark-spec-ready)"
[ "$(q "SELECT requirements_count FROM specs;")" = 15 ] || die "P<n> items must not count as requirements"
pass "15 requirements accepted (P1 not counted)"
write_spec 16
out=$(H approve-spec alpha --by tester) && die "approve-spec should refuse a spec edited to 16"
[ "$(q "SELECT status FROM specs;")" = ready ] || die "refused approval must leave the spec ready"
pass "approve-spec refuses a spec edited above the limit"
jq '.spec_max_requirements = 0' "$P/.harness.json" > "$P/c" && mv "$P/c" "$P/.harness.json"
H approve-spec alpha --by tester >/dev/null || die "spec_max_requirements=0 should disable the gate"
pass "spec_max_requirements=0 disables the gate"

echo "2. test subcommand"
P="$WORK/p2"; new_project "$P" '{"verify_command":"echo FULL-SUITE","test_targeted_command":"echo TARGETED {files}; test ! -e fail"}'
out=$(H test "a b.spec.ts" c.spec.ts) || die "targeted run should pass: $out"
grep -q "TARGETED 'a b.spec.ts' c.spec.ts\|TARGETED a\\\\ b.spec.ts c.spec.ts" "$P/progress/test_last.log" \
  || die "files not substituted and quoted: $(cat "$P/progress/test_last.log")"
grep -q '^TARGETED' <<<"$out" && die "test output must stay in the log, not stdout: $out"
pass "targeted command gets quoted files; output only in progress/test_last.log"
jq '.test_targeted_command = "echo EACH {files:--include} END"' "$P/.harness.json" > "$P/c" && mv "$P/c" "$P/.harness.json"
H test "a b.spec.ts" c.spec.ts >/dev/null || die "{files:FLAG} run"
grep -q "^EACH --include a b.spec.ts --include c.spec.ts END" "$P/progress/test_last.log" \
  || die "{files:FLAG} should repeat the flag per file: $(cat "$P/progress/test_last.log")"
grep -q "^\$ echo EACH --include a\\\\ b.spec.ts --include c.spec.ts END" "$P/progress/test_last.log" \
  || die "{files:FLAG} paths must stay quoted: $(cat "$P/progress/test_last.log")"
pass "{files:FLAG} repeats the flag before each quoted file"
jq '.test_targeted_command = "echo TARGETED {files}; test ! -e fail"' "$P/.harness.json" > "$P/c" && mv "$P/c" "$P/.harness.json"
touch "$P/fail"
out=$(H test x.spec.ts) && die "failing tests must exit non-zero"
grep -q 'tests failed' <<<"$out" || die "failure should be reported: $out"
rm "$P/fail"
pass "failure exit status propagates"
H test >/dev/null || die "no files should run verify_command"
grep -q FULL-SUITE "$P/progress/test_last.log" || die "no files should fall back to verify_command"
jq 'del(.test_targeted_command)' "$P/.harness.json" > "$P/c" && mv "$P/c" "$P/.harness.json"
H test x.spec.ts >/dev/null || die "fallback run"
grep -q FULL-SUITE "$P/progress/test_last.log" || die "missing test_targeted_command should fall back"
pass "falls back to verify_command"

echo "3. log-out review budget"
P="$WORK/p3"; new_project "$P" '{"review_budget_lines":5}'
(cd "$P" && git init -q && mkdir -p src && printf 'a\nb\n' > src/app.ts && git add src && \
  git -c user.email=t@t -c user.name=t commit -qm base) || die "git setup"
printf 'a\nB\nc\nd\n' > "$P/src/app.ts"                     # +3 -1 = 4 code lines
mkdir -p "$P/src/x"; printf '1\n2\n3\n' > "$P/src/x/app.spec.ts"   # 3 test lines (untracked)
printf 'lock\n%.0s' $(seq 1 50) > "$P/bun.lock"            # excluded
printf 'doc\n' > "$P/NOTES.md"                              # excluded
H claim beta >/dev/null || die "claim beta"
H record-review approved --by human:tester >/dev/null || die "record-review"
out=$(H log-out --changes src/app.ts src/x bun.lock NOTES.md --verification v --closure c) || die "log-out: $out"
grep -q 'DIFF: code=4 lines, tests=3 lines, files=2' <<<"$out" || die "wrong DIFF: $out"
grep -q 'review_budget_lines' <<<"$(q "SELECT entry FROM session_log_entries;")" || die "DIFF not logged on the session"
grep -q 'exceeds' <<<"$out" && die "4 code lines must not exceed a budget of 5: $out"
pass "DIFF logged with code/test split, lockfile and prose excluded"
[ "$(q "SELECT status FROM features WHERE name='beta';")" = done ] || die "log-out must still close"
q "UPDATE features SET status='pending' WHERE name='beta';"
printf 'x\n%.0s' $(seq 1 10) >> "$P/src/app.ts"
H claim beta >/dev/null && H record-review approved --by human:tester >/dev/null || die "re-claim beta"
out=$(H log-out --changes src/app.ts --verification v --closure c) || die "log-out over budget must not block: $out"
grep -q 'exceeds review_budget_lines=5' <<<"$out" || die "over-budget warning missing: $out"
pass "over budget warns and still closes"

echo "4. token budget warning"
P="$WORK/p4"; new_project "$P" '{}'
H claim beta >/dev/null || die "claim beta"
q "INSERT INTO agent_runs (project_id, session_id, feature_id, runtime, external_id, total_tokens)
VALUES ('p1', 1, 2, 'claude', 'x1', 1000);"
out=$(H record-usage)
grep -q 'token budget' <<<"$out" && die "no token_quota must mean no warning: $out"
jq '.token_quota = 10000' "$P/.harness.json" > "$P/c" && mv "$P/c" "$P/.harness.json"
out=$(H record-usage)
grep -q 'token budget' <<<"$out" && die "10% must stay under the default 15%: $out"
q "UPDATE agent_runs SET total_tokens=2000;"
out=$(H record-usage)
grep -q 'token budget: feature 2 beta has used 2000 tokens = 20%' <<<"$out" || die "missing warning at 20%: $out"
pass "warns at token_warn_percent of token_quota, quiet below or without quota"

echo "all $PASS checks passed"
