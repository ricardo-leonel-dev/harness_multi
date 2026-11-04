#!/usr/bin/env bash
# worktree_link_refresh_test.sh — linked worktrees stay in step with the main
# checkout's harness, and record-usage never fails silently. Temp HOME and temp
# repositories only; no database server, no network.
#
#   1. install.sh in the main checkout re-links its linked worktrees: in a
#      worktree whose scripts/ is a real directory (a tracked project file),
#      a stale regular copy of a harness script becomes a link (the differing
#      copy is kept under progress/stale_harness_copies/), an identical copy of
#      AGENTS.md becomes a link, a harness file missing there gets linked, and
#      the tracked project file is untouched.
#   2. install.sh refuses to run inside such a linked worktree.
#   3. link-worktree alone repairs the same way and reports each file.
#   4. project files that are only git-ignored (a .gitignore'd scripts/local.json,
#      .codex/config.toml under an ignored .codex/) and mock-data/ are never
#      replaced or backed up, by link-worktree or by install.sh in main.
#   5. record-usage with a collector that rejects its options prints a [WARN]
#      with the collector's error and still exits 0; stats shows that warning
#      before "no agent runs recorded".
#   6. a worktree whose .claude is a directory link to the main checkout's
#      .claude (the layout older link-worktree runs left): install.sh in main
#      and link-worktree never replace main's own agent files through it — they
#      stay regular files with their content and no self-referential link appears.
#   7. the same for a worktree whose scripts/ links to main's, and for a
#      worktree project directory that is itself a link to the main checkout
#      (link-worktree refuses it).
#   8. a worktree .claude linked to a folder outside both checkouts: nothing
#      there is deleted, replaced or linked.
#   9. without harness/installed-files.txt nothing is repaired.
#  10. install.sh in main fails loudly, before copying, on a self-referential
#      link or a linked directory where it would copy a harness file.
#  11. a worktree progress/ that links to main's is made local before the repair,
#      so backups never land in main's; a failed ln prints a [WARN] naming the
#      file; a real harness/instructions/ is repaired like scripts/; install.sh in
#      a partly linked worktree prints one summary [FAIL]; on a case-insensitive
#      volume the main checkout named in another case is refused as this checkout.
#
# Usage: bash tests/worktree_link_refresh_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

