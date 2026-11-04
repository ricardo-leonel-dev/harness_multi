#!/usr/bin/env bash
# scope_surfaces_test.sh — out-of-scope lines and session surfaces in
# scripts/harness.sh, run against a throwaway project in a temp dir.
#
#   1. An older harness.db gains features.out_of_scope and session_log.surfaces
#      in place; a session already open then is marked as predating surfaces.
#   2. add-feature --out-of-scope / set-out-of-scope store at most 5 lines;
#      claim and status print them.
#   3. set-surfaces refuses patterns that match everything, absolute paths and
#      '..', and is set once; add-surface needs a reason and logs it.
#   4. log-out (reviewer path and --quick) refuses without surfaces and lists
#      files outside them (--changes, untracked, committed since the claim);
#      progress/, git-excluded files, the feature's specs/ and files already
#      dirty at claim are ignored, as are untracked nested repositories and
#      worktrees; non-ASCII names match raw; inside the surfaces it closes.
#   5. A session opened before the migration closes with a warning; a lean
#      log-out never reaches the surfaces check.
#
# Usage: bash tests/scope_surfaces_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

P="$WORK/p"
mkdir -p "$P/scripts" "$WORK/home"
cp "$TOOLKIT_DIR"/scripts/*.sh "$TOOLKIT_DIR/scripts/agent_usage.py" "$P/scripts/"
echo '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state"}' > "$P/.harness.json"
sqlite3 "$P/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql"
sqlite3 "$P/harness.db" "INSERT INTO projects (id, slug) VALUES ('p1','t');"

H() { (cd "$P" && HOME="$WORK/home" HARNESS_AGENT=implementer ANTHROPIC_MODEL= bash scripts/harness.sh "$@") 2>&1; }
q() { sqlite3 "$P/harness.db" "$1"; }
g() { (cd "$P" && git -c user.email=t@t -c user.name=t "$@"); }
ready() { H record-init pass >/dev/null && H record-review approved --by human:tester >/dev/null || die "init/review"; }

g init -q && mkdir -p "$P/src/api" "$P/docs" && printf 'a\n' > "$P/src/api/a.ts" && printf 'd\n' > "$P/docs/x.md"
printf 'progress/\nharness.db\nscripts/\nstate/\n.harness.json\n' > "$P/.gitignore"
g add -A && g commit -qm base || die "git setup"

echo "1. migration of an older harness.db"
H add-feature --name legacy --title Legacy >/dev/null && H claim legacy >/dev/null || die "claim legacy"
q "ALTER TABLE features DROP COLUMN out_of_scope; ALTER TABLE session_log DROP COLUMN surfaces; ALTER TABLE session_log DROP COLUMN surfaces_required;" \
  || die "could not build an old db"
H status >/dev/null || die "status on an old db"
q "SELECT out_of_scope FROM features LIMIT 0; SELECT surfaces FROM session_log LIMIT 0;" || die "migration should add the scope columns"
[ "$(q "SELECT out_of_scope FROM features WHERE name='legacy';")" = '[]' ] || die "existing features get an empty out_of_scope"
[ "$(q "SELECT surfaces_required FROM session_log;")" = 0 ] || die "a session open before the migration must not require surfaces"
pass "an older harness.db gains out_of_scope and surfaces; open sessions are marked as predating them"

printf 'b\n' >> "$P/src/api/a.ts"; ready
out=$(H log-out --changes src/api/a.ts --verification v --closure c) || die "a pre-migration session must close: $out"
grep -q 'opened before surfaces existed' <<<"$out" || die "pre-migration warning missing: $out"
g add -A && g commit -qm legacy >/dev/null
pass "a session opened before the migration closes with a warning"

echo "2. out of scope"
H add-feature --name api --title Api --out-of-scope "no pagination" --out-of-scope "no new dependencies" >/dev/null || die "add-feature --out-of-scope"
[ "$(q "SELECT out_of_scope FROM features WHERE name='api';")" = '["no pagination","no new dependencies"]' ] || die "out_of_scope not stored"
out=$(H add-feature --name six --title Six --out-of-scope 1 --out-of-scope 2 --out-of-scope 3 --out-of-scope 4 --out-of-scope 5 --out-of-scope 6) \
  && die "six out-of-scope lines must be refused"
grep -q 'at most 5' <<<"$out" || die "wrong refusal for six lines: $out"
[ -z "$(q "SELECT 1 FROM features WHERE name='six';")" ] || die "a refused add-feature must not insert"
H add-feature --name tiny --title Tiny --size small >/dev/null || die "add-feature tiny"
H set-out-of-scope tiny "no UI" >/dev/null || die "set-out-of-scope"
[ "$(q "SELECT out_of_scope FROM features WHERE name='tiny';")" = '["no UI"]' ] || die "set-out-of-scope not stored"
H set-out-of-scope tiny 1 2 3 4 5 6 >/dev/null && die "set-out-of-scope with six lines must be refused"
H set-out-of-scope tiny >/dev/null && [ "$(q "SELECT out_of_scope FROM features WHERE name='tiny';")" = '[]' ] || die "set-out-of-scope with no line clears"
H set-out-of-scope legacy "x" >/dev/null && die "a done feature's out of scope is final"
out=$(H claim api) || die "claim api: $out"
grep -q -- '- no pagination' <<<"$out" && grep -q -- '- no new dependencies' <<<"$out" || die "claim must print the out-of-scope lines: $out"
grep -q 'set-surfaces' <<<"$out" || die "claim must point to set-surfaces: $out"
out=$(H status); grep -q -- '- no pagination' <<<"$out" && grep -q 'none declared yet' <<<"$out" || die "status must show out of scope and missing surfaces: $out"
pass "out of scope: at most 5 lines, set/cleared, printed by claim and status"

echo "3. set-surfaces and add-surface"
for bad in . '*' '**' '**/*' /etc/x ../x 'src/../x'; do
  H set-surfaces "$bad" >/dev/null && die "set-surfaces '$bad' must be refused"
