#!/usr/bin/env bash
# feature_flow_test.sh — end-to-end check of the per-feature flow additions in
# scripts/harness.sh, run against a throwaway project in a temp dir.
#
#   1. features.request keeps the user's request verbatim (add-feature
#      --request, set-request, notion-import) and the snapshot shows it.
#   2. mark-spec-ready refuses a requirements.md without its "Request
#      (verbatim)" and "Assumptions" sections; drop-sdd only applies before a
#      spec exists.
#   3. Each feature works in progress/<name>/: claim names it, log-out and
#      supersede delete it, and the quick gate also finds a handoff named by
#      feature number or in the older flat progress/quick_<x>.md form.
#   4. log-out's DIFF says tests=n/a when the project keeps tests/ out of git.
#   5. A Notion push that fails on the network names notion-push, which retries it.
#   6. link-worktree shares the harness with a git worktree but keeps
#      progress/ local, replacing an existing progress/ symlink.
#
# Usage: bash tests/feature_flow_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

P="$WORK/repo/app"
mkdir -p "$P/scripts" "$P/src" "$P/progress"
cp "$TOOLKIT_DIR"/scripts/*.sh "$TOOLKIT_DIR/scripts/agent_usage.py" "$P/scripts/"
echo '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state"}' > "$P/.harness.json"
sqlite3 "$P/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql"
sqlite3 "$P/harness.db" "INSERT INTO projects (id, slug) VALUES ('p1','t');"

H() { (cd "$P" && HOME="$WORK/home" HARNESS_AGENT=implementer ANTHROPIC_MODEL= bash scripts/harness.sh "$@") 2>&1; }
q() { sqlite3 "$P/harness.db" "$1"; }
g() { git -C "$WORK/repo" -c user.email=t@t -c user.name=t "$@"; }

echo "1. verbatim request"
q "ALTER TABLE features DROP COLUMN request;"
H status >/dev/null || die "status on an old db"
q "SELECT request FROM features LIMIT 0;" || die "migration should add features.request"
H add-feature --name spec_one --title "Spec one" --sdd --request "Quiero el endpoint /a, igual que /b" >/dev/null || die "add-feature --request"
[ "$(q "SELECT request FROM features WHERE name='spec_one';")" = "Quiero el endpoint /a, igual que /b" ] || die "request not stored"
H add-feature --name plain --title Plain >/dev/null || die "add-feature"
[ -z "$(q "SELECT request FROM features WHERE name='plain';")" ] || die "no --request must leave it empty"
H set-request plain "Arregla el foco al guardar" >/dev/null || die "set-request"
[ "$(q "SELECT request FROM features WHERE name='plain';")" = "Arregla el foco al guardar" ] || die "set-request did not apply"
echo '[{"name":"from_notion","title":"From Notion","description":"Texto de la tarjeta","source_id":"n1"}]' > "$WORK/n.json"
H notion-import "$WORK/n.json" >/dev/null || die "notion-import"
[ "$(q "SELECT request FROM features WHERE name='from_notion';")" = "Texto de la tarjeta" ] || die "notion-import must keep the card text as the request"
H snapshot >/dev/null || die "snapshot"
grep -q '^## Request (verbatim)$' "$P"/state/features/001-spec_one.md || die "snapshot should show the request"
pass "request is stored by add-feature, set-request and notion-import, and shown in the snapshot"

echo "2. spec sections"
H claim-spec spec_one >/dev/null || die "claim-spec"
mkdir -p "$P/specs/spec_one"
printf '## R1 — Rule\nWHEN x THE SYSTEM SHALL y.\n' > "$P/specs/spec_one/requirements.md"
printf '# design\n' > "$P/specs/spec_one/design.md"
printf -- '- [ ] T1 (R1) do it\n' > "$P/specs/spec_one/tasks.md"
out=$(H mark-spec-ready) && die "mark-spec-ready must refuse without the request section"
grep -q "no '## Request (verbatim)' section" <<<"$out" || die "wrong refusal: $out"
{ printf '## Request (verbatim)\nQuiero el endpoint /a\n\n'; cat "$P/specs/spec_one/requirements.md"; } > "$WORK/r" && mv "$WORK/r" "$P/specs/spec_one/requirements.md"
out=$(H mark-spec-ready) && die "mark-spec-ready must refuse without assumptions"
grep -q "no '## Assumptions' section" <<<"$out" || die "wrong refusal: $out"
printf '\n## Assumptions\n- S1: none\n' >> "$P/specs/spec_one/requirements.md"
out=$(H mark-spec-ready) || die "mark-spec-ready with both sections: $out"
grep -q 'R=1, T=1' <<<"$out" || die "the sections must not count as requirements: $out"
pass "mark-spec-ready requires the request and assumptions sections"
out=$(H drop-sdd spec_one "complete") && die "drop-sdd must refuse a feature whose spec exists"
H add-feature --name clear_one --title "Clear one" --sdd >/dev/null || die "add-feature clear_one"
out=$(H drop-sdd clear_one) && die "drop-sdd needs a reason"
H drop-sdd clear_one "one field, nothing to decide" >/dev/null || die "drop-sdd clear_one"
[ "$(q "SELECT sdd FROM features WHERE name='clear_one';")" = 0 ] || die "drop-sdd must set sdd=0"
[ "$(q "SELECT entry FROM feature_notes n JOIN features f ON f.id=n.feature_id WHERE f.name='clear_one';")" = "SDD dropped: one field, nothing to decide" ] || die "drop-sdd must keep the reason"
pass "drop-sdd turns a pending feature without a spec into sdd=0 and keeps the reason"
H add-sdd clear_one "el usuario pidió spec" >/dev/null || die "add-sdd clear_one"
[ "$(q "SELECT sdd || size FROM features WHERE name='clear_one';")" = 1normal ] || die "add-sdd must set sdd=1 and size normal"
[ "$(q "SELECT count(*) FROM feature_notes n JOIN features f ON f.id=n.feature_id WHERE f.name='clear_one' AND entry='SDD added: el usuario pidió spec';")" = 1 ] || die "add-sdd must keep the reason"
out=$(H add-sdd clear_one "again") && die "add-sdd must refuse a feature that is already sdd=1"
[ "$(q "SELECT count(*) FROM features WHERE name='clear_one';")" = 1 ] || die "add-sdd must not re-create the feature"
pass "add-sdd turns a pending sdd=0 feature into sdd=1 in place and keeps the reason"

echo "3. work folder"
g init -q && mkdir -p "$P/tests"
printf 'progress/\nharness.db\nscripts/\nstate/\n.harness.json\nspecs/\n' > "$P/.gitignore"
printf 'a\n' > "$P/src/app.ts" && g add -A && g commit -qm base || die "git setup"
out=$(H claim plain) || die "claim plain: $out"
grep -q 'work folder: progress/plain/' <<<"$out" || die "claim should name the work folder: $out"
mkdir -p "$P/progress/plain" && printf 'handoff\n' > "$P/progress/plain/impl.md"
printf 'b\n' >> "$P/src/app.ts"
H record-init pass >/dev/null && H record-review approved --by human:tester >/dev/null
H log-out --changes src/app.ts --verification v --closure c >/dev/null || die "log-out plain"
[ ! -e "$P/progress/plain" ] || die "log-out must delete progress/plain/"
pass "claim names progress/<name>/ and log-out deletes it"

H add-feature --name gone --title Gone >/dev/null && mkdir -p "$P/progress/gone" && printf 'split\n' > "$P/progress/gone/split.md"
H supersede gone --by spec_one --reason "absorbed" >/dev/null || die "supersede"
[ ! -e "$P/progress/gone" ] || die "supersede must delete progress/gone/"
pass "supersede deletes the work folder"

g add -A && g commit -qm plain >/dev/null
for form in number flat; do
  H add-feature --name "q_$form" --title Q --size small >/dev/null
  num=$(q "SELECT feature_number FROM features WHERE name='q_$form';")
  H claim "q_$form" >/dev/null || die "claim q_$form"
  printf 'c%s\n' "$form" >> "$P/src/app.ts"
  if [ "$form" = number ]; then mkdir -p "$P/progress/$num"; f="$P/progress/$num/quick.md"; else f="$P/progress/quick_$num.md"; fi
  printf 'Cambio: x\nArchivos: src/app.ts\nRisk: none\nMotivo: t\n' > "$f"
  H record-init pass >/dev/null
  out=$(H log-out --quick --changes src/app.ts --verification v --closure c) || die "quick gate should accept the $form-named handoff: $out"
  g add -A && g commit -qm "q $form" >/dev/null
done
pass "the quick gate accepts handoffs named by feature number and the older flat form"

echo "4. DIFF with ignored tests"
printf 'tests/\n' >> "$P/.gitignore" && g add -A && g commit -qm ignore-tests >/dev/null
H add-feature --name t_ignored --title T >/dev/null && H claim t_ignored >/dev/null
printf 'd\n' >> "$P/src/app.ts" && printf 'test\n' > "$P/tests/app.test.ts"
H record-init pass >/dev/null && H record-review approved --by human:tester >/dev/null
out=$(H log-out --changes src/app.ts tests/app.test.ts --verification v --closure c) || die "log-out t_ignored: $out"
grep -q 'tests=n/a (tests/ is ignored by git)' <<<"$out" || die "DIFF should say tests are not visible: $out"
pass "DIFF reports tests=n/a when tests/ is ignored by git"

echo "5. Notion push failure"
mkdir -p "$WORK/bin" && printf '#!/bin/sh\necho "curl: (6) Could not resolve host" >&2\nexit 6\n' > "$WORK/bin/curl" && chmod +x "$WORK/bin/curl"
jq '. + {notion_database_id:"db1", notion_token_env:"T_NOTION"}' "$P/.harness.json" > "$WORK/hj" && cp "$WORK/hj" "$P/.harness.json"
H add-feature --name carded --title Carded >/dev/null && H link-notion carded page1 >/dev/null || die "link-notion"
num=$(q "SELECT feature_number FROM features WHERE name='carded';")
out=$(PATH="$WORK/bin:$PATH" T_NOTION=x H claim carded) || die "claim must not fail when Notion is unreachable: $out"
grep -q "still shows its previous status — retry with network: scripts/harness.sh notion-push $num" <<<"$out" || die "claim should name the retry command: $out"
out=$(PATH="$WORK/bin:$PATH" T_NOTION=x H notion-push carded) || die "notion-push must not fail: $out"
grep -q "notion-push $num" <<<"$out" || die "notion-push should warn again while offline: $out"
out=$(T_NOTION= H notion-push carded) || die "notion-push without a token: $out"
grep -q "retry with network" <<<"$out" && die "a missing token is not a network failure: $out"
sid=$(q "SELECT max(id) FROM session_log;")
H cancel-session --force "$sid" "test cleanup" >/dev/null || die "cancel-session"
jq 'del(.notion_database_id, .notion_token_env)' "$P/.harness.json" > "$WORK/hj" && cp "$WORK/hj" "$P/.harness.json"
pass "an unreachable Notion leaves a warning that names notion-push, and notion-push retries it"

echo "6. link-worktree"
g add -A && g commit -qm wt >/dev/null
g worktree add -q "$WORK/wt" 2>/dev/null || die "git worktree add"
W="$WORK/wt/app"
mkdir -p "$W" && ln -s "$P/progress" "$W/progress"
out=$(H link-worktree "$W") || die "link-worktree: $out"
[ -L "$W/harness.db" ] && [ -L "$W/scripts" ] && [ -L "$W/.harness.json" ] || die "shared items should be symlinks: $(ls -la "$W")"
[ -d "$W/progress" ] && [ ! -L "$W/progress" ] || die "progress/ must be a local directory"
[ -L "$W/specs" ] || die "an ignored project folder missing in the worktree should be linked"
[ -d "$W/src" ] && [ ! -L "$W/src" ] || die "tracked files are the worktree's own"
grep -qxF '/app/harness.db' "$WORK/repo/.git/info/exclude" || die "links must be listed in the shared exclude"
grep -q 'replaced by a local directory' <<<"$out" || die "should report the progress symlink replacement: $out"
(cd "$W" && bash scripts/harness.sh status >/dev/null 2>&1) || die "harness must work from the worktree"
H link-worktree "$W" >/dev/null || die "link-worktree must be re-runnable"
[ "$(grep -c '^# >>> harness-worktree-links: /app/' "$WORK/repo/.git/info/exclude")" = 1 ] || die "re-run must not duplicate the exclude block"
out=$(H link-worktree "$P") && die "the main checkout itself must be refused"
pass "link-worktree shares the harness and keeps progress/ local"

echo "all $PASS checks passed"