g() { git -C "$WORK/repo" -c user.email=t@t -c user.name=t "$@"; }
# Mirror sync is pointed at env vars that are never set: install.sh skips it.
install_into() {
  (cd "$1" && HOME="$WORK/home" bash "$TOOLKIT_DIR/install.sh" --slug wt-test --human-user Tester \
    --verify-command true --supabase-url-env HARNESS_TEST_UNSET_URL --supabase-key-env HARNESS_TEST_UNSET_KEY) 2>&1
}
H() { (cd "$1" && shift && HOME="$WORK/home" HARNESS_AGENT=implementer ANTHROPIC_MODEL= bash scripts/harness.sh "$@") 2>&1; }
is_link_to() { [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; }

P="$WORK/repo/app"
mkdir -p "$P/scripts"
git init -q "$WORK/repo"
printf 'console.log("env")\n' > "$P/scripts/write-env.mjs"
g add app/scripts/write-env.mjs && g commit -qm project >/dev/null || die "initial commit"
out=$(install_into "$P") || die "install in the main checkout: $out"
g add -A && g commit -qm docs >/dev/null || die "commit project-owned files"
g worktree add -q "$WORK/wt" 2>/dev/null || die "git worktree add"
W="$WORK/wt/app"
[ -d "$W/scripts" ] && [ ! -L "$W/scripts" ] || die "the worktree's scripts/ should be a real directory"
out=$(H "$P" link-worktree "$W") || die "link-worktree: $out"
is_link_to "$W/scripts/agent_usage.py" "$P/scripts/agent_usage.py" || die "first link-worktree should link agent_usage.py"

echo "1. install.sh in the main checkout refreshes linked worktrees"
# What an older toolkit left behind: a stale regular copy, an identical regular
# copy, and a harness file the worktree never got a link for.
rm "$W/scripts/agent_usage.py" && printf 'stale\n' > "$W/scripts/agent_usage.py"
rm "$W/AGENTS.md" && cp "$P/AGENTS.md" "$W/AGENTS.md"
rm "$W/scripts/time_phase.py"
cp "$W/scripts/write-env.mjs" "$WORK/write-env.before"
out=$(install_into "$P") || die "reinstall in the main checkout: $out"
is_link_to "$W/scripts/agent_usage.py" "$P/scripts/agent_usage.py" || die "stale copy should become a link: $(ls -la "$W/scripts")"
[ "$(cat "$W/progress/stale_harness_copies/scripts/agent_usage.py")" = stale ] || die "the differing copy must be kept aside"
is_link_to "$W/AGENTS.md" "$P/AGENTS.md" || die "identical AGENTS.md copy should become a link"
[ ! -e "$W/progress/stale_harness_copies/AGENTS.md" ] || die "an identical copy needs no backup"
is_link_to "$W/scripts/time_phase.py" "$P/scripts/time_phase.py" || die "missing harness file should be linked"
[ -f "$W/scripts/write-env.mjs" ] && [ ! -L "$W/scripts/write-env.mjs" ] && cmp -s "$WORK/write-env.before" "$W/scripts/write-env.mjs" \
  || die "the tracked project file must stay untouched"
grep -q 'replaced stale harness copies with links: .*scripts/agent_usage.py' <<<"$out" || die "install should report the repair: $out"
[ -z "$(git -C "$WORK/wt" status --porcelain --untracked-files=all)" ] || die "the worktree must stay clean: $(git -C "$WORK/wt" status --porcelain)"
pass "install.sh re-links worktrees, keeps the project file and backs up a differing copy"

echo "2. install.sh refuses a linked worktree"
out=$(install_into "$W") && die "install.sh inside a linked worktree must refuse: $out"
grep -q 'run install.sh in that main checkout' <<<"$out" || die "wrong refusal: $out"
is_link_to "$W/scripts/agent_usage.py" "$P/scripts/agent_usage.py" || die "a refused install must not touch the links"
pass "install.sh refuses to write through a linked worktree"

echo "3. link-worktree repairs on its own"
rm "$W/scripts/agent_usage.py" && cp "$P/scripts/agent_usage.py" "$W/scripts/agent_usage.py"
out=$(H "$P" link-worktree "$W") || die "link-worktree: $out"
is_link_to "$W/scripts/agent_usage.py" "$P/scripts/agent_usage.py" || die "link-worktree should replace the copy"
grep -q 'replaced stale harness copies with links: scripts/agent_usage.py' <<<"$out" || die "should report each repaired file: $out"
out=$(H "$P" link-worktree "$W") || die "link-worktree re-run: $out"
grep -q 'replaced stale' <<<"$out" && die "nothing left to repair on a re-run: $out"
pass "link-worktree replaces harness-owned copies, reports them and is idempotent"

echo "4. git-ignored project files and mock-data/ are left alone"
printf 'scripts/local.json\n.codex/\n' > "$P/.gitignore"
mkdir -p "$P/.codex" "$P/mock-data"
printf '{"port":1}\n' > "$P/scripts/local.json"
printf 'model = "main"\n' > "$P/.codex/config.toml"
printf '{"main":true}\n' > "$P/mock-data/selection.json"
for d in .codex mock-data; do
  if [ -L "$W/$d" ]; then rm "$W/$d"; fi
  mkdir -p "$W/$d"
done
printf '{"port":2}\n' > "$W/scripts/local.json"
printf 'model = "worktree"\n' > "$W/.codex/config.toml"
printf '{"worktree":true}\n' > "$W/mock-data/selection.json"
own="scripts/local.json .codex/config.toml mock-data/selection.json"
for f in $own; do cp "$W/$f" "$WORK/wt.$(basename "$f")"; cp "$P/$f" "$WORK/main.$(basename "$f")"; done
untouched() {
  local f
  for f in $own; do
    [ -f "$W/$f" ] && [ ! -L "$W/$f" ] || die "$1: $f must stay a regular file: $(ls -la "$W/$f")"
    cmp -s "$WORK/wt.$(basename "$f")" "$W/$f" || die "$1: the worktree's $f changed"
    cmp -s "$WORK/main.$(basename "$f")" "$P/$f" || die "$1: the main checkout's $f changed (write-through)"
    [ ! -e "$W/progress/stale_harness_copies/$f" ] && ! ls "$W/progress/stale_harness_copies/$f".* >/dev/null 2>&1 \
      || die "$1: $f must not be backed up"
  done
  ! grep -q 'replaced stale.*\(local.json\|config.toml\|selection.json\)' <<<"$out" || die "$1 reported a project file as a harness copy: $out"
}
git -C "$P" check-ignore -q scripts/local.json && git -C "$P" check-ignore -q .codex/config.toml || die "setup: the project files should be git-ignored in main"
out=$(H "$P" link-worktree "$W") || die "link-worktree: $out"
untouched "link-worktree"
out=$(install_into "$P") || die "reinstall in the main checkout: $out"
untouched "install.sh in main"
is_link_to "$W/scripts/agent_usage.py" "$P/scripts/agent_usage.py" || die "the toolkit's own files stay linked"
pass "ignored project files, user config and mock-data/ keep their content and type"

echo "5. record-usage with a broken collector"
Q="$WORK/solo"
mkdir -p "$Q/scripts"
cp "$TOOLKIT_DIR"/scripts/*.sh "$Q/scripts/"
echo '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state"}' > "$Q/.harness.json"
sqlite3 "$Q/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql"
sqlite3 "$Q/harness.db" "INSERT INTO projects (id, slug) VALUES ('p1','t');"
# A collector from before --reopen-warn-tokens existed: argparse rejects it.
cat > "$Q/scripts/agent_usage.py" <<'EOF'
import sys
if 'collect' in sys.argv:
    sys.stderr.write('usage: agent_usage.py [-h] ...\nagent_usage.py: error: unrecognized arguments: --reopen-warn-tokens 80000\n')
    sys.exit(2)
print('no agent runs recorded')
EOF
out=$(H "$Q" record-usage); rc=$?
[ "$rc" = 0 ] || die "record-usage must stay best-effort (exit 0), got $rc: $out"
grep -q '^\[WARN\].*record-usage failed: scripts/agent_usage.py exited 2.*unrecognized arguments: --reopen-warn-tokens' <<<"$out" \
  || die "record-usage should warn with the collector's error: $out"
out=$(H "$Q" stats); rc=$?
[ "$rc" = 0 ] || die "stats exit $rc: $out"
[ "$(printf '%s\n' "$out" | grep -n 'record-usage failed' | cut -d: -f1)" = 1 ] && [ "$(printf '%s\n' "$out" | grep -n 'no agent runs recorded' | cut -d: -f1)" = 2 ] \
  || die "stats should show the warning before 'no agent runs recorded': $out"
pass "record-usage warns about a failed collector and stats shows it"

# main_agents_intact <label> — main's agent files are regular, with their
# install-time content, and the main checkout holds no broken or looping link.
cp -R "$P/.claude/agents" "$WORK/main-agents.before"
main_agents_intact() {
  local f n=0
  for f in "$WORK/main-agents.before"/*.md; do
    n=$((n + 1))
    [ -f "$P/.claude/agents/${f##*/}" ] && [ ! -L "$P/.claude/agents/${f##*/}" ] \
      || die "$1: main's .claude/agents/${f##*/} must stay a regular file: $(ls -la "$P/.claude/agents/${f##*/}" 2>&1)"
    cmp -s "$f" "$P/.claude/agents/${f##*/}" || die "$1: main's .claude/agents/${f##*/} lost its content"
  done
  [ "$n" -gt 0 ] || die "setup: no agent files in main"
  [ -z "$(find -L "$P" -type l 2>/dev/null)" ] || die "$1: broken or looping links in main: $(find -L "$P" -type l 2>/dev/null)"
}

echo "6. a worktree .claude linked to main's .claude"
rm -rf "$W/.claude" && ln -s "$P/.claude" "$W/.claude"
out=$(install_into "$P") || die "reinstall in the main checkout: $out"
main_agents_intact "install.sh in main"
out=$(H "$P" link-worktree "$W") || die "link-worktree: $out"
main_agents_intact "link-worktree"
cmp -s "$WORK/main-agents.before/implementer.md" "$W/.claude/agents/implementer.md" || die "the worktree must still read the agents"
grep -q 'replaced stale.*\.claude' <<<"$out" && die "nothing under a linked .claude may be repaired: $out"
pass "main's agent files survive a worktree .claude that links to them"

echo "7. a worktree scripts/ linked to main's, and a worktree project dir linked to main"
cp -R "$P/scripts" "$WORK/main-scripts.before"
mv "$W/scripts" "$WORK/wt-scripts.real" && ln -s "$P/scripts" "$W/scripts"
out=$(H "$P" link-worktree "$W") || die "link-worktree: $out"
out=$(install_into "$P") || die "reinstall in the main checkout: $out"
for f in "$WORK/main-scripts.before"/*; do
  [ -f "$P/scripts/${f##*/}" ] && [ ! -L "$P/scripts/${f##*/}" ] || die "main's scripts/${f##*/} must stay a regular file"
done
main_agents_intact "scripts/ linked"
rm "$W/scripts" && mv "$WORK/wt-scripts.real" "$W/scripts"
git -C "$WORK/repo" worktree add -q "$WORK/wt2" 2>/dev/null || die "git worktree add wt2"
rm -rf "$WORK/wt2/app" && ln -s "$P" "$WORK/wt2/app"
out=$(H "$P" link-worktree "$WORK/wt2/app") && die "a worktree dir that resolves to the main checkout must be refused: $out"
main_agents_intact "worktree dir linked to main"
for f in "$WORK/main-scripts.before"/*; do
  [ -f "$P/scripts/${f##*/}" ] && [ ! -L "$P/scripts/${f##*/}" ] || die "main's scripts/${f##*/} must stay a regular file after the refusal"
done
out=$(install_into "$P") || die "reinstall with wt2 linked to main: $out"
main_agents_intact "install.sh with a worktree dir linked to main"
rm "$WORK/wt2/app" && git -C "$WORK/repo" worktree remove --force "$WORK/wt2" 2>/dev/null
pass "linked scripts/ and a worktree dir that is main itself leave main's files alone"

echo "8. a worktree .claude linked outside both checkouts"
mkdir -p "$WORK/outside" && cp -R "$P/.claude" "$WORK/outside/.claude"
cp -R "$WORK/outside/.claude" "$WORK/outside.before"
rm "$W/.claude" && ln -s "$WORK/outside/.claude" "$W/.claude"
out=$(H "$P" link-worktree "$W") || die "link-worktree: $out"
out=$(install_into "$P") || die "reinstall in the main checkout: $out"
[ -z "$(find "$WORK/outside" -type l)" ] || die "no link may be written outside the worktree: $(find "$WORK/outside" -type l)"
diff -r "$WORK/outside.before" "$WORK/outside/.claude" >/dev/null || die "the outside folder changed"
main_agents_intact "outside link"
pass "a .claude linked outside both checkouts is left alone"

echo "9. no installed-files list, no repair"
rm "$W/.claude" && mkdir -p "$W/.claude"
out=$(H "$P" link-worktree "$W") || die "link-worktree: $out"
is_link_to "$W/.claude/agents" "$P/.claude/agents" || die "link-worktree should link .claude/agents: $(ls -la "$W/.claude")"
mv "$P/harness/installed-files.txt" "$WORK/installed-files.txt"
rm "$W/AGENTS.md" && cp "$P/AGENTS.md" "$W/AGENTS.md"
out=$(H "$P" link-worktree "$W") || die "link-worktree: $out"
[ -f "$W/AGENTS.md" ] && [ ! -L "$W/AGENTS.md" ] || die "without the list the copy must stay"
grep -q 'replaced stale' <<<"$out" && die "without the list nothing is repaired: $out"
mv "$WORK/installed-files.txt" "$P/harness/installed-files.txt"
out=$(H "$P" link-worktree "$W") || die "link-worktree: $out"
is_link_to "$W/AGENTS.md" "$P/AGENTS.md" || die "with the list back the copy is repaired"
pass "without harness/installed-files.txt nothing is repaired"

echo "10. install.sh refuses a self-referential link or a linked directory in main"
cp "$P/.claude/agents/reviewer.md" "$WORK/reviewer.md.bak"
rm "$P/.claude/agents/reviewer.md" && ln -s "$P/.claude/agents/reviewer.md" "$P/.claude/agents/reviewer.md"
out=$(install_into "$P") && die "install.sh must fail on a self-referential link: $out"
grep -q '\[FAIL\].*\.claude/agents/reviewer.md' <<<"$out" || die "the failure must name the link: $out"
grep -q 'Copying harness-core files' <<<"$out" && die "it must fail before copying: $out"
rm "$P/.claude/agents/reviewer.md" && cp "$WORK/reviewer.md.bak" "$P/.claude/agents/reviewer.md"
mv "$P/.codex" "$WORK/codex-elsewhere" && ln -s "$WORK/codex-elsewhere" "$P/.codex"
cp -R "$WORK/codex-elsewhere" "$WORK/codex.before"
out=$(install_into "$P") && die "install.sh must fail on a linked directory: $out"
grep -q '\[FAIL\].*\.codex' <<<"$out" || die "the failure must name the linked directory: $out"
diff -r "$WORK/codex.before" "$WORK/codex-elsewhere" >/dev/null || die "nothing may be written through the link"
rm "$P/.codex" && mv "$WORK/codex-elsewhere" "$P/.codex"
out=$(install_into "$P") || die "install.sh after the links are fixed: $out"
main_agents_intact "after the refused installs"
pass "install.sh fails loudly before writing through a link"

echo "11. backups stay in the worktree, failures warn, nested toolkit dirs, path case"
WR="$(cd "$W" && pwd -P)"
# A worktree progress/ that links to main's: the backup lands in the worktree's own real
# progress/, never in main's, and the message names where it is.
rm -rf "$W/progress" && ln -s "$P/progress" "$W/progress"
rm "$W/scripts/agent_usage.py" && printf 'stale2\n' > "$W/scripts/agent_usage.py"
ls "$P/progress/stale_harness_copies" >/dev/null 2>&1 && die "setup: main has no backups"
out=$(H "$P" link-worktree "$W") || die "link-worktree: $out"
[ -d "$W/progress" ] && [ ! -L "$W/progress" ] || die "progress/ must be local"
is_link_to "$W/scripts/agent_usage.py" "$P/scripts/agent_usage.py" || die "the stale copy should be replaced"
[ "$(cat "$W/progress/stale_harness_copies/scripts/agent_usage.py")" = stale2 ] || die "the backup must be in the worktree's own progress/"
[ ! -e "$P/progress/stale_harness_copies" ] || die "no backup may go into main's progress/: $(ls -R "$P/progress")"
grep -qF "kept in $WR/progress/stale_harness_copies/" <<<"$out" || die "the message must name the backups' real location: $out"
# ln fails (a read-only scripts/): a [WARN] names the file and says the copy is unchanged.
rm "$W/scripts/agent_usage.py" && printf 'stale3\n' > "$W/scripts/agent_usage.py"
chmod a-w "$W/scripts"
out=$(H "$P" link-worktree "$W"); rc=$?
chmod u+w "$W/scripts"
[ "$rc" = 0 ] || die "a failed repair is a warning, not a failure: $out"
grep -q "WARN.*could not create a link for $W/scripts/agent_usage.py (ln -s failed): the copy stays where it was, unchanged" <<<"$out" \
  || die "a failed ln must warn naming the file and that it is unchanged: $out"
[ -f "$W/scripts/agent_usage.py" ] && [ ! -L "$W/scripts/agent_usage.py" ] && [ "$(cat "$W/scripts/agent_usage.py")" = stale3 ] \
  || die "after a failed ln the copy must be unchanged"
ls "$W/scripts"/*.harness-relink* >/dev/null 2>&1 && die "no temp file may be left"
out=$(H "$P" link-worktree "$W") || die "link-worktree: $out"
is_link_to "$W/scripts/agent_usage.py" "$P/scripts/agent_usage.py" || die "once writable the copy is replaced"
# A real harness/instructions/ in the worktree: its stale copies are replaced and missing
# files linked, by the same rules (backup kept).
rm "$W/harness" && mkdir -p "$W/harness/instructions" && printf 'stale\n' > "$W/harness/instructions/persona.md"
out=$(H "$P" link-worktree "$W") || die "link-worktree: $out"
is_link_to "$W/harness/instructions/persona.md" "$P/harness/instructions/persona.md" || die "a stale instruction copy should become a link: $out"
is_link_to "$W/harness/instructions/testing.md" "$P/harness/instructions/testing.md" || die "a missing instruction file should be linked: $out"
[ "$(cat "$W/progress/stale_harness_copies/harness/instructions/persona.md")" = stale ] || die "the differing instruction copy must be kept"
grep -q 'replaced stale harness copies with links: .*harness/instructions/persona.md' <<<"$out" || die "the repair must be reported: $out"
rm -rf "$W/harness" && H "$P" link-worktree "$W" >/dev/null && is_link_to "$W/harness" "$P/harness" || die "restore harness link"
# install.sh in a partly linked worktree (a regular scripts/harness.sh, the rest links):
# one summary [FAIL] with the count, the first paths and the main-checkout hint.
rm "$W/scripts/harness.sh" "$W/harness.db" && cp "$P/scripts/harness.sh" "$W/scripts/harness.sh"
out=$(install_into "$W") && die "install.sh in a partly linked worktree must refuse: $out"
[ "$(grep -c '\[FAIL\]' <<<"$out")" = 1 ] || die "one summary [FAIL] line expected: $out"
grep -q '\[FAIL\].*[0-9][0-9]* harness path(s) are links.*and [0-9][0-9]* more.*linked git worktree: run install.sh in its main checkout' <<<"$out" \
  || die "the summary must give the count, the first paths and the hint: $out"
rm "$W/scripts/harness.sh" && ln -s "$P/scripts/harness.sh" "$W/scripts/harness.sh" && ln -s "$P/harness.db" "$W/harness.db" || die "restore links"
main_agents_intact "partly linked worktree install"
# A case-insensitive volume: the main checkout named in another case is still this checkout,
# and a worktree named in another case is repaired normally.
PU="$(printf '%s' "$P" | tr '[:lower:]' '[:upper:]')"; WU="$(printf '%s' "$W" | tr '[:lower:]' '[:upper:]')"
if [ "$PU" != "$P" ] && [ -d "$PU" ] && [ "$PU" -ef "$P" ]; then
  out=$(H "$P" link-worktree "$PU") && die "the main checkout in another case must be refused: $out"
  grep -q 'not this checkout' <<<"$out" || die "the refusal must say it is this checkout: $out"
  rm "$W/AGENTS.md" && cp "$P/AGENTS.md" "$W/AGENTS.md"
  out=$(H "$P" link-worktree "$WU") || die "link-worktree with the worktree in another case: $out"
  [ -L "$W/AGENTS.md" ] && [ "$W/AGENTS.md" -ef "$P/AGENTS.md" ] || die "a worktree named in another case must still be repaired: $out"
  main_agents_intact "path case"
  echo "  (case-insensitive volume: path-case checks ran)"
fi
pass "backups stay in the worktree's own progress/, a failed ln warns, harness/instructions/ is repaired, one summary refusal, path case"

echo "all $PASS checks passed"
