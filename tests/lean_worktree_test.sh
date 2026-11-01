#!/usr/bin/env bash
# lean_worktree_test.sh — the lean flow in a project that is a git worktree, or a
# subfolder of its repository (a monorepo's backend/), checked in throwaway dirs:
#
#   1. lean/sandbox.sh lets the session read the resolved target of each top-level symlink
#      git tracks or ignores (not one it neither tracks nor ignores, nor a re-pointed committed
#      one) and the git directories (carved out of the denied siblings, added to allowRead,
#      Edit denied), keeps private folders and the frozen manifests denied even through a
#      symlink, and sets the session environment.
#   2. With sandbox-exec (macOS), the same rules applied for real: cat through the
#      symlinks and git status/diff in the worktree and in a plain repo's subfolder
#      work; a sibling project, the frozen manifest and writes through a symlink don't.
#   3. lean/gate.sh in a subfolder project (services/api/): **Files** / **Changed tests**
#      paths relative to the project or spelled from the repository root both pass, an
#      unlisted file still fails, a change outside the project fails (named from the
#      repository root) unless git ignores it, a prefixed path names the project's own
#      file when one is there (p/p/x), the frozen manifest is read relative to the project,
#      a moved HEAD fails, and a user's diff.relative=true changes nothing.
#   4. lean/run.sh through a fake claude (it records the settings): an excluded link reads, an
#      untracked one doesn't. The git state is write-denied: in sandbox-exec, git commit/add
#      and a write to .git/info/exclude fail, git init can't create the project's missing .git,
#      status/diff/log/show work.
#   5. The lean state (trusted hashes, frozen manifest) is keyed by the project's resolved
#      path: a slug change between steps is refused as a trusted-file change, and once
#      accepted doesn't drop risk mode; a changed lean/ file stops the next step; state kept
#      under the slug is adopted once.
#   6. denyWrite/Edit deny cover the harness-owned paths; in sandbox-exec, writing, removing
#      or replacing lean/, scripts/, .harness.json, the database, init.sh, .claude/, .codex/,
#      AGENTS.md, CLAUDE.md, .mcp.json or harness/ fails (also the worktree's links, section 2);
#      project files stay writable.
#   7. $HOME is denied by default, checked on the real `sandbox.sh --seatbelt` profile (the
#      gate's) and on the settings: credentials and other projects are unreadable, also the
#      credential files inside allowed toolchain folders (the re-denies come after the
#      allows; allowRead never holds a re-denied path), ~/.gitconfig and ~/.local/share
#      outside the toolchain subfolders; toolchains and lean.allowed_read are readable; a
#      lean.allowed_read entry that reaches a protected path through `..` or a link is
#      refused in every form. ~/.claude (but the project's own folder), uv's credential
#      store, /Volumes, the per-user cache dir and Claude Code's temp folder (a fake one: the
#      project's own entry is denied in the gate's profile and re-opened for the session)
#      are unreadable.
#   8. lean/gate.sh runs the suite under the sessions' rules (sandbox-exec), or warns that it
#      runs unsandboxed (no sandbox-exec, LEAN_GATE_UNSANDBOXED=1).
#   9. Unix sockets (real profile): a Docker-like socket in $HOME, the real /var/run/docker.sock
#      and an ssh-agent-like socket are unreachable; a database socket (in a folder of the
#      test's own, LEAN_DB_SOCK_DIR) and one in the project are reachable. The gate's suite
#      runs without SSH_AUTH_SOCK and secret-looking variables (but lean.env_passthrough),
#      with GIT_CONFIG_GLOBAL=/dev/null, in a process group killed when it ends (with a
#      [WARN] in the report); fds above 2 are closed; run from a pty, a TIOCSTI suite pushes
#      nothing into the terminal; sandbox.sh's [WARN] (allowed_domains) reaches gate.sh and
#      run.sh gate; CLAUDE.local.md and nested CLAUDE.md / CLAUDE.local.md are write-denied
#      and trusted.
#  10. Mach services are denied but for an allowlist (lean.allowed_mach can't add
#      LEAN_MACH_NEVER; checked on the generated profile), lookups of LaunchServices, lsd,
#      Apple Events and the pasteboard refused (1100), launchctl (help only, directly, through
#      a link or a copy), cfprefsd's agent (a lookup: 1100 inside, 0 outside),
#      signals to outside processes, writes and ioctls on a terminal (sandbox_check: nothing
#      opened); git, python, node and cargo (where installed) still run, writing only in the
#      run's own TMPDIR. Every check that could touch real system state runs only inside the
#      profile, output discarded; unsandboxed controls only where they have no side effect.
#      The env scrub reads the names from the environment (non-identifier names, multi-line
#      values; bash and /bin/bash; perl without env -0, fails closed without both) and drops
#      GIT_CONFIG_*, npm/yarn auth, MYSQL_PWD, passphrases, *_KEY, *_PASS, *_PAT, cookies,
#      Docker and Gradle signing credentials and bundler credentials, and strips proxy URLs'
#      credentials; lean_in_group runs nothing without perl. The gate refuses a nested
#      CLAUDE.md / CLAUDE.local.md or .claude/ file not tracked unchanged at the base
#      (carried into an ignored folder by a rename, any case), paths with a newline and
#      folders it can't list; lean_run_lock runs one sandboxed run of a project at a time.
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

# Nothing under the real home is run or looked up (toolchains found through PATH there),
# and Claude Code's real temp folder is never consulted: a fake, missing one stands in.
REAL_HOME="$HOME"
PATH=$(printf '%s\n' "$PATH" | tr ':' '\n' | grep -vF "$REAL_HOME/" | paste -sd: -)
# Database sockets are looked for in a folder of the test's own (LEAN_DB_SOCK_DIR) instead of
# the real /private/tmp, where nothing is bound.
export HOME="$WORK/home" LEAN_CLAUDE_TMP="$WORK/no-claude-tmp" LEAN_DB_SOCK_DIR="$WORK/dbs"
mkdir -p "$LEAN_DB_SOCK_DIR"
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
# one committed. And one git neither tracks nor ignores (a stray or planted one).
mkdir -p "$DEV/shared" "$DEV/shared2" && printf 's\n' > "$DEV/shared/s.txt" && printf 't\n' > "$DEV/shared2/t.txt"
ln -s "$DEV/shared" "$P/excl" && printf '/backend/excl\n' >> "$MAIN/.git/info/exclude"
ln -s "$DEV/shared2" "$P/tracked" && g -C "$WT" add backend/tracked && g -C "$WT" commit -qm link || die "tracked link"
echo '{"project_slug":"t"}' > "$P/.harness.json"
(cd "$P" && ln -s ../../other planted)

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
grep -qxF "$DEV/other" <<<"$allow" && die "an untracked, not ignored link must not open its target: $allow"
grep -q "$P/planted .*neither tracks nor ignores" "$WORK/sandbox.err" || die "the untracked link should be named on stderr: $(cat "$WORK/sandbox.err")"
# Re-pointing a committed link makes it a planted one too.
rm "$P/tracked" && ln -s "$DEV/other" "$P/tracked"
S3=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$P" 2>/dev/null) || die "sandbox.sh with a re-pointed link"
jq -r '.sandbox.filesystem.allowRead[]' <<<"$S3" | grep -qxF "$DEV/other" && die "a re-pointed committed link must not open its new target"
rm "$P/tracked" && ln -s "$DEV/shared2" "$P/tracked"
[ "$(jq -c .env <<<"$S")" = '{"RUSTC_WRAPPER":"","CARGO_BUILD_RUSTC_WRAPPER":"","GIT_OPTIONAL_LOCKS":"0","GIT_CONFIG_GLOBAL":"/dev/null","SSH_AUTH_SOCK":""}' ] \
  || die "session env: $(jq -c .env <<<"$S")"
pass "known symlink targets and git dirs readable; untracked or re-pointed links, private and frozen stay denied; session env set"

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
have_sbx=0
command -v sandbox-exec >/dev/null 2>&1 && sandbox-exec -p '(version 1)(allow default)' true 2>/dev/null && have_sbx=1
# The settings' temp dir holds $WORK itself here, so a scratch dir stands in for it.
tmp="$WORK/scratch"; mkdir -p "$tmp"
# profile <settings> <project>: the settings' denyRead, write limits and denyWrite as a
# seatbelt profile (a later rule wins). allowRead is left out on purpose: the denies alone
# must not cover the targets.
profile() {
  printf '(version 1)\n(allow default)\n'
  jq -r '.sandbox.filesystem.denyRead[] | "(deny file-read* (subpath \(tojson)))"' <<<"$1"
  printf '(deny file-write*)\n(allow file-write* (subpath "%s") (subpath "%s") (subpath "/dev"))\n' "$2" "$tmp"
  jq -r '.sandbox.filesystem.denyWrite[] | "(deny file-write* (subpath \(tojson)))"' <<<"$1"
}
run_in() { # run_in <settings> <project> <command...>
  local s="$1" p="$2"; shift 2
  env $(jq -r '.env | to_entries[] | "\(.key)=\(.value)"' <<<"$s") sandbox-exec -p "$(profile "$s" "$p")" "$@"
}
if [ "$have_sbx" = 0 ]; then
  echo "  skip sandbox-exec not available"