done
H set-surfaces src/api/a.ts "src/ok" "/abs" >/dev/null && die "one refused pattern refuses the whole call"
[ -z "$(q "SELECT surfaces FROM session_log WHERE closed_at IS NULL;")" ] || die "a refused set-surfaces must store nothing"
H set-surfaces "./src/api/**" "tests/api_*.sh" >/dev/null || die "set-surfaces"
[ "$(q "SELECT surfaces FROM session_log WHERE closed_at IS NULL;")" = '["src/api/**","tests/api_*.sh"]' ] || die "surfaces not normalized/stored"
H set-surfaces docs >/dev/null && die "set-surfaces twice must be refused (widen with add-surface)"
H add-surface docs >/dev/null && die "add-surface without --reason must be refused"
H add-surface /docs --reason r >/dev/null && die "add-surface validates the pattern"
H add-surface docs/x.md --reason "the API is documented there" >/dev/null || die "add-surface"
H add-surface docs/x.md --reason "again" >/dev/null || die "add-surface twice"
[ "$(q "SELECT surfaces FROM session_log WHERE closed_at IS NULL;")" = '["src/api/**","tests/api_*.sh","docs/x.md"]' ] || die "add-surface must append once"
[ -n "$(q "SELECT 1 FROM session_log_entries WHERE entry = '[harness] SURFACE added: docs/x.md — reason: the API is documented there';")" ] \
  || die "add-surface must log the reason"
pass "set-surfaces validates and is set once; add-surface needs a reason and logs it"

