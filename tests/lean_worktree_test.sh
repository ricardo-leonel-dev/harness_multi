#!/usr/bin/env bash
# lean_worktree_test.sh — the lean flow in a project that is a git worktree, or a
# subfolder of its repository (a monorepo's backend/), checked in throwaway dirs:
#
#   1. lean/sandbox.sh lets the session read the resolved target of each top-level
#      symlink git tracks or ignores (not one a session planted) and the git directories (carved out of the denied siblings, added to
#      allowRead, Edit denied), keeps private folders and the frozen manifests denied
#      even through a symlink, and sets RUSTC_WRAPPER/CARGO_BUILD_RUSTC_WRAPPER empty
#      and GIT_OPTIONAL_LOCKS=0.
#   2. With sandbox-exec (macOS), the same rules applied for real: cat through the
#      symlinks and git status/diff in the worktree and in a plain repo's subfolder
#      work; a sibling project, the frozen manifest and writes through a symlink don't.
#   3. lean/gate.sh in a subfolder project (services/api/): **Files** / **Changed tests**
#      paths relative to the project or spelled from the repository root both pass, an
#      unlisted file still fails, a change outside the project fails (named from the
#      repository root) unless git ignores it, a prefixed path names the project's own
#      file when one is there (p/p/x), the frozen manifest is read relative to the project.
#
# Usage: bash tests/lean_worktree_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"   # resolved: the sandbox compares real paths
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }
g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

export HOME="$WORK/home"
DEV="$HOME/Documents/Dev"
MAIN="$DEV/mono"; WT="$DEV/mono-wt"; P="$WT/backend"
mkdir -p "$MAIN/backend/src" "$MAIN/backend/lean/risk-questions" "$MAIN/backend/migrations" \
  "$DEV/other" "$HOME/.ssh" "$HOME/.cache/harness/t/frozen"
printf 'secret\n' > "$DEV/other/secret.txt"
printf 'key\n' > "$HOME/.ssh/id"
printf 'abc  acceptance/x.test.sh\n' > "$HOME/.cache/harness/t/frozen/x.sha"
printf 'db\n' > "$MAIN/backend/harness.db"
printf '# risks\n' > "$MAIN/backend/lean/risk-questions/backend.md"
printf 'create table t();\n' > "$MAIN/backend/migrations/0001.sql"
printf 'not linked\n' > "$MAIN/backend/unlinked.txt"
printf 'harness.db\nlean\nmigrations\nfrozen\nssh\n' > "$MAIN/backend/.gitignore"
printf 'a\n' > "$MAIN/backend/src/a.txt"
g -C "$MAIN" init -q && g -C "$MAIN" add -A && g -C "$MAIN" commit -qm base || die "git setup"
g -C "$MAIN" worktree add -q "$WT" -b wt >/dev/null 2>&1 || die "worktree add"
mkdir -p "$WT/frontend" && printf 'f\n' > "$WT/frontend/f.txt"   # a sibling folder of the repository
for l in harness.db lean migrations; do ln -s "$MAIN/backend/$l" "$P/$l"; done
ln -s "$HOME/.cache/harness/t/frozen" "$P/frozen"
ln -s "$HOME/.ssh" "$P/ssh"
# Links git knows: one excluded (the common dir's info/exclude, as link-worktree writes it),
# one committed. And one a session could have planted: untracked, not ignored.
mkdir -p "$DEV/shared" "$DEV/shared2" && printf 's\n' > "$DEV/shared/s.txt" && printf 't\n' > "$DEV/shared2/t.txt"
ln -s "$DEV/shared" "$P/excl" && printf '/backend/excl\n' >> "$MAIN/.git/info/exclude"
ln -s "$DEV/shared2" "$P/tracked" && g -C "$WT" add backend/tracked && g -C "$WT" commit -qm link || die "tracked link"
(cd "$P" && ln -s ../../other planted)
echo '{"project_slug":"t"}' > "$P/.harness.json"