else
  run_in "$S" "$P" cat "$P/harness.db" >/dev/null 2>&1 || die "cat through the harness.db symlink"
  run_in "$S" "$P" cat "$P/lean/risk-questions/backend.md" >/dev/null 2>&1 || die "cat lean/risk-questions/backend.md"
  run_in "$S" "$P" ls "$P/migrations" >/dev/null 2>&1 || die "ls migrations/"
  run_in "$S" "$P" cat "$P/excl/s.txt" >/dev/null 2>&1 || die "cat through an excluded link"
  run_in "$S" "$P" cat "$P/tracked/t.txt" >/dev/null 2>&1 || die "cat through a committed link"
  run_in "$S" "$P" cat "$P/planted/secret.txt" >/dev/null 2>&1 && die "an untracked link must not be readable"
  printf 'b\n' >> "$P/src/a.txt"
  out=$(run_in "$S" "$P" git -C "$P" status --short 2>&1) && grep -q 'src/a.txt' <<<"$out" || die "git status in the worktree: $out"
  out=$(run_in "$S" "$P" git -C "$P" diff 2>&1) && grep -q '^+b' <<<"$out" || die "git diff in the worktree: $out"
  run_in "$S" "$P" cat "$DEV/other/secret.txt" >/dev/null 2>&1 && die "a sibling project must stay unreadable"
  run_in "$S" "$P" cat "$P/frozen/x.sha" >/dev/null 2>&1 && die "the frozen manifest must stay unreadable through a symlink"
  run_in "$S" "$P" cat "$MAIN/backend/unlinked.txt" >/dev/null 2>&1 && die "the main worktree's other files must stay unreadable"
  run_in "$S" "$P" sh -c "echo x >> '$P/harness.db'" 2>/dev/null && die "writing through a symlink must fail"
  # The harness-owned links of the worktree can't be removed or replaced (denyWrite by name).
  run_in "$S" "$P" rm "$P/lean" 2>/dev/null && die "removing the lean/ link must be denied"
  run_in "$S" "$P" ln -sfn "$DEV/other" "$P/lean" 2>/dev/null && die "re-pointing the lean/ link must be denied"
  run_in "$S" "$P" mv "$P/harness.db" "$P/h.db" 2>/dev/null && die "moving the harness.db link must be denied"
  [ "$(readlink "$P/lean")" = "$MAIN/backend/lean" ] && [ -L "$P/harness.db" ] || die "the worktree's harness links changed"
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
# A commit since the base: the committed work would escape the checks.
base3=$(git -C "$G" rev-parse HEAD)
g -C "$G" commit -q --allow-empty -m moved || die "empty commit"
out=$(gate --base "$base3") && die "a moved HEAD must fail: $out"
grep -q "HEAD MOVED: HEAD is .*base commit is $base3" <<<"$out" || die "moved HEAD message: $out"
out=$(gate) || die "with the default base (HEAD) the gate passes: $out"
g -C "$G" reset -q --soft "$base3"
out=$(gate --base "$base3") || die "back on the base, the gate passes: $out"
pass "gate: HEAD moved off the base commit fails with a clear message"

# diff.relative=true in the user's git config changes nothing.
printf '[diff]\n\trelative = true\n' > "$WORK/relative.gitconfig"
rgate() { GIT_CONFIG_GLOBAL="$WORK/relative.gitconfig" gate "$@"; }
[ "$(GIT_CONFIG_GLOBAL="$WORK/relative.gitconfig" git -C "$B" config diff.relative)" = true ] || die "diff.relative not set"
out=$(rgate) || die "diff.relative: a listed change should pass: $out"
fdoc src/a.txt tests/app_test.sh
out=$(rgate) && die "diff.relative: unlisted file and removed assertion must fail"
grep -qx 'src/b.txt' <<<"$out" && grep -q 'ASSERTION LINES REMOVED FROM tests/app_test.sh' <<<"$out" \
  || die "diff.relative: unlisted file / removed assertion: $out"
grep -q 'CHANGED OUTSIDE' <<<"$out" && die "diff.relative: project files reported outside: $out"
fdoc src/a.txt src/b.txt tests/app_test.sh -- tests/app_test.sh
printf 'z3\n' >> "$G/outside.txt"
out=$(rgate) && die "diff.relative: a change outside the project must fail"
grep -qx 'outside.txt' <<<"$out" || die "diff.relative: the outside change should be named from the root: $out"
g -C "$G" checkout -q -- outside.txt
pass "gate: diff.relative=true in the user's config gives the same results"

for spelling in "" "$PX"; do
  (cd "$B" && shasum -a 256 acceptance/f.test.sh) | sed "s|  acceptance/|  ${spelling}acceptance/|" > "$WORK/f.sha"
  out=$(gate --frozen "$WORK/f.sha") || die "frozen manifest spelled '${spelling}acceptance/' should pass: $out"
done
printf 'changed\n' > "$B/acceptance/f.test.sh"
out=$(gate --frozen "$WORK/f.sha") && die "a changed frozen file must fail"
grep -q 'FROZEN ACCEPTANCE TESTS CHANGED' <<<"$out" || die "frozen change: $out"
pass "gate: the frozen manifest is read relative to the project in both spellings; a changed frozen file fails"