echo "4. log-out against the surfaces"
mkdir -p "$P/tests" "$P/progress/api" "$P/specs/api" "$P/other"
printf 'c\n' >> "$P/src/api/a.ts"; printf 't\n' > "$P/tests/api_one.sh"; printf 'h\n' > "$P/progress/api/impl.md"
printf 's\n' > "$P/specs/api/tasks.md"; printf 'i\n' > "$P/other/ignored.txt"; printf 'other/\n' >> "$P/.git/info/exclude"
ready
out=$(H log-out --changes src/api/a.ts src/main.ts --verification v --closure c) && die "a --changes file outside must refuse"
grep -q -- '- src/main.ts' <<<"$out" && grep -q 'add-surface' <<<"$out" || die "refusal must list src/main.ts and point to add-surface: $out"
grep -q 'progress/\|specs/api\|other/ignored\|tests/api_one' <<<"$out" && die "progress/, the feature's specs, excluded and declared files are not offenders: $out"
printf 'n\n' > "$P/src/new.ts"
out=$(H log-out --changes src/api/a.ts --verification v --closure c) && die "an untracked file outside must refuse"
grep -q -- '- src/new.ts' <<<"$out" || die "refusal must list the untracked file: $out"
[ -n "$(q "SELECT 1 FROM session_log_entries WHERE entry LIKE '[harness] SURFACES: refused — outside: src/new.ts%';")" ] || die "the refusal must be logged"
rm "$P/src/new.ts"
printf 'n\n' > "$P/src/new.ts"; g add src/new.ts && g commit -qm sneak >/dev/null
out=$(H log-out --changes src/api/a.ts --verification v --closure c) && die "a file committed since the claim outside must refuse"
grep -q -- '- src/new.ts' <<<"$out" || die "refusal must list the committed file: $out"
g reset -q --hard HEAD~1 && printf 'a\nb\nc\n' > "$P/src/api/a.ts"
printf 'u\n' > "$P/src/api/café.txt"; printf 'u\n' > "$P/src/ñ.ts"
out=$(H log-out --changes src/api/a.ts --verification v --closure c) && die "an untracked non-ASCII file outside must refuse"
grep -qxF -- '  - src/ñ.ts' <<<"$out" || die "a non-ASCII file outside must be listed by its raw name: $out"
grep -q 'caf' <<<"$out" && die "a non-ASCII file inside the surfaces is not an offender: $out"
rm "$P/src/ñ.ts"
pass "non-ASCII file names are matched by their raw name (inside allowed, outside listed raw)"
g worktree add -q "$P/.claude/worktrees/agent-x" 2>/dev/null || die "git worktree add"
mkdir -p "$P/vendor/nested" && (cd "$P/vendor/nested" && git init -q) || die "nested git init"
ready
out=$(H log-out --changes src/api/a.ts tests/api_one.sh docs/x.md --verification v --closure c) || die "inside the surfaces it must close: $out"
grep -q '\.claude/worktrees\|vendor/nested' <<<"$out" && die "a nested worktree or repository is not a changed file: $out"
[ "$(q "SELECT status FROM features WHERE name='api';")" = done ] || die "api must be done"
g worktree remove --force "$P/.claude/worktrees/agent-x" && rm -rf "$P/.claude" "$P/vendor" || die "worktree cleanup"
g add -A && g commit -qm api >/dev/null
pass "log-out refuses files outside (--changes, untracked, committed) and closes inside; progress/, specs/<name>/, excluded files and nested worktrees/repositories ignored"

H add-feature --name nosurf --title NoSurf >/dev/null && H claim nosurf >/dev/null || die "claim nosurf"
printf 'z\n' >> "$P/src/api/a.ts"; ready
out=$(H log-out --changes src/api/a.ts --verification v --closure c) && die "log-out without surfaces must refuse"
grep -q 'no surfaces declared' <<<"$out" || die "missing-surfaces reason: $out"
H set-surfaces src/api >/dev/null; ready
H log-out --changes src/api/a.ts --verification v --closure c >/dev/null || die "nosurf should close once declared"
g add src && g commit -qm nosurf >/dev/null
printf 'pre\n' > "$P/docs/x.md"   # dirty before the next claim, untouched since
H claim tiny >/dev/null || die "claim tiny"
mkdir -p "$P/progress/tiny" && printf 'Change: x\nFiles: src/api/a.ts\nRisk: none\n' > "$P/progress/tiny/quick.md"
printf 'q\n' >> "$P/src/api/a.ts"; H record-init pass >/dev/null
out=$(H log-out --quick --changes src/api/a.ts --verification v --closure c) && die "--quick without surfaces must refuse"
grep -q 'no surfaces declared' <<<"$out" || die "--quick missing-surfaces reason: $out"
H set-surfaces src/main.ts >/dev/null
out=$(H log-out --quick --changes src/api/a.ts --verification v --closure c) && die "--quick with a file outside must refuse"
grep -q -- '- src/api/a.ts' <<<"$out" || die "--quick refusal must list the file: $out"
grep -q 'docs/x.md' <<<"$out" && die "a file dirty at claim and untouched since is not this session's change: $out"
H add-surface src/api/a.ts --reason "the fix lives there" >/dev/null
out=$(H log-out --quick --changes src/api/a.ts --verification v --closure c) || die "--quick inside the surfaces must close: $out"
pass "log-out --quick applies the same surfaces check; files dirty at claim and untouched are ignored"

echo "5. lean log-out is unaffected"
H add-feature --name leanf --title Lean --mode normal >/dev/null && H claim leanf >/dev/null || die "claim leanf"
out=$(H log-out --lean --changes src/api/a.ts --verification v --closure c)
grep -qi 'surfaces' <<<"$out" && die "the lean path must not check surfaces: $out"
grep -q 'log-out --lean refused' <<<"$out" || die "the lean gate should be what answers: $out"
pass "log-out --lean never reaches the surfaces check"

H snapshot >/dev/null || die "snapshot"
grep -q '^## Out of scope' "$P"/state/features/*-api.md || die "snapshot must list out of scope"
grep -q '^## Surfaces' "$P"/state/sessions/*-api.md || die "snapshot must list surfaces"
pass "the snapshot shows out of scope and surfaces"

echo "PASS: $PASS checks"
