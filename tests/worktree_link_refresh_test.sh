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

echo "all $PASS checks passed"