echo "4. run.sh; the git state is read-only"
# A root-level repository: .git is inside the project. lean/run.sh with a fake claude that
# keeps the --settings it gets.
R2="$DEV/rootp"
mkdir -p "$R2/src" "$R2/docs/features" "$WORK/bin"
printf 'a\n' > "$R2/src/a.txt"; printf '# f\n' > "$R2/docs/features/f.md"
echo '{"lean":{"implementer":"claude"}}' > "$R2/.harness.json"
g -C "$R2" init -q && g -C "$R2" add -A && g -C "$R2" commit -qm base || die "root repo setup"
ln -s "$DEV/shared" "$R2/excl" && printf '/excl\n' >> "$R2/.git/info/exclude"
ln -s "$DEV/other" "$R2/stray"
cat > "$WORK/bin/claude" <<SH
#!/usr/bin/env bash
env > "$WORK/claude.env"
while [ \$# -gt 0 ]; do [ "\$1" = --settings ] && printf '%s' "\$2" > "$WORK/settings.json"; shift; done
echo '{}'
SH
chmod +x "$WORK/bin/claude"
step() { (cd "$R2" && PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/run.sh" implement f --headless) 2>"$WORK/run.err"; }
allows() { jq -r '.sandbox.filesystem.allowRead[]' <<<"$1" | grep -qxF "$2"; }
state_of() { bash -c '. "$1/lean/lib.sh"; lean_state_dir "$2"' _ "$TOOLKIT_DIR" "$1"; }
step || die "lean/run.sh implement: $(cat "$WORK/run.err")"
S4=$(cat "$WORK/settings.json")
allows "$S4" "$DEV/shared" || die "an excluded link should be readable: $S4"
allows "$S4" "$DEV/other" && die "an untracked, not ignored link must not be readable: $S4"
grep -q "$R2/stray .*neither tracks nor ignores" "$WORK/run.err" || die "the untracked link should be named: $(cat "$WORK/run.err")"
[ "$have_sbx" = 0 ] || run_in "$S4" "$R2" cat "$R2/excl/s.txt" >/dev/null 2>&1 || die "sandboxed: the excluded link should read"
[ "$have_sbx" = 0 ] || ! run_in "$S4" "$R2" cat "$R2/stray/secret.txt" >/dev/null 2>&1 || die "sandboxed: the untracked link must not read"
rm "$R2/stray"
jq -r '.sandbox.filesystem.denyWrite[]' <<<"$S4" | grep -qxF "$R2/.git" || die "denyWrite should hold the project's .git: $(jq -c .sandbox.filesystem <<<"$S4")"
jq -r '.permissions.deny[]' <<<"$S4" | grep -qxF "Edit(/$R2/.git/**)" || die "the project's .git should get an Edit deny rule"
jq -r '.sandbox.filesystem.denyWrite[]' <<<"$S2" | grep -qxF "$Q/.git" || die "a subfolder project's .git (absent) should be write-denied"
pass "run.sh: known links read, untracked ones don't; the git state is write-denied"

if [ "$have_sbx" = 1 ]; then
  head2=$(git -C "$R2" rev-parse HEAD)
  printf 'c\n' >> "$R2/src/a.txt"
  out=$(run_in "$S4" "$R2" git -C "$R2" status --short 2>&1) && grep -q 'src/a.txt' <<<"$out" || die "sandboxed git status: $out"
  out=$(run_in "$S4" "$R2" git -C "$R2" diff 2>&1) && grep -q '^+c' <<<"$out" || die "sandboxed git diff: $out"
  run_in "$S4" "$R2" git -C "$R2" log --oneline -1 >/dev/null 2>&1 || die "sandboxed git log"
  run_in "$S4" "$R2" git -C "$R2" show --stat HEAD >/dev/null 2>&1 || die "sandboxed git show"
  run_in "$S4" "$R2" git -C "$R2" -c user.email=t@t -c user.name=t commit -qam x >/dev/null 2>&1 && die "git commit must be denied"
  run_in "$S4" "$R2" git -C "$R2" add src/a.txt >/dev/null 2>&1 && die "git add must be denied"
  [ "$(git -C "$R2" rev-parse HEAD)" = "$head2" ] || die "HEAD must not move"
  run_in "$S4" "$R2" sh -c "echo '/x' >> '$R2/.git/info/exclude'" 2>/dev/null && die "writing .git/info/exclude must be denied"
  grep -qx '/x' "$R2/.git/info/exclude" && die ".git/info/exclude was written"
  run_in "$S2" "$Q" git -C "$Q" init -q >/dev/null 2>&1 && die "the project's missing .git must not be created"
  [ ! -e "$Q/.git" ] || die "$Q/.git was created"
  g -C "$R2" checkout -q -- src/a.txt
  pass "sandboxed: git commit/add, info/exclude writes and git init in the project are denied; status/diff/log/show work"
fi

echo "5. the lean state is keyed by the project's path; trusted files are pinned"
# A root-level risk-mode project with the harness-owned files a session must not touch.
R3="$DEV/keyp"
mkdir -p "$R3/src" "$R3/docs/features" "$R3/acceptance" "$R3/scripts" "$R3/.claude"
printf '# f\n' > "$R3/docs/features/f.md"; printf 'a\n' > "$R3/src/a.txt"; printf 't\n' > "$R3/acceptance/f.test.sh"
cp -R "$TOOLKIT_DIR/lean" "$R3/lean"; printf '#!/bin/sh\nexit 0\n' > "$R3/scripts/harness.sh"
printf 'db\n' > "$R3/harness.db"; printf '#!/bin/sh\n' > "$R3/init.sh"; printf '# a\n' > "$R3/AGENTS.md"; echo '{}' > "$R3/.claude/settings.json"
echo '{"project_slug":"k1","verify_command":"true","lean":{"implementer":"claude"}}' > "$R3/.harness.json"
g -C "$R3" init -q && g -C "$R3" add -A && g -C "$R3" commit -qm base || die "keyp setup"
ln -s "$DEV/shared" "$R3/excl" && printf '/excl\n' >> "$R3/.git/info/exclude"
step3() { (cd "$R3" && PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/run.sh" "$1" f --headless) 2>"$WORK/run3.err"; }
ST3=$(state_of "$R3")
step3 freeze || die "run.sh freeze: $(cat "$WORK/run3.err")"
[ -f "$ST3/frozen/f.sha" ] && [ -f "$ST3/lean/f/trusted.sha" ] || die "freeze should pin into $ST3: $(ls -R "$ST3")"
grep -q '  lean/sandbox.sh$' "$ST3/lean/f/trusted.sha" && grep -q '  .harness.json$' "$ST3/lean/f/trusted.sha" \
  && grep -q '  scripts/harness.sh$' "$ST3/lean/f/trusted.sha" || die "trusted hashes: $(cat "$ST3/lean/f/trusted.sha")"
step3 implement || die "implement: $(cat "$WORK/run3.err")"
grep -q 'Frozen acceptance tests' "$ST3/lean/f.system.md" || die "the feature should be in risk mode"
# A slug change between steps (sessions can't write .harness.json; the user can).
jq '.project_slug = "k2"' "$R3/.harness.json" > "$WORK/h.json" && mv "$WORK/h.json" "$R3/.harness.json"
step3 implement && die "a step after a trusted file changed must be refused"
grep -q 'harness-owned files changed' "$WORK/run3.err" && grep -q '^  .harness.json$' "$WORK/run3.err" \
  || die "the refusal should name .harness.json: $(cat "$WORK/run3.err")"
rm "$ST3/lean/f/trusted.sha"   # the human accepts the edit
step3 implement || die "implement after re-pinning the hashes: $(cat "$WORK/run3.err")"
grep -q 'Frozen acceptance tests' "$ST3/lean/f.system.md" || die "a slug change must not drop risk mode"
[ ! -e "$HOME/.cache/harness/k2" ] && [ ! -e "$HOME/.cache/harness/k1" ] || die "nothing is kept under the slug"
jq '.project_slug = "k1"' "$R3/.harness.json" > "$WORK/h.json" && mv "$WORK/h.json" "$R3/.harness.json"
rm "$ST3/lean/f/trusted.sha"; step3 implement || die "re-pin"
pass "a slug change is refused as a trusted-file change, and after it doesn't drop risk mode"

# Any file under lean/ or scripts/ changed: the next step refuses.
printf '# x\n' >> "$R3/lean/sandbox.sh"
step3 implement && die "a changed lean/sandbox.sh must stop the next step"
grep -q '^  lean/sandbox.sh$' "$WORK/run3.err" || die "the refusal should name lean/sandbox.sh: $(cat "$WORK/run3.err")"
cp "$TOOLKIT_DIR/lean/sandbox.sh" "$R3/lean/sandbox.sh"
step3 implement || die "restored lean/sandbox.sh: $(cat "$WORK/run3.err")"
# Legacy state under the slug is adopted once, so a feature frozen before keeps its risk mode.
R5="$DEV/legacyp"; mkdir -p "$R5/docs/features" "$HOME/.cache/harness/lg/frozen"
printf '# f\n' > "$R5/docs/features/f.md"; echo '{"project_slug":"lg","lean":{"implementer":"claude"}}' > "$R5/.harness.json"
printf 'abc  acceptance/f.test.sh\n' > "$HOME/.cache/harness/lg/frozen/f.sha"
g -C "$R5" init -q && g -C "$R5" add -A && g -C "$R5" commit -qm base || die "legacy setup"
(cd "$R5" && PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/run.sh" implement f --headless) 2>"$WORK/run5.err" || die "legacy: $(cat "$WORK/run5.err")"
[ -f "$(state_of "$R5")/frozen/f.sha" ] && grep -q 'Frozen acceptance tests' "$(state_of "$R5")/lean/f.system.md" \
  || die "legacy frozen manifests should be adopted: $(cat "$WORK/run5.err")"
pass "a changed lean/ file stops the next step; state kept under the slug is adopted once"

echo "6. sessions can't write what the next step runs or trusts"
step3 implement || die "implement: $(cat "$WORK/run3.err")"; S6=$(cat "$WORK/settings.json")
rules6=$(jq -r '.permissions.deny[]' <<<"$S6")
for p in lean scripts .harness.json harness.db init.sh .claude .codex AGENTS.md CLAUDE.md .mcp.json harness; do
  jq -r '.sandbox.filesystem.denyWrite[]' <<<"$S6" | grep -qxF "$R3/$p" || die "denyWrite should hold $R3/$p"
  grep -qxF "Edit(/$R3/$p)" <<<"$rules6" && grep -qxF "Edit(/$R3/$p/**)" <<<"$rules6" || die "Edit deny rules for $p"
done
if [ "$have_sbx" = 1 ]; then
  for cmd in "echo x >> lean/sandbox.sh" "rm -rf lean" "mv lean lean2" "echo '{}' > .harness.json" "rm .harness.json" \
             "echo x >> scripts/harness.sh" "rm -rf scripts" "echo x > harness.db" "echo x > harness.db-journal" \
             "echo '{}' > .claude/settings.local.json" "echo '{}' > .mcp.json" "echo x >> init.sh" "echo x > CLAUDE.md" \
             "mkdir .codex" "ln -s ../other harness"; do
    run_in "$S6" "$R3" sh -c "cd '$R3' && $cmd" 2>/dev/null && die "sandboxed: '$cmd' must be denied"
  done
  [ ! -e "$R3/.mcp.json" ] && [ ! -e "$R3/.codex" ] && [ ! -e "$R3/CLAUDE.md" ] && [ ! -e "$R3/harness" ] && [ -d "$R3/lean" ] || die "a denied write happened"
  step3 implement || die "nothing trusted changed, the next step runs: $(cat "$WORK/run3.err")"
  run_in "$S6" "$R3" sh -c "cd '$R3' && echo b >> src/a.txt && echo n > src/new.txt && mkdir -p src/m && echo m > src/m/m.txt" \
    || die "sandboxed: normal project files must stay writable"
  g -C "$R3" checkout -q -- src/a.txt && rm -r "$R3/src/new.txt" "$R3/src/m"
  pass "sandboxed: lean/, scripts/, .harness.json, the database, init.sh, .claude/, .codex/, AGENTS.md, CLAUDE.md, .mcp.json are write-denied; project files are not"
fi

echo "7. \$HOME is denied by default"
# Credentials, including the ones inside allowed toolchain folders, and files that must stay
# private; then what toolchains need.
histories=".zsh_history .zsh_sessions/s.history .bash_history .python_history .node_repl_history .psql_history
  .sqlite_history .mysql_history .lesshst .irb_history"
secret_files=".config/gh/hosts.yml .netrc .docker/config.json .kube/config .gnupg/k Library/Keychains/k work/otherproj/x
  .local/share/fish/fish_history .local/share/atuin/history.db .local/share/tool/t .zshrc .ssh/id
  .cargo/credentials .cargo/credentials.toml .gradle/gradle.properties .m2/settings.xml .m2/settings-security.xml
  .m2/settings-work.xml .gem/credentials .npmrc .yarnrc .yarnrc.yml .pypirc .config/git/credentials .config/git/config
  .gitconfig extra/lib/.ssh-like/../../../.ssh/id .claude/shell-snapshots/snapshot-zsh.sh .claude/settings.json
  .local/share/uv/credentials/credentials.toml $histories"
open_files=".cargo/registry/r .gradle/caches/c .m2/repository/r .gem/specs/s .local/share/mise/m .local/share/pnpm/p extra/lib/e
  .local/share/uv/python/p"
# (Content git can parse: ~/.gitconfig and ~/.config/git/config are read by the test's own git.)
for f in $secret_files $open_files; do mkdir -p "$(dirname "$HOME/$f")" && printf '[s]\n' > "$HOME/$f"; done
ln -s .ssh "$HOME/sshlink"
R4="$DEV/homep"; mkdir -p "$R4/src"; printf 'a\n' > "$R4/src/a.txt"
echo '{"lean":{"allowed_read":["~/extra/lib","~/.ssh","~/.local/share/fish/fish_history","~/.cache/../.ssh","~/sshlink","~/.cargo/../.gradle"]}}' > "$R4/.harness.json"
# Shell and REPL histories are hard-protected: refused in lean.allowed_read too.
hist_allow=$(for f in $histories; do printf '~/%s\n' "${f%%/*}"; done | jq -R . | jq -sc .)
jq --argjson h "$hist_allow" '.lean.allowed_read += $h' "$R4/.harness.json" > "$WORK/h4.json" && mv "$WORK/h4.json" "$R4/.harness.json"
S7=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$R4" 2>"$WORK/home.err") || die "sandbox.sh: $(cat "$WORK/home.err")"
SB7=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$R4" --seatbelt 2>/dev/null) || die "sandbox.sh --seatbelt"
allows "$S7" "$HOME/extra/lib" && allows "$S7" "$HOME/.local/share/mise" || die "allowRead: $(jq -c .sandbox.filesystem.allowRead <<<"$S7")"
allows "$S7" "$HOME/.local/share" && die "~/.local/share must not be allowed whole"
jq -r '.sandbox.filesystem.allowRead[]' <<<"$S7" | grep -q '\.ssh' && die "no form of ~/.ssh may be in allowRead: $(jq -c .sandbox.filesystem.allowRead <<<"$S7")"
grep -qF "$HOME/.ssh stays unreadable" "$WORK/home.err" && grep -q "fish_history stays unreadable" "$WORK/home.err" \
  && grep -qF "$HOME/sshlink (-> $HOME/.ssh) stays unreadable" "$WORK/home.err" || die "refused allowed_read entries should be named: $(cat "$WORK/home.err")"
for f in $histories; do
  grep -qF "$HOME/${f%%/*} stays unreadable" "$WORK/home.err" || die "lean.allowed_read must refuse ~/${f%%/*}: $(cat "$WORK/home.err")"
  jq -r '.sandbox.filesystem.allowRead[]' <<<"$S7" | grep -qF "$HOME/${f%%/*}" && die "~/${f%%/*} must not be in allowRead"
done
grep -qF "$HOME/.cache/" "$WORK/home.err" && die "~/.cache/../.ssh should be named normalised: $(cat "$WORK/home.err")"
# Settings: no allowRead entry holds a denyRead one in \$HOME (Claude Code lets allowRead win).
deny7=$(jq -r '.sandbox.filesystem.denyRead[]' <<<"$S7")
for d in "$HOME/.cargo/credentials.toml" "$HOME/.gradle/gradle.properties" "$HOME/.m2/settings-work.xml" "$HOME/.gitconfig" "$HOME/.local/share/fish"; do
  grep -qxF "$d" <<<"$deny7" || die "denyRead should hold $d"
done
while IFS= read -r a; do
  while IFS= read -r d; do
    case "$d/" in "$a"/*) [ "$d" = "$a" ] || die "allowRead $a holds the denied $d" ;; esac
  done <<<"$deny7"
done < <(jq -r '.sandbox.filesystem.allowRead[]' <<<"$S7")
# Profile: each re-denied credential comes after the allow of the folder holding it.
last_line() { grep -nF "$1" <<<"$SB7" | tail -1 | cut -d: -f1; }
for pair in ".cargo/credentials.toml .cargo" ".gradle/gradle.properties .gradle" ".m2/settings.xml .m2"; do
  set -- $pair
  dl=$(last_line "(deny file-read* (subpath \"$HOME/$1\"))"); al=$(last_line "(allow file-read* (subpath \"$HOME/$2\"))")
  [ -n "$dl" ] && [ -n "$al" ] && [ "$dl" -gt "$al" ] || die "the re-deny of ~/$1 must follow the allow of ~/$2 (deny line '$dl', allow line '$al')"
done
# sb <project> <command...> — under the real profile (sandbox.sh --seatbelt), as the gate runs.
sb() { local p="$1"; shift; (cd "$p" && sandbox-exec -p "$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$p" --seatbelt 2>/dev/null)" "$@"); }
if [ "$have_sbx" = 1 ]; then
  for f in $secret_files sshlink/id .cache/../.ssh/id; do
    sb "$R4" cat "$HOME/$f" >/dev/null 2>&1 && die "sandboxed (--seatbelt): ~/$f must be unreadable"
  done
  for f in $open_files; do
    sb "$R4" cat "$HOME/$f" >/dev/null 2>&1 || die "sandboxed (--seatbelt): ~/$f should be readable"
  done
  sb "$R4" cat "$R4/src/a.txt" >/dev/null 2>&1 || die "sandboxed: the project should be readable"
  pass "sandboxed (--seatbelt): \$HOME is denied but for toolchains, lean.allowed_read and the project; credentials stay denied inside allowed folders and through .. or links"
  [ ! -d /Volumes ] || ! sb "$R4" ls /Volumes >/dev/null 2>&1 || die "sandboxed: /Volumes must be unreadable"
  UC=$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null)
  [ -z "$UC" ] || [ ! -d "$UC" ] || ! sb "$R4" ls "$UC" >/dev/null 2>&1 || die "sandboxed: the per-user cache dir must be unreadable"
fi
# Claude Code's temp folder, a fake one (LEAN_CLAUDE_TMP): the entry named after the project
# (shared by every Claude Code session run from it, the leader's scratchpad included) and
# another one. The settings re-open the project's entry for the session; the gate's profile
# denies both, reading and writing.
CT="$WORK/claude-tmp"; CTS="$CT/$(printf '%s' "$R4" | sed 's/[^a-zA-Z0-9]/-/g')"
mkdir -p "$CTS/leader/scratchpad" "$CT/other-project/s"
printf 'echo leader\n' > "$CTS/leader/scratchpad/run.sh"; printf 's\n' > "$CT/other-project/s/x.txt"
S7c=$(LEAN_CLAUDE_TMP="$CT" bash "$TOOLKIT_DIR/lean/sandbox.sh" "$R4" 2>/dev/null)
jq -r '.sandbox.filesystem.denyRead[]' <<<"$S7c" | grep -qxF "$CT" || die "settings: denyRead should hold the Claude Code temp folder"
allows "$S7c" "$CTS" || die "settings: the session's own entry should be re-opened: $(jq -c .sandbox.filesystem.allowRead <<<"$S7c")"
SB7c=$(LEAN_CLAUDE_TMP="$CT" bash "$TOOLKIT_DIR/lean/sandbox.sh" "$R4" --seatbelt 2>/dev/null)
grep -qF "\"$CTS\"" <<<"$SB7c" && die "the gate's profile must not name the project's entry (no allow): $(grep -F "$CTS" <<<"$SB7c")"
if [ "$have_sbx" = 1 ]; then
  sbc() { (cd "$R4" && sandbox-exec -p "$SB7c" "$@"); }
  for f in "$CTS/leader/scratchpad/run.sh" "$CT/other-project/s/x.txt"; do
    sbc cat "$f" >/dev/null 2>&1 && die "sandboxed (--seatbelt): $f must be unreadable"
    sbc sh -c "echo 'echo PWNED' >> '$f'" 2>/dev/null && die "sandboxed (--seatbelt): $f must be unwritable"
  done
  sbc sh -c "echo x > '$CTS/new.txt'" 2>/dev/null && die "sandboxed (--seatbelt): no file may be created in the project's entry"
  [ "$(cat "$CTS/leader/scratchpad/run.sh")" = "echo leader" ] && [ ! -e "$CTS/new.txt" ] || die "a denied write to the Claude Code temp folder happened"
  pass "sandboxed (--seatbelt): /Volumes and Claude Code's temp folder (the project's own entry, the leader's scratchpad, included) are denied"
fi

echo "8. the gate runs the suite in the sandbox"
setv() { jq --arg v "$1" '.verify_command = $v' "$R3/.harness.json" > "$WORK/h.json" && mv "$WORK/h.json" "$R3/.harness.json"; }
gate3() { bash "$TOOLKIT_DIR/lean/gate.sh" "$R3" f "$@" 2>&1; }
printf '# f\n\n**Files**\n- `.harness.json`: the verify_command each case sets\n' > "$R3/docs/features/f.md"; g -C "$R3" add -A && g -C "$R3" commit -qm doc || die "doc"
if [ "$have_sbx" = 1 ]; then
  setv "cat '$HOME/.ssh/id'"
  out=$(gate3) && die "the suite must not read ~/.ssh in the gate: $out"
  grep -q 'SUITE FAILS' <<<"$out" || die "gate: $out"
  out=$(LEAN_GATE_UNSANDBOXED=1 gate3) || die "LEAN_GATE_UNSANDBOXED=1 runs it unsandboxed: $out"
  grep -q '^\[WARN\] the suite and the acceptance tests run UNSANDBOXED' <<<"$out" || die "the unsandboxed run must say so: $out"
  setv "cat '$HOME/.cargo/registry/r' excl/s.txt"
  out=$(gate3) || die "toolchains and excluded links are readable in the gate: $out"
  grep -q 'WARN' <<<"$out" && die "no warning when sandboxed: $out"
  setv "echo /x >> .git/info/exclude"
  out=$(gate3) && die "the suite must not write the git state: $out"
  grep -qx '/x' "$R3/.git/info/exclude" && die ".git/info/exclude was written by the suite"
  setv "echo x >> scripts/harness.sh"
  out=$(gate3) && die "the suite must not write scripts/: $out"
  (cd "$R3" && ln -s ../other planted2)
  setv "cat planted2/secret.txt"
  out=$(gate3) && die "an untracked, not ignored link must stay unreadable in the gate: $out"
  grep -q 'SUITE FAILS' <<<"$out" || die "the suite itself should fail on the untracked link: $out"
  rm "$R3/planted2"
  setv "true"
  pass "the gate runs the suite under the sessions' rules (no ~/.ssh, no git or harness writes, known links only); LEAN_GATE_UNSANDBOXED=1 warns"
else
  setv "true"
  out=$(gate3); grep -q '^\[WARN\] the suite and the acceptance tests run UNSANDBOXED' <<<"$out" || die "without sandbox-exec the gate must warn: $out"
  pass "without sandbox-exec the gate warns that the suite runs unsandboxed"
fi

echo "9. unix sockets, the gate's environment and process group, warnings, CLAUDE.local.md"
# A unix-socket client and server (paths relative to their folder: sockets have a short limit).
cat > "$WORK/sock.py" <<'PY'
import os, socket, sys, time
d, n = os.path.split(sys.argv[2]); os.chdir(d or ".")
s = socket.socket(socket.AF_UNIX)
if sys.argv[1] == "serve":
    s.bind(n); s.listen(5); time.sleep(120)
else:
    try: s.connect(n)
    except OSError: sys.exit(1)
PY
SERVERS=()
serve() { python3 -I "$WORK/sock.py" serve "$1" & SERVERS+=($!); local i=0; while [ ! -S "$1" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; [ -S "$1" ] || die "no socket $1"; }
reach() { python3 -I "$WORK/sock.py" connect "$1"; }
AGENT_DIR="$WORK/agent"; mkdir -p "$AGENT_DIR"   # an ssh-agent stand-in (SSH_AUTH_SOCK)
PGSOCK="$LEAN_DB_SOCK_DIR/.s.PGSQL.5432"
cleanup9() { kill ${SERVERS[@]+"${SERVERS[@]}"} 2>/dev/null; rm -f "$PGSOCK"; }
trap 'cleanup9; chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
# Docker stand-ins: Docker Desktop's socket in $HOME, and one outside it where only the socket
# rule can stop a connection (the real /var/run/docker.sock is only ever connected to below,
# from inside the profile, where that must fail).
mkdir -p "$HOME/.docker/run" "$WORK/var/run" "$R3/run"
serve "$HOME/.docker/run/docker.sock"; serve "$WORK/var/run/docker.sock"; serve "$AGENT_DIR/Listeners"; serve "$PGSOCK"; serve "$R3/run/app.sock"
for k in "$HOME/.docker/run/docker.sock" "$WORK/var/run/docker.sock" "$AGENT_DIR/Listeners" "$PGSOCK" "$R3/run/app.sock"; do reach "$k" || die "unsandboxed, $k should answer"; done
S9=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$R3" 2>/dev/null)
[ "$(jq -c '.sandbox.network.allowAllUnixSockets' <<<"$S9")" = false ] || die "settings: allowAllUnixSockets must be false"
socks9=$(jq -r '.sandbox.network.allowUnixSockets[]' <<<"$S9")
grep -qxF "$R3" <<<"$socks9" && grep -qxF "$PGSOCK" <<<"$socks9" || die "settings: the project and the database socket should be allowed: $socks9"
grep -q 'docker\|launchd' <<<"$socks9" && die "settings: no Docker or agent socket may be allowed: $socks9"
if [ "$have_sbx" = 1 ]; then
  export SSH_AUTH_SOCK="$AGENT_DIR/Listeners"
  sb "$R3" python3 -I "$WORK/sock.py" connect "$HOME/.docker/run/docker.sock" && die "sandboxed: a Docker socket in \$HOME must be unreachable"
  sb "$R3" python3 -I "$WORK/sock.py" connect "$WORK/var/run/docker.sock" && die "sandboxed: a Docker-like socket outside \$HOME must be unreachable"
  sb "$R3" python3 -I "$WORK/sock.py" connect /var/run/docker.sock && die "sandboxed: /var/run/docker.sock must be unreachable"
  sb "$R3" python3 -I "$WORK/sock.py" connect "$SSH_AUTH_SOCK" && die "sandboxed: the ssh-agent socket must be unreachable"
  sb "$R3" python3 -I "$WORK/sock.py" connect "$PGSOCK" || die "sandboxed: a database socket in /private/tmp should answer"
  sb "$R3" python3 -I "$WORK/sock.py" connect "$R3/run/app.sock" || die "sandboxed: a socket in the project should answer"
  # The default folder for database sockets is /private/tmp (checked on the profile, nothing bound there).
  grep -qF '(regex #"^/private/tmp/(' <<<"$(env -u LEAN_DB_SOCK_DIR bash "$TOOLKIT_DIR/lean/sandbox.sh" "$R3" --seatbelt 2>/dev/null)" || die "the profile should match database sockets in /private/tmp by default"
  pass "sandboxed (--seatbelt): Docker and ssh-agent sockets are unreachable; database sockets and the project's are reachable"
fi
cleanup9; SERVERS=(); rm -r "$R3/run"
# The gate's environment: no SSH_AUTH_SOCK, no secret-looking variable unless passed through,
# no global git config; in both sandboxed and unsandboxed runs.
jq '.lean.env_passthrough = ["KEEP_TOKEN"]' "$R3/.harness.json" > "$WORK/h.json" && mv "$WORK/h.json" "$R3/.harness.json"
setv '[ -z "${SSH_AUTH_SOCK:-}" ] && [ -z "${FAKE_TOKEN:-}${DB_PASSWORD:-}${DATABASE_URL:-}" ] && [ "$KEEP_TOKEN" = k ] && [ "$GIT_CONFIG_GLOBAL" = /dev/null ] && [ "$PLAIN" = p ]'
for un in 0 1; do
  out=$(SSH_AUTH_SOCK=/x FAKE_TOKEN=t DB_PASSWORD=p DATABASE_URL=u KEEP_TOKEN=k PLAIN=p LEAN_GATE_UNSANDBOXED=$un gate3) \
    || die "the gate's environment (LEAN_GATE_UNSANDBOXED=$un): $out"
done
# The session starts without them too, but for Claude Code's own ANTHROPIC_* / CLAUDE_*.
rm -f "$ST3/lean/f/trusted.sha"   # the .harness.json edit above is the human's: pin again
FAKE_TOKEN=t DATABASE_URL=u ANTHROPIC_API_KEY=a KEEP_TOKEN=k SSH_AUTH_SOCK=/x step3 implement || die "implement: $(cat "$WORK/run3.err")"
grep -qE '^(FAKE_TOKEN|DATABASE_URL|SSH_AUTH_SOCK)=' "$WORK/claude.env" && die "the session must start without secret-looking variables: $(grep -E 'TOKEN|URL|SOCK' "$WORK/claude.env")"
grep -qx 'ANTHROPIC_API_KEY=a' "$WORK/claude.env" && grep -qx 'KEEP_TOKEN=k' "$WORK/claude.env" || die "the session keeps ANTHROPIC_* and lean.env_passthrough"
# The suite's leftovers are killed when it ends.
rm -f "$R3/late.txt"
setv '(sleep 2; echo late > late.txt) >/dev/null 2>&1 & echo started'
out=$(gate3) || die "a suite leaving a background job passes (warned): $out"
grep -q '^\[WARN\] lean: processes the command started were still running when it ended' <<<"$out" || die "the gate should warn about the leftover: $out"
sleep 3; [ ! -e "$R3/late.txt" ] || die "a process the suite left running must be killed when it ends"
setv true
out=$(gate3) || die "a clean suite: $out"
grep -q 'WARN' <<<"$out" && die "no warning for a suite that leaves nothing running: $out"
pass "the gate's suite runs without SSH_AUTH_SOCK or secret-looking variables (lean.env_passthrough kept), without global git config; its leftovers are killed with a [WARN]"
# File descriptors the caller holds (above 2) don't reach the suite, sandboxed or not.
( { true >&9; } 2>/dev/null ) 9>"$WORK/held" || die "the control: fd 9 should be open in the caller"
setv '! { true >&9; } 2>/dev/null && ! { true <&4; } 2>/dev/null'
for un in 0 1; do
  out=$(LEAN_GATE_UNSANDBOXED=$un bash "$TOOLKIT_DIR/lean/gate.sh" "$R3" f 9>"$WORK/held" 4<"$WORK/held" 2>&1) || die "the suite must not inherit fds 4 and 9 (LEAN_GATE_UNSANDBOXED=$un): $out"
done
setv true
pass "file descriptors above 2 the caller holds are closed before the suite runs"
# The terminal: run from a terminal (a pty), a suite that ignores SIGTTOU and tries TIOCSTI on
# /dev/tty and on fds 0-2 pushes nothing into the shell that ran the gate, and the gate ends.
# Control: the same program run directly in the pty does inject (where TIOCSTI works at all;
# only into the test's own pty).
cat > "$WORK/drv.py" <<'PY'
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", sys.argv[1]])
out, end = b"", time.time() + float(sys.argv[2])
while time.time() < end:
    if select.select([fd], [], [], 0.5)[0]:
        try: d = os.read(fd, 4096)
        except OSError: break
        if not d: break
        out += d
    if os.waitpid(pid, os.WNOHANG)[0]: break
else:
    os.kill(pid, 9)
print(out.decode(errors="replace").replace("\r", ""))
PY
cat > "$WORK/sti.py" <<'PY'
import fcntl, os, signal, sys, termios
signal.signal(signal.SIGTTOU, signal.SIG_IGN); signal.signal(signal.SIGTTIN, signal.SIG_IGN)
fds = [i for i in (0, 1, 2)]
try: fds.insert(0, os.open("/dev/tty", os.O_RDWR))
except OSError: pass
for fd in fds:
    try:
        for ch in sys.argv[1].encode() + b"\n": fcntl.ioctl(fd, termios.TIOCSTI, bytes([ch]))
    except OSError: pass
PY
ctl=$(python3 -I "$WORK/drv.py" "python3 -I '$WORK/sti.py' 'echo LEAN_TTY_CONTROL'; read -t 2 l; echo \"outer read:[\$l]\"" 20)
if grep -qF 'outer read:[echo LEAN_TTY_CONTROL]' <<<"$ctl"; then
  cp "$WORK/sti.py" "$R3/sti.py"
  setv 'python3 -I sti.py "echo LEAN_TTY_ESCAPE"'
  for un in 0 1; do
    [ "$un" = 1 ] || [ "$have_sbx" = 1 ] || continue
    out=$(python3 -I "$WORK/drv.py" "LEAN_GATE_UNSANDBOXED=$un bash '$TOOLKIT_DIR/lean/gate.sh' '$R3' f >/dev/null 2>&1; echo gate-ended; read -t 2 l; echo \"outer read:[\$l]\"" 60)
    grep -q '^gate-ended' <<<"$out" || die "the gate did not end in a terminal (LEAN_GATE_UNSANDBOXED=$un): $out"
    grep -qF 'outer read:[]' <<<"$out" || die "the gate's suite pushed input into the caller's terminal (LEAN_GATE_UNSANDBOXED=$un): $out"
  done
  rm -f "$R3/sti.py"; setv true
  pass "a suite can't push input into the terminal the gate runs from (TIOCSTI, SIGTTOU ignored), sandboxed or not"
else
  echo "  skip TIOCSTI: it doesn't inject even unsandboxed here"
fi
if [ "$have_sbx" = 1 ]; then
  jq '.lean.allowed_domains = ["registry.npmjs.org"]' "$R3/.harness.json" > "$WORK/h.json" && mv "$WORK/h.json" "$R3/.harness.json"
  out=$(gate3) || die "gate with allowed_domains: $out"
  grep -q '^\[WARN\] lean/sandbox.sh --seatbelt: lean.allowed_domains is set' <<<"$out" || die "gate.sh must show sandbox.sh's [WARN]: $out"
  rm -f "$ST3/lean/f/trusted.sha"   # the .harness.json edits above are the human's: pin again
  out=$( (cd "$R3" && bash "$TOOLKIT_DIR/lean/run.sh" gate f) 2>&1) || die "run.sh gate with allowed_domains: $out"
  grep -q '^\[WARN\] lean/sandbox.sh --seatbelt: lean.allowed_domains is set' <<<"$out" || die "run.sh gate must show sandbox.sh's [WARN]: $out"
  jq 'del(.lean.allowed_domains)' "$R3/.harness.json" > "$WORK/h.json" && mv "$WORK/h.json" "$R3/.harness.json"
  rm -f "$ST3/lean/f/trusted.sha"
  pass "sandbox.sh's [WARN] about allowed_domains reaches the gate's report and run.sh gate"
fi
# CLAUDE.local.md: write-denied by name and trusted; nested CLAUDE.md / CLAUDE.local.md by regex.
jq -r '.sandbox.filesystem.denyWrite[]' <<<"$S9" | grep -qxF "$R3/CLAUDE.local.md" || die "denyWrite should hold CLAUDE.local.md"
rules9=$(jq -r '.permissions.deny[]' <<<"$S9")
for r in "Edit(/$R3/CLAUDE.local.md)" "Edit(/$R3/**/CLAUDE.md)" "Edit(/$R3/**/CLAUDE.local.md)"; do grep -qxF "$r" <<<"$rules9" || die "permissions.deny should hold $r"; done
printf 'x\n' > "$R3/CLAUDE.local.md"
bash -c '. "$1/lean/lib.sh"; lean_trusted_manifest "$2"' _ "$TOOLKIT_DIR" "$R3" | grep -q '  CLAUDE.local.md$' || die "CLAUDE.local.md should be a trusted file"
if [ "$have_sbx" = 1 ]; then
  mkdir -p "$R3/src/sub"
  for f in CLAUDE.local.md src/CLAUDE.md src/sub/CLAUDE.local.md src/sub/claude.MD; do
    sb "$R3" sh -c "echo y > '$R3/$f'" 2>/dev/null && die "sandboxed: writing $f must be denied"
  done
  sb "$R3" sh -c "echo y > '$R3/src/sub/notes.md'" || die "sandboxed: other .md files stay writable"
  [ "$(cat "$R3/CLAUDE.local.md")" = x ] && [ ! -e "$R3/src/CLAUDE.md" ] || die "a denied CLAUDE write happened"
  rm -r "$R3/src/sub"
  pass "sandboxed (--seatbelt): CLAUDE.local.md and nested CLAUDE.md / CLAUDE.local.md are write-denied; CLAUDE.local.md is trusted"
fi
rm -f "$R3/CLAUDE.local.md"

echo "10. the specific denies; the env scrub; the gate's scan; one run at a time"
if [ "$have_sbx" = 1 ]; then
  # Mach lookups through python ctypes (side-effect free: a lookup only gets a send right).
  cat > "$WORK/mach.py" <<'PY'
import ctypes, sys
lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
task, bp, p = ctypes.c_uint.in_dll(lib, "mach_task_self_").value, ctypes.c_uint.in_dll(lib, "bootstrap_port").value, ctypes.c_uint(0)
print(lib.bootstrap_look_up(bp, sys.argv[2].encode(), ctypes.byref(p)))
PY
  [ "$(python3 -I "$WORK/mach.py" look "lean.test.none.$$")" = 1102 ] || die "unsandboxed, looking up a missing mach name should answer 1102"
  # Processes outside the sandbox, from the profile itself and from mach lookups only: no
  # check runs open, osascript, pbpaste, defaults or launchctl beyond `help`, so a broken deny
  # can't launch an app, send an Apple Event or read or change any real state.
  PR=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$R3" --seatbelt 2>/dev/null)
  grep -qxF '(deny mach-lookup)' <<<"$PR" || die "the profile must deny mach lookups by default"
  [ "$(grep -c '^(allow mach-lookup' <<<"$PR")" = 1 ] || die "the profile must have one mach allow line: $(grep mach-lookup <<<"$PR")"
  [ "$(grep -n '^(deny mach-lookup)$' <<<"$PR" | cut -d: -f1)" -lt "$(grep -n '^(allow mach-lookup' <<<"$PR" | cut -d: -f1)" ] || die "the mach allow must follow the deny"
  mach_allow=$(sed -n '/^LEAN_MACH_ALLOW="/,/"$/p' "$TOOLKIT_DIR/lean/sandbox.sh" | sed 's/^LEAN_MACH_ALLOW="//; s/"$//' | tr -s ' \t' '\n\n' | sed '/^$/d')
  mach_never=$(sed -n "s/^LEAN_MACH_NEVER='\(.*\)'$/\1/p" "$TOOLKIT_DIR/lean/sandbox.sh")
  [ -n "$mach_allow" ] && [ -n "$mach_never" ] || die "LEAN_MACH_ALLOW / LEAN_MACH_NEVER not found in sandbox.sh"
  got_mach=$(grep '^(allow mach-lookup' <<<"$PR" | grep -oE '\(global-name "[^"]*"\)' | sed 's/^(global-name "//; s/")$//')
  [ -n "$got_mach" ] || die "the mach allow line should name services"
  while IFS= read -r m; do
    grep -qxF "$m" <<<"$mach_allow" || die "mach service $m is allowed but not in LEAN_MACH_ALLOW"
    grep -qE "$mach_never" <<<"$m" && die "mach service $m matches LEAN_MACH_NEVER"
  done <<<"$got_mach"
  for m in com.apple.coreservices.launchservicesd com.apple.lsd.mapdb com.apple.lsd.modifydb com.apple.lsd.open \
           com.apple.coreservices.appleevents com.apple.pasteboard.1; do
    grep -qE "$mach_never" <<<"$m" || die "$m should match LEAN_MACH_NEVER"
    [ "$(sb "$R3" python3 -I "$WORK/mach.py" look "$m")" = 1100 ] || die "sandboxed: the lookup of $m must be denied (1100)"
  done
  # launchctl: the profile denies running it, by path and by signing identifier (a link or a
  # copy). Only its `help` is tried, which reads and changes nothing even if the deny broke.
  grep -qF '(deny process-exec (literal "/bin/launchctl") (signing-identifier "com.apple.xpc.launchctl"))' <<<"$PR" || die "the profile must deny running launchctl"
  sb "$R3" /bin/ls "$R3" >/dev/null 2>&1 || die "sandboxed: running /bin/ls should work (the launchctl check means something)"
  sb "$R3" /bin/launchctl help >/dev/null 2>&1 && die "sandboxed: launchctl must not run"
  sb "$R3" sh -c 'ln -s /bin/launchctl "$1/lk" && "$1/lk" help >/dev/null 2>&1' _ "$R3" 2>/dev/null && { rm -f "$R3/lk"; die "sandboxed: launchctl through a link must not run"; }
  sb "$R3" sh -c 'cp /bin/launchctl "$1/lc" && "$1/lc" help >/dev/null 2>&1' _ "$R3" 2>/dev/null && { rm -f "$R3/lc"; die "sandboxed: a copy of launchctl must not run"; }
  rm -f "$R3/lk" "$R3/lc"
  # Signals: none to a process outside the sandbox; its own children still can be.
  sleep 60 & OUTSIDE=$!
  sb "$R3" kill -0 "$OUTSIDE" 2>/dev/null && { kill "$OUTSIDE"; die "sandboxed: kill -0 on an outside process must fail"; }
  sb "$R3" kill -TERM "$OUTSIDE" 2>/dev/null; kill -0 "$OUTSIDE" 2>/dev/null || die "sandboxed: an outside process was killed"
  kill "$OUTSIDE"; wait "$OUTSIDE" 2>/dev/null
  sb "$R3" sh -c 'sleep 30 & kill $!' 2>/dev/null || die "sandboxed: the command's own child should be killable"
  # Preferences, without reading or writing any: cfprefsd's agent can't be looked up inside
  # (1100; 0 outside).
  [ "$(python3 -I "$WORK/mach.py" look com.apple.cfprefsd.agent)" = 0 ] || die "unsandboxed, cfprefsd's agent should be found (the check means something)"
  [ "$(sb "$R3" python3 -I "$WORK/mach.py" look com.apple.cfprefsd.agent)" = 1100 ] || die "sandboxed: cfprefsd's agent must not be reachable (1100)"
  # Terminals, asked of the sandbox itself (sandbox_check: nothing is opened): no write or ioctl
  # on a terminal, while /dev/null and the project stay usable.
  cat > "$WORK/chk.py" <<'PY2'
import ctypes, os, sys
lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
c = lib.sandbox_check
c.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]; c.restype = ctypes.c_int
for a in sys.argv[1:]:   # <operation>=<path>: "<arg> <answer>"
    op, path = a.split("=", 1)
    print(a, c(os.getpid(), op.encode(), 1 | 0x40000000, ctypes.c_char_p(path.encode())))
PY2
  want="file-write-data=/dev/null 0
file-ioctl=/dev/null 0
file-write-data=$R3/src/a.txt 0
file-write-data=/dev/tty 1
file-ioctl=/dev/tty 1"
  for d in /dev/ttys*; do
    [ -e "$d" ] && want="$want
file-write-data=$d 1
file-ioctl=$d 1"
    break
  done
  got=$(sb "$R3" python3 -I "$WORK/chk.py" $(cut -d' ' -f1 <<<"$want"))
  [ "$got" = "$want" ] || die "sandboxed: terminals (1 = denied; /dev/null and the project allowed, so the check means something): $(diff <(echo "$want") <(echo "$got"))"
  # Toolchains still run under the profile (each where installed).
  sb "$R3" env GIT_CONFIG_GLOBAL=/dev/null git -C "$R3" status --short >/dev/null || die "sandboxed: git should run"
  sb "$R3" python3 -I -c 'import ssl, sqlite3, subprocess; subprocess.run(["true"], check=True)' || die "sandboxed: python3 should run"
  if command -v node >/dev/null 2>&1; then
    out=$(sb "$R3" node -e 'require("child_process").execSync("true"); require("os").userInfo()' 2>&1) || die "sandboxed: node should run: $(head -5 <<<"$out")"
  fi
  # The run's own TMPDIR is the only place it may write in the user temp dir (lean_sandboxed):
  # node and cargo test write there; next to it nothing can be written.
  lsb3() { bash -c '. "$1/lean/lib.sh"; lean_sandbox_prepare "$2" >/dev/null; lean_sandboxed "$2" "$3"' _ "$TOOLKIT_DIR" "$R3" "$1"; }
  UT=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null); UT="${UT%/}"
  if [ -n "$UT" ] && [ -d "$UT" ]; then
    lsb3 "echo x > '$UT/lean-test-$$'" 2>/dev/null && { rm -f "$UT/lean-test-$$"; die "sandboxed: the user temp dir must not be writable outside the run's TMPDIR"; }
    lsb3 'echo x > "$TMPDIR/ok" && [ -s "$TMPDIR/ok" ]' || die "sandboxed: the run's TMPDIR should be writable"
  fi
  if command -v node >/dev/null 2>&1; then
    out=$(lsb3 'node -e "require(\"fs\").writeFileSync(require(\"os\").tmpdir() + \"/n\", \"1\")"' 2>&1) || die "sandboxed: node should write in its TMPDIR: $(head -5 <<<"$out")"
  fi
  if command -v cargo >/dev/null 2>&1 && RUSTC_WRAPPER= cargo --version >/dev/null 2>&1; then
    mkdir -p "$WORK/crate/src"; printf '[package]\nname = "c"\nversion = "0.1.0"\nedition = "2021"\n' > "$WORK/crate/Cargo.toml"
    printf 'fn main() {}\n#[test]\nfn t() { assert_eq!(1, 1); }\n' > "$WORK/crate/src/main.rs"
    lsb3 "cp -R '$WORK/crate' \"\$TMPDIR/crate\" && cd \"\$TMPDIR/crate\" && cargo test --quiet --offline >/dev/null 2>&1" \
      || die "sandboxed: cargo test should run in the run's TMPDIR"
  fi
  # lean.allowed_mach adds a service; the ones that launch or drive processes stay out.
  grep -qF '"com.apple.cfprefsd.agent"' <<<"$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$R3" --seatbelt 2>/dev/null)" && die "cfprefsd's agent must not be on the mach allowlist"
  jq '.lean.allowed_mach = ["com.example.toolchain", "com.apple.coreservices.launchservicesd", "com.apple.pasteboard.1", "com.apple.cfprefsd.agent", "com.apple.coreservices.appleevents"]' "$R3/.harness.json" > "$WORK/h.json" && mv "$WORK/h.json" "$R3/.harness.json"
  P10=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$R3" --seatbelt 2>"$WORK/m.err")
  grep -qF '(global-name "com.example.toolchain")' <<<"$P10" || die "lean.allowed_mach should be allowed"
  grep -qE 'launchservicesd"|pasteboard\.1"|cfprefsd\.agent"|appleevents"' <<<"$P10" && die "LEAN_MACH_NEVER names must stay denied: $(grep mach-lookup <<<"$P10")"
  grep -q 'mach service com.apple.pasteboard.1 stays denied' "$WORK/m.err" || die "a refused mach service should be named: $(cat "$WORK/m.err")"
  jq 'del(.lean.allowed_mach)' "$R3/.harness.json" > "$WORK/h.json" && mv "$WORK/h.json" "$R3/.harness.json"
  pass "sandboxed (--seatbelt): mach lookups denied but for LEAN_MACH_ALLOW (LaunchServices, lsd, Apple Events, the pasteboard refused), launchctl (help, a link, a copy), signals to outside processes, cfprefsd's agent and terminal writes and ioctls fail; git, python, node and cargo run, writing only in the run's TMPDIR"
fi
# The env scrub takes the names from the environment itself (names that aren't shell
# identifiers, multi-line values), and drops git config and npm auth passed through it; in
# both shells.
for sh in bash /bin/bash; do
  [ -x "$(command -v "$sh")" ] || continue
  got=$(env 'MY-API_TOKEN=l1' 'npm_config_//reg.example/:_authToken=l2' npm_config__auth=l3 npm_config_registry=r \
      MYSQL_PWD=m GPG_PASSPHRASE=g YARN_NPM_AUTH_IDENT=y BUNDLE_GEMS__EXAMPLE__COM=u:p OPENAI_KEY=o \
      BUNDLE_BUILD__NOKOGIRI=--use-system-libraries BUNDLE_PATH=vendor \
      DB_PASS=d SMTP_PASS=s GITHUB_PAT=p DOCKER_AUTH_CONFIG=c NPM_AUTH=n ORG_GRADLE_PROJECT_signingKey=k \
      ORG_GRADLE_PROJECT_signingPassword=w ORG_GRADLE_PROJECT_version=1 SESSION_COOKIE=c \
      HTTPS_PROXY=http://u:p@proxy.example:8080 ALL_PROXY=u:p@socks.example:1080 http_proxy=http://proxy.example:3128 \
      npm_config_https_proxy=http://u:p@px1.example:1 npm_config_proxy=http://u:p@px2.example:2 YARN_HTTPS_PROXY=http://u:p@px3.example:3 \
      BUNDLE_HTTP_PROXY=http://u:p@px4.example:4 https_proxy=http://u:pa/ss@px5.example:5 FTP_PROXY='http://u:p@@not a host' \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0=l4 GIT_CONFIG_PARAMETERS="'a.b'='c'" \
      "$(printf 'ML=x\nFAKE_IN_VALUE_TOKEN=y')" PLAIN=p \
      "$sh" -c '. "$1/lean/lib.sh"; lean_env_args "$2"; printf "%s\n" "${LEAN_ENV_ARGS[@]}"' _ "$TOOLKIT_DIR" "$R3")
  for n in 'MY-API_TOKEN' 'npm_config_//reg.example/:_authToken' npm_config__auth GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS \
           MYSQL_PWD GPG_PASSPHRASE YARN_NPM_AUTH_IDENT BUNDLE_GEMS__EXAMPLE__COM OPENAI_KEY \
           DB_PASS SMTP_PASS GITHUB_PAT DOCKER_AUTH_CONFIG NPM_AUTH ORG_GRADLE_PROJECT_signingKey ORG_GRADLE_PROJECT_signingPassword SESSION_COOKIE; do
    grep -qxF -- "$n" <<<"$got" || die "$sh: lean_env_args should drop $n: $got"
  done
  grep -qE '^(PLAIN|ML|FAKE_IN_VALUE_TOKEN|npm_config_registry|BUNDLE_BUILD__NOKOGIRI|BUNDLE_PATH)$' <<<"$got" && die "$sh: only secret-looking names are dropped: $got"
  grep -qE '^(ORG_GRADLE_PROJECT_version|http_proxy|HTTPS_PROXY|ALL_PROXY)$' <<<"$got" && die "$sh: build properties and proxies are kept: $got"
  grep -qxF 'HTTPS_PROXY=http://proxy.example:8080' <<<"$got" && grep -qxF 'ALL_PROXY=socks.example:1080' <<<"$got" \
    || die "$sh: a proxy URL's credentials should be stripped: $got"
  grep -q '^http_proxy=' <<<"$got" && die "$sh: a proxy without credentials is passed on as is: $got"
  for kv in npm_config_https_proxy=http://px1.example:1 npm_config_proxy=http://px2.example:2 YARN_HTTPS_PROXY=http://px3.example:3 \
            BUNDLE_HTTP_PROXY=http://px4.example:4 https_proxy=http://px5.example:5; do
    grep -qxF "$kv" <<<"$got" || die "$sh: any name ending in proxy loses the credentials, up to the last @ (want $kv): $got"
  done
  grep -qE 'u:p|pa/ss' <<<"$got" && die "$sh: no proxy credentials may be left: $got"
  grep -qxF FTP_PROXY <<<"$got" || die "$sh: a proxy value with an @ that can't be parsed is dropped: $got"
done
# Where env has no -0, perl's %ENV gives the names; with neither, nothing runs (fail closed).
mkdir -p "$WORK/noenv0"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -0 ] && { echo "env: illegal option -- 0" >&2; exit 1; }; done\nexec /usr/bin/env "$@"\n' > "$WORK/noenv0/env"
chmod +x "$WORK/noenv0/env"
got=$(env PATH="$WORK/noenv0:$PATH" 'MY-API_TOKEN=l1' bash -c '. "$1/lean/lib.sh"; lean_env_args "$2"; printf "%s\n" "${LEAN_ENV_ARGS[@]}"' _ "$TOOLKIT_DIR" "$R3" 2>&1) \
  || die "lean_env_args should fall back to perl: $got"
grep -qxF 'MY-API_TOKEN' <<<"$got" || die "the perl fallback should drop MY-API_TOKEN: $got"
printf '#!/bin/sh\nexit 1\n' > "$WORK/noenv0/perl"; chmod +x "$WORK/noenv0/perl"
out=$(PATH="$WORK/noenv0:$PATH" LEAN_GATE_UNSANDBOXED=1 bash -c '. "$1/lean/lib.sh"; lean_sandbox_prepare "$2"; lean_sandboxed "$2" "touch ran.txt"' _ "$TOOLKIT_DIR" "$R3" 2>&1) \
  && die "without env -0 and perl the command must not run: $out"
[ ! -e "$R3/ran.txt" ] && grep -q "can't list the environment's variables" <<<"$out" || { rm -f "$R3/ran.txt"; die "fail closed, naming why: $out"; }
# Without perl (setsid, closing descriptors) lean_in_group runs nothing either.
printf '#!/bin/sh\nexit 127\n' > "$WORK/noenv0/perl"
out=$(PATH="$WORK/noenv0:$PATH" bash -c 'command() { [ "$2" = perl ] && return 1; builtin command "$@"; }; . "$1/lean/lib.sh"; lean_in_group touch "$2/ran.txt"' _ "$TOOLKIT_DIR" "$R3" 2>&1) \
  && die "without perl lean_in_group must not run the command: $out"
[ ! -e "$R3/ran.txt" ] && grep -q 'perl is needed' <<<"$out" || { rm -f "$R3/ran.txt"; die "lean_in_group fails closed without perl, naming why: $out"; }
rm -r "$WORK/noenv0"
setv '! env | grep -qE "^(MY-API_TOKEN|npm_config_//|npm_config__auth|GIT_CONFIG_(COUNT|KEY_0|VALUE_0|PARAMETERS))="'
for un in 0 1; do
  out=$(env 'MY-API_TOKEN=l1' 'npm_config_//reg.example/:_authToken=l2' npm_config__auth=l3 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
    GIT_CONFIG_VALUE_0='Authorization: l4' GIT_CONFIG_PARAMETERS="'http.extraheader'='Authorization: l5'" LEAN_GATE_UNSANDBOXED=$un bash "$TOOLKIT_DIR/lean/gate.sh" "$R3" f 2>&1) \
    || die "the gate's suite must run without them (LEAN_GATE_UNSANDBOXED=$un): $out"
done
setv true
pass "the env scrub drops non-identifier names, git config, npm/yarn auth, MYSQL_PWD, passphrases, *_KEY, *_PASS, *_PAT, cookies, Docker and Gradle signing credentials and bundler credentials, strips proxy URLs' credentials (any name ending in proxy, up to the last @; unparsable ones dropped), under bash and /bin/bash; perl when env has no -0; fails closed without both, and without perl"
mkdir -p "$R3/node_modules"
printf '/node_modules\n' >> "$R3/.git/info/exclude"
# A nested CLAUDE.md the gate's profile can't stop (carried in by renaming its folder into a
# git-ignored one; a session's Bash can write one directly): the gate refuses it, any case,
# unless git tracks it unchanged at the base.
if [ "$have_sbx" = 1 ]; then
  setv 'mkdir -p "$TMPDIR/pkg" && echo injected > "$TMPDIR/pkg/CLAUDE.md" && mv "$TMPDIR/pkg" node_modules/pkg'
  out=$(gate3) && die "a CLAUDE.md carried into an ignored folder must fail the gate: $out"
  [ "$(cat "$R3/node_modules/pkg/CLAUDE.md" 2>/dev/null)" = injected ] || die "the scenario: the folder rename should get past the profile: $out"
else
  mkdir -p "$R3/node_modules/pkg" && echo injected > "$R3/node_modules/pkg/CLAUDE.md"
  out=$(gate3) && die "a nested CLAUDE.md in an ignored folder must fail the gate: $out"
fi
grep -q '^CLAUDE.md / CLAUDE.local.md OR NESTED .claude/ FILES NOT TRACKED' <<<"$out" && grep -qx 'node_modules/pkg/CLAUDE.md' <<<"$out" || die "the file should be named: $out"
setv true; rm -r "$R3/node_modules/pkg"
mkdir -p "$R3/src/deep"; echo x > "$R3/src/deep/claude.LOCAL.md"
out=$(gate3) && die "an untracked nested claude.LOCAL.md must fail the gate: $out"
grep -qx 'src/deep/claude.LOCAL.md' <<<"$out" || die "it should be named: $out"
rm "$R3/src/deep/claude.LOCAL.md"; echo '# memory' > "$R3/src/deep/CLAUDE.md"
g -C "$R3" add src/deep/CLAUDE.md && g -C "$R3" commit -qm memory || die "commit nested CLAUDE.md"
out=$(gate3) || die "a nested CLAUDE.md tracked at the base passes: $out"
echo changed >> "$R3/src/deep/CLAUDE.md"
out=$(gate3) && die "a tracked nested CLAUDE.md that changed must fail the gate: $out"
grep -qx 'src/deep/CLAUDE.md' <<<"$out" || die "it should be named: $out"
g -C "$R3" checkout -q -- src/deep/CLAUDE.md
rm -r "$R3/node_modules"
pass "the gate refuses nested CLAUDE.md / CLAUDE.local.md not tracked unchanged at the base (any case), ignored ones included; tracked memory files pass"

# Check 6 keeps names NUL-separated: a folder whose name holds a newline (posing as the tracked
# AGENTS.md, carried in by a rename past check 3 with a .gitignore of its own) fails the gate;
# a nested CLAUDE.md under a non-ASCII folder name, tracked unchanged at the base, passes
# (git quotes such names by default, core.quotePath).
CAFE=$(printf 'caf\303\251'); NLD=$(printf 'AGENTS.md\nx')
mkdir -p "$R3/$CAFE" && echo '# memory' > "$R3/$CAFE/CLAUDE.md"
g -C "$R3" add -- "$CAFE/CLAUDE.md" && g -C "$R3" commit -qm cafe || die "commit the non-ASCII CLAUDE.md"
out=$(gate3) || die "a nested CLAUDE.md in a non-ASCII folder, tracked unchanged, should pass: $out"
if [ "$have_sbx" = 1 ]; then
  setv 'mkdir -p "$TMPDIR/p" && printf "*\n" > "$TMPDIR/p/.gitignore" && echo injected > "$TMPDIR/p/CLAUDE.md" && mv "$TMPDIR/p" "$(printf "AGENTS.md\nx")"'
else
  mkdir -p "$R3/$NLD" && printf '*\n' > "$R3/$NLD/.gitignore" && echo injected > "$R3/$NLD/CLAUDE.md"
fi
out=$(gate3) && die "a folder name with a newline must fail the gate: $out"
[ "$(cat "$R3/$NLD/CLAUDE.md" 2>/dev/null)" = injected ] || die "the scenario: the folder should have been carried in: $out"
grep -q '^PATHS WITH A NEWLINE' <<<"$out" && grep -q 'AGENTS\.md.*x/CLAUDE\.md' <<<"$out" || die "the path should be named, quoted: $out"
setv true; rm -r "${R3:?}/${NLD:?}"
# Folders the gate can't list: one without the read bit (its CLAUDE.md still opens by path),
# one without the search bit: each fails, named; the gate changes no permission.
if [ "$have_sbx" = 1 ]; then
  setv 'mkdir -p "$TMPDIR/p" node_modules && echo injected > "$TMPDIR/p/CLAUDE.md" && mv "$TMPDIR/p" node_modules/pkg && chmod 300 node_modules/pkg'
else
  mkdir -p "$R3/node_modules/pkg" && echo injected > "$R3/node_modules/pkg/CLAUDE.md" && chmod 300 "$R3/node_modules/pkg"
fi
out=$(gate3) && die "a folder without the read bit must fail the gate: $out"
[ "$(cat "$R3/node_modules/pkg/CLAUDE.md" 2>/dev/null)" = injected ] || die "the scenario: the file should still open by path: $out"
grep -q "^FOLDERS THE GATE CAN'T LIST" <<<"$out" && grep -qx 'node_modules/pkg' <<<"$out" || die "the folder should be named: $out"
[ "$(stat -f %Lp "$R3/node_modules/pkg" 2>/dev/null || stat -c %a "$R3/node_modules/pkg")" = 300 ] || die "the gate must not change the folder's permissions"
chmod 700 "$R3/node_modules/pkg"; rm -r "${R3:?}/node_modules"
setv true
mkdir -p "$R3/node_modules/q" && echo x > "$R3/node_modules/q/CLAUDE.md" && chmod 600 "$R3/node_modules/q"
out=$(gate3) && die "a folder without the search bit must fail the gate: $out"
grep -qx 'node_modules/q' <<<"$out" || die "the folder should be named: $out"
chmod 700 "$R3/node_modules/q"; rm -r "${R3:?}/node_modules"
# Nested .claude/ folders (skills, commands, agents): write-denied by regex; one carried in by a
# rename fails the gate, file by file; one tracked unchanged at the base passes.
if [ "$have_sbx" = 1 ]; then
  sb "$R3" mkdir -p "$R3/src/.claude/skills" 2>/dev/null && die "sandboxed: a nested .claude folder must be write-denied"
  sb "$R3" mkdir -p "$R3/src/.Claude" 2>/dev/null && die "sandboxed: a nested .Claude folder must be write-denied"
  setv 'mkdir -p "$TMPDIR/c/.claude/skills/s" node_modules && echo x > "$TMPDIR/c/.claude/skills/s/SKILL.md" && mv "$TMPDIR/c" node_modules/c'
else
  mkdir -p "$R3/node_modules/c/.claude/skills/s" && echo x > "$R3/node_modules/c/.claude/skills/s/SKILL.md"
fi
out=$(gate3) && die "a nested .claude folder carried in must fail the gate: $out"
grep -qx 'node_modules/c/.claude/skills/s/SKILL.md' <<<"$out" || die "the nested .claude file should be named: $out"
setv true; rm -rf "${R3:?}/node_modules"
mkdir -p "$R3/src/.claude/commands" && echo '# cmd' > "$R3/src/.claude/commands/x.md"
g -C "$R3" add src/.claude && g -C "$R3" commit -qm cmd || die "commit nested .claude"
out=$(gate3) || die "a nested .claude file tracked unchanged at the base passes: $out"
echo changed >> "$R3/src/.claude/commands/x.md"
out=$(gate3) && die "a changed tracked nested .claude file must fail the gate: $out"
grep -qx 'src/.claude/commands/x.md' <<<"$out" || die "it should be named: $out"
g -C "$R3" checkout -q -- src/.claude/commands/x.md
pass "the gate keeps names NUL-separated (newline names fail, non-ASCII tracked ones pass) and fails on folders it can't list and nested .claude files not tracked unchanged; nested .claude is write-denied"
if [ "$have_sbx" = 1 ]; then
  # lean_run_lock: a second sandboxed run of the project fails after LEAN_RUN_LOCK_WAIT with its
  # own message; a third waits for the first and runs; a lock whose holder is gone, or whose pid
  # now belongs to another process, is taken over; a live holder keeps it.
  LOCK="$ST3/tmp/run.lock"
  lsb3 'sleep 12' & FIRST=$!
  i=0; while [ ! -s "$LOCK/pid" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$LOCK/pid" ] || die "the first run should hold the lock"
  out=$(LEAN_RUN_LOCK_WAIT=2 lsb3 'touch ran2' 2>&1); rc=$?
  [ "$rc" = 125 ] && grep -qF 'another sandboxed run of this project' <<<"$out" && grep -qF 'still holds' <<<"$out" || die "a second run must fail after LEAN_RUN_LOCK_WAIT (125, its message): rc=$rc $out"
  [ ! -e "$R3/ran2" ] || die "the second run must not run its command"
  SECONDS=0; out=$(lsb3 'touch ran3' 2>&1) || die "a third run should wait and run: $out"
  [ -e "$R3/ran3" ] && [ "$SECONDS" -ge 1 ] && grep -qF 'waiting for another sandboxed run' <<<"$out" || die "the third run should have waited for the first: ${SECONDS}s $out"
  wait "$FIRST" || die "the first run should pass"
  sleep 0 & DEAD=$!; wait "$DEAD"
  mkdir -p "$LOCK" && printf '%s x\n' "$DEAD" > "$LOCK/pid"
  out=$(LEAN_RUN_LOCK_WAIT=2 lsb3 'touch ran4' 2>&1) && [ -e "$R3/ran4" ] || die "a dead holder's lock should be taken over: $out"
  sleep 30 & LIVE=$!
  mkdir -p "$LOCK" && printf '%s %s\n' "$LIVE" "Thu Jan  1 00:00:00 1970" > "$LOCK/pid"
  out=$(LEAN_RUN_LOCK_WAIT=2 lsb3 'touch ran5' 2>&1) && [ -e "$R3/ran5" ] || { kill "$LIVE"; die "a lock whose pid now belongs to another process should be taken over: $out"; }
  mkdir -p "$LOCK" && printf '%s %s\n' "$LIVE" "$(ps -o lstart= -p "$LIVE" | sed 's/^ *//; s/ *$//')" > "$LOCK/pid"
  out=$(LEAN_RUN_LOCK_WAIT=1 lsb3 'touch ran6' 2>&1) && { kill "$LIVE"; die "a live holder with its own start time keeps the lock: $out"; }
  kill "$LIVE"; wait "$LIVE" 2>/dev/null; rm -rf "${LOCK:?}"
  [ ! -e "$R3/ran6" ] || die "the run behind a live holder must not run"
  rm -f "$R3/ran3" "$R3/ran4" "$R3/ran5"
  pass "lean_run_lock: a second run fails after LEAN_RUN_LOCK_WAIT with its own message (125), a third waits and runs; a dead holder or a reused pid loses the lock, a live holder keeps it"
fi

echo "all $PASS checks passed"