echo "1. sandbox settings"
S=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$P" 2>"$WORK/sandbox.err") || die "sandbox.sh failed: $(cat "$WORK/sandbox.err")"
allow=$(jq -r '.sandbox.filesystem.allowRead[]' <<<"$S")
deny=$(jq -r '.sandbox.filesystem.denyRead[]' <<<"$S")
rules=$(jq -r '.permissions.deny[]' <<<"$S")
# denied <path>: some denyRead entry is <path> or holds it.
denied() { while IFS= read -r d; do case "$1/" in "$d"/*) return 0 ;; esac; done <<<"$deny"; return 1; }
for t in "$MAIN/backend/harness.db" "$MAIN/backend/lean" "$MAIN/backend/migrations" "$DEV/shared" "$DEV/shared2" "$WT/.git" "$MAIN/.git" "$MAIN/.git/worktrees/mono-wt"; do
  grep -qxF "$t" <<<"$allow" || die "allowRead should hold $t: $allow"
  denied "$t" && die "$t should not be denied: $deny"
  grep -qxF "Read(/$t/**)" <<<"$rules" && die "$t should have no Read deny rule"
done
grep -qxF "Edit(/$MAIN/backend/harness.db)" <<<"$rules" && grep -qxF "Edit(/$MAIN/backend/lean/**)" <<<"$rules" \
  || die "symlink targets should get Edit deny rules: $rules"
denied "$MAIN/backend/unlinked.txt" || die "the rest of the main worktree should stay denied"
denied "$DEV/other/secret.txt" || die "a sibling project should stay denied"
denied "$HOME/.cache/harness/t/frozen" && denied "$HOME/.ssh" || die "frozen manifests and ~/.ssh should stay denied"
grep -q "$HOME/.cache/harness" <<<"$allow" && die "a symlink into the frozen manifests must not open them"
grep -q "$HOME/.ssh" <<<"$allow" && die "a symlink into ~/.ssh must not open it"
grep -q 'stays unreadable' "$WORK/sandbox.err" || die "a refused symlink should be named on stderr"
grep -qxF "$DEV/other" <<<"$allow" && die "a planted (untracked, not ignored) link must not open its target: $allow"
grep -q "$P/planted .*neither tracks nor ignores" "$WORK/sandbox.err" || die "the planted link should be named on stderr: $(cat "$WORK/sandbox.err")"
# Re-pointing a committed link makes it a planted one too.
rm "$P/tracked" && ln -s "$DEV/other" "$P/tracked"
S3=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$P" 2>/dev/null) || die "sandbox.sh with a re-pointed link"
jq -r '.sandbox.filesystem.allowRead[]' <<<"$S3" | grep -qxF "$DEV/other" && die "a re-pointed committed link must not open its new target"
rm "$P/tracked" && ln -s "$DEV/shared2" "$P/tracked"
[ "$(jq -c .env <<<"$S")" = '{"RUSTC_WRAPPER":"","CARGO_BUILD_RUSTC_WRAPPER":"","GIT_OPTIONAL_LOCKS":"0"}' ] \
  || die "session env: $(jq -c .env <<<"$S")"
pass "known symlink targets and git dirs readable; planted links, private and frozen stay denied; session env set"

# A plain repository whose project is a subfolder: .git sits next to it.
R="$DEV/plain"; Q="$R/sub"
mkdir -p "$Q" && printf 'x\n' > "$Q/x.txt" && echo '{}' > "$Q/.harness.json"
g -C "$R" init -q && g -C "$R" add -A && g -C "$R" commit -qm base || die "plain git setup"
S2=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$Q" 2>/dev/null) || die "sandbox.sh on a subfolder failed"
jq -r '.sandbox.filesystem.allowRead[]' <<<"$S2" | grep -qxF "$R/.git" || die "a subfolder project should read the repo's .git"
deny=$(jq -r '.sandbox.filesystem.denyRead[]' <<<"$S2")
denied "$R/.git" && die "the repo's .git should not be denied"
pass "a project in a repository's subfolder can read the repository's .git"

echo "2. sandbox-exec"
if ! command -v sandbox-exec >/dev/null 2>&1 || ! sandbox-exec -p '(version 1)(allow default)' true 2>/dev/null; then
  echo "  skip sandbox-exec not available"
else
  # The settings' temp dir holds $WORK itself here, so a scratch dir stands in for it.
  tmp="$WORK/scratch"; mkdir -p "$tmp"
  # profile <settings> <project>: the settings' denyRead and write limits as a seatbelt
  # profile. allowRead is left out on purpose: the denies alone must not cover the targets.
  profile() {
    printf '(version 1)\n(allow default)\n'
    jq -r '.sandbox.filesystem.denyRead[] | "(deny file-read* (subpath \(tojson)))"' <<<"$1"
    printf '(deny file-write*)\n(allow file-write* (subpath "%s") (subpath "%s") (subpath "/dev"))\n' "$2" "$tmp"
  }
  run_in() { # run_in <settings> <project> <command...>
    local s="$1" p="$2"; shift 2
    env $(jq -r '.env | to_entries[] | "\(.key)=\(.value)"' <<<"$s") sandbox-exec -p "$(profile "$s" "$p")" "$@"
  }
  run_in "$S" "$P" cat "$P/harness.db" >/dev/null 2>&1 || die "cat through the harness.db symlink"
  run_in "$S" "$P" cat "$P/lean/risk-questions/backend.md" >/dev/null 2>&1 || die "cat lean/risk-questions/backend.md"
  run_in "$S" "$P" ls "$P/migrations" >/dev/null 2>&1 || die "ls migrations/"
  run_in "$S" "$P" cat "$P/excl/s.txt" >/dev/null 2>&1 || die "cat through an excluded link"
  run_in "$S" "$P" cat "$P/tracked/t.txt" >/dev/null 2>&1 || die "cat through a committed link"
  run_in "$S" "$P" cat "$P/planted/secret.txt" >/dev/null 2>&1 && die "a planted link must not be readable"
  printf 'b\n' >> "$P/src/a.txt"
  out=$(run_in "$S" "$P" git -C "$P" status --short 2>&1) && grep -q 'src/a.txt' <<<"$out" || die "git status in the worktree: $out"
  out=$(run_in "$S" "$P" git -C "$P" diff 2>&1) && grep -q '^+b' <<<"$out" || die "git diff in the worktree: $out"
  run_in "$S" "$P" cat "$DEV/other/secret.txt" >/dev/null 2>&1 && die "a sibling project must stay unreadable"
  run_in "$S" "$P" cat "$P/frozen/x.sha" >/dev/null 2>&1 && die "the frozen manifest must stay unreadable through a symlink"
  run_in "$S" "$P" cat "$MAIN/backend/unlinked.txt" >/dev/null 2>&1 && die "the main worktree's other files must stay unreadable"
  run_in "$S" "$P" sh -c "echo x >> '$P/harness.db'" 2>/dev/null && die "writing through a symlink must fail"
  printf 'y\n' >> "$Q/x.txt"
  out=$(run_in "$S2" "$Q" git -C "$Q" status --short 2>&1) && grep -q 'x.txt' <<<"$out" || die "git status in a subfolder project: $out"
  pass "sandboxed: reads through symlinks and git work; siblings, frozen manifests and writes outside stay blocked"
fi

echo "3. gate in a subfolder project"
# The prefix comes from git, not a folder name: a two-level services/api/ project.
G="$WORK/gate"; B="$G/services/api"; PX=services/api/
mkdir -p "$B/src" "$B/tests" "$B/docs/features" "$B/acceptance" "$B/services/api" "$G/web"
echo '{"project_slug":"gt","verify_command":"true"}' > "$B/.harness.json"
printf 'a\n' > "$B/src/a.txt"; printf 'b\n' > "$B/src/b.txt"
printf 'top\n' > "$B/x.txt"; printf 'nested\n' > "$B/services/api/x.txt"   # project's x.txt and p/p/x.txt
printf '  assert true\n  assert true 2\n' > "$B/tests/app_test.sh"
printf 'ok\n' > "$B/acceptance/f.test.sh"
printf 'z\n' > "$G/outside.txt"; printf 'w\n' > "$G/web/w.txt"
printf 'web/ignored.log\n' > "$G/.gitignore"
g -C "$G" init -q && g -C "$G" add -A && g -C "$G" commit -qm base || die "gate git setup"
fdoc() { # fdoc <files...> [-- <changed tests...>]
  { echo "# f"; echo; echo "**Files**"
    while [ $# -gt 0 ] && [ "$1" != -- ]; do echo "- \`$1\`: why"; shift; done
    echo; echo "**Changed tests**"; [ $# -gt 0 ] && shift
    while [ $# -gt 0 ]; do echo "- \`$1\`: why"; shift; done
  } > "$B/docs/features/f.md"
}
gate() { bash "$TOOLKIT_DIR/lean/gate.sh" "$B" f "$@" 2>&1; }
printf 'a2\n' >> "$B/src/a.txt"; printf 'b2\n' >> "$B/src/b.txt"
printf '  assert true\n' > "$B/tests/app_test.sh"
printf 'ignored\n' > "$G/web/ignored.log"   # outside the project but ignored by git: not checked
fdoc src/a.txt ${PX}src/b.txt ${PX}tests/app_test.sh -- ${PX}tests/app_test.sh
out=$(gate) || die "both spellings should pass: $out"
grep -q 'ALL CHECKS PASS' <<<"$out" || die "gate: $out"
fdoc src/a.txt src/b.txt tests/app_test.sh -- tests/app_test.sh
out=$(gate) || die "project-relative paths should pass: $out"
fdoc src/a.txt tests/app_test.sh -- tests/app_test.sh
out=$(gate) && die "an unlisted file must fail"
grep -qx 'src/b.txt' <<<"$out" || die "the unlisted file should be named relative to the project: $out"
fdoc src/a.txt src/b.txt tests/app_test.sh
out=$(gate) && die "a removed assertion not listed must fail"
grep -q 'ASSERTION LINES REMOVED FROM tests/app_test.sh' <<<"$out" || die "removed assertion: $out"
pass "gate: project-relative and repo-root spellings pass, unlisted files and removed assertions still fail"

# Outside the project: a changed tracked file and a new untracked one fail, named from the root,
# even when listed; ../ or a root spelling can't list them.
printf 'z2\n' >> "$G/outside.txt"; printf 'n\n' > "$G/web/new.txt"
fdoc src/a.txt src/b.txt tests/app_test.sh outside.txt ../web/new.txt -- tests/app_test.sh
out=$(gate) && die "a change outside the project must fail: $out"
grep -q 'CHANGED OUTSIDE THE PROJECT DIRECTORY' <<<"$out" && grep -qx 'outside.txt' <<<"$out" && grep -qx 'web/new.txt' <<<"$out" \
  || die "outside changes should be named by their repository-root path: $out"
grep -q 'ignored.log' <<<"$out" && die "an ignored file outside the project is not checked: $out"
g -C "$G" checkout -q -- outside.txt && rm "$G/web/new.txt"
pass "gate: a changed or untracked file outside the project fails, named from the repository root; ignored ones don't"

# The p/p/x rule: services/api/x.txt names the project's own services/api/x.txt, which exists;
# the project's top-level x.txt then needs its own line.
printf 't1\n' >> "$B/x.txt"
fdoc src/a.txt src/b.txt tests/app_test.sh ${PX}x.txt -- tests/app_test.sh
out=$(gate) && die "${PX}x.txt names the existing nested file (unchanged), not the project's x.txt"
grep -qx 'x.txt' <<<"$out" || die "x.txt should be reported unlisted: $out"
g -C "$G" checkout -q -- services/api/x.txt
printf 'n2\n' >> "$B/services/api/x.txt"
out=$(gate) || die "${PX}x.txt should name the existing nested file: $out"
printf 't2\n' >> "$B/x.txt"
out=$(gate) && die "the top-level x.txt is not listed by ${PX}x.txt when the nested one exists"
grep -qx 'x.txt' <<<"$out" || die "x.txt should be reported unlisted: $out"
fdoc src/a.txt src/b.txt tests/app_test.sh x.txt ${PX}x.txt -- tests/app_test.sh
out=$(gate) || die "both x.txt files listed should pass: $out"
g -C "$G" checkout -q -- services/api/services services/api/x.txt
pass "gate: a prefixed path names the project's own file when one is there (the p/p/x case)"

fdoc src/a.txt src/b.txt tests/app_test.sh -- tests/app_test.sh
for spelling in "" "$PX"; do
  (cd "$B" && shasum -a 256 acceptance/f.test.sh) | sed "s|  acceptance/|  ${spelling}acceptance/|" > "$WORK/f.sha"
  out=$(gate --frozen "$WORK/f.sha") || die "frozen manifest spelled '${spelling}acceptance/' should pass: $out"
done
printf 'changed\n' > "$B/acceptance/f.test.sh"
out=$(gate --frozen "$WORK/f.sha") && die "a changed frozen file must fail"
grep -q 'FROZEN ACCEPTANCE TESTS CHANGED' <<<"$out" || die "frozen change: $out"
pass "gate: the frozen manifest is read relative to the project in both spellings; a changed frozen file fails"

echo "all $PASS checks passed"
