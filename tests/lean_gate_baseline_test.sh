#!/usr/bin/env bash
# lean_gate_baseline_test.sh — files already changed before a lean feature, and
# .harness.json::lean.acceptance_command, against throwaway projects (temp HOME, temp git
# repositories, a stub adapter: no model is ever called; the suite runs unsandboxed,
# LEAN_GATE_UNSANDBOXED=1).
#
#   1. the first pin records the files already changed (modified, deleted, untracked) in
#      dirty.sha; the gate ignores them while their content is the recorded one and names them
#      in one `gate: ignoring` line; a file changed further, or put back to HEAD, counts and must
#      be under **Files**; an untracked one changed further too.
#   2. a feature pinned before dirty.sha existed keeps today's behaviour: every change counts;
#      neither a re-pin nor a later claim (--again) records one.
#   3. chain's `next:` log-out line leaves the ignored files out of --changes.
#   4. lean.acceptance_command: {paths} replaced with the quoted paths, or the paths appended;
#      unset, verify_command with the paths appended, and a [WARN] when it is compound
#      (lean_is_compound); used by the gate and by run.sh freeze.
#   5. a non-string lean.acceptance_command exits 2: the gate, and run.sh before any session.
#   6. dirty.sha is written once, before the feature's first session: a later claim (--again)
#      or a re-pin after deleting trusted.sha never rewrites it (the session's files count), and a
#      pin after a session ran records none.
#   7. a rename is recorded under both paths (its old path put back counts); a chmod counts (1).
#   8. risk mode: the feature's plan, review report, acceptance tests and frozen manifest files
#      never get in dirty.sha; they stay in chain's next: --changes and out of the ignoring line.
#   9. acceptance test files whose names hold a space: run.sh freeze hashes them (first and
#      again once frozen) and runs them shell-quoted (verify_command fallback and {paths}); the
#      risk gate checks and runs them.
#
# Usage: bash tests/lean_gate_baseline_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }
g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

mkdir -p "$WORK/home"
export HOME="$WORK/home" LEAN_GATE_UNSANDBOXED=1 GIT_CONFIG_GLOBAL=/dev/null
export LEAN_CLAUDE_TMP="$WORK/no-claude-tmp"
L="$WORK/lean"; cp -R "$TOOLKIT_DIR/lean" "$L"
export CALLS="$WORK/calls" SCN="$WORK/scn"
cat > "$L/adapters/claude.sh" <<'SH'
#!/usr/bin/env bash
project="$1" result="${6:-}"
st=$(basename "$result"); st="${st#*.}"; st="${st%%.*}"
echo "$st" >> "$CALLS"
cd "$project" || exit 1
[ -f "$SCN/$st" ] && . "$SCN/$st"
[ -z "$result" ] || printf '{"is_error":false,"num_turns":1,"total_cost_usd":0.01}\n' > "$result"
SH
chmod +x "$L/adapters/claude.sh"

# new_project <dir> [harness] — a repository whose suite passes once src/app.txt says done; the
# runner appends its arguments to .args (git-ignored).
new_project() {
  local p="$1"
  mkdir -p "$p/src" "$p/tests" "$p/docs/features" "$p/acceptance"
  echo '{"verify_command":"bash run_tests.sh","lean":{"implementer":"claude","reviewer":"claude:other"}}' > "$p/.harness.json"
  cat > "$p/run_tests.sh" <<'T'
printf '%s|' "$@" >> .args; echo >> .args
[ $# -gt 0 ] || set -- tests/*_test.sh
for a in "$@"; do case "$a" in --*) shift ;; *) break ;; esac; done
rc=0
for f in "$@"; do case "$f" in --*) continue ;; esac; if bash "$f"; then echo " 1 pass"; else echo " 1 fail"; rc=1; fi; done
exit "$rc"
T
  printf 'grep -q done src/app.txt || { echo "FAIL: app_test expects done"; exit 1; }\n' > "$p/tests/app_test.sh"
  printf 'grep -q done src/app.txt || { echo "FAIL: acceptance expects done"; exit 1; }\n' > "$p/acceptance/f.test.sh"
  printf 'todo\n' > "$p/src/app.txt"
  printf 'a: 1\n' > "$p/config.yml"
  printf 'old\n' > "$p/old.txt"
  printf '# f\n\n**Files**\n- `src/app.txt`\n' > "$p/docs/features/f.md"
  if [ "${2:-}" = harness ]; then
    mkdir -p "$p/scripts"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$p/scripts/harness.sh"
  fi
  printf '.harness.json\nscripts/\n.args\n' > "$p/.gitignore"
  g -C "$p" init -q && g -C "$p" add -A && g -C "$p" commit -qm base || die "project setup: $p"
}
# dirty <dir> — the user's own edits before the feature: a tracked file modified, one deleted,
# an untracked one.
dirty() { printf 'a: local\n' > "$1/config.yml"; rm "$1/old.txt"; printf 'mine\n' > "$1/notes.txt"; }
lib() { (cd "$P" && bash -c '. "$1/lib.sh"; shift; "$@"' _ "$L" "$@"); }
state() { lib lean_state_dir "$P"; }
gate() { (cd "$P" && bash "$L/gate.sh" "$P" f "$@") > "$WORK/out" 2>&1; }
out() { cat "$WORK/out"; }
conf() { jq "$2" "$1/.harness.json" > "$WORK/h" && mv "$WORK/h" "$1/.harness.json"; }

echo "1. files changed before the feature"
P="$WORK/p1"; new_project "$P"; dirty "$P"
# A hidden harness: its files are git-excluded (.git/info/exclude), and progress/ is the harness's.
mkdir -p "$P/harness" "$P/progress"; printf 'x\n' > "$P/harness/persona.md"; printf 'x\n' > "$P/progress/note.md"
printf 'harness/\n' >> "$P/.git/info/exclude"
lib lean_pin "$P" f 2>/dev/null || die "pin"
D="$(state)/lean/f/dirty.sha"
[ "$(awk '{print $2}' "$D" | tr '\n' ' ')" = "config.yml notes.txt old.txt " ] || die "dirty.sha: $(cat "$D")"
grep -q '^deleted  old.txt$' "$D" || die "a deleted file is recorded as deleted: $(cat "$D")"
printf 'done\n' > "$P/src/app.txt"
gate || die "pre-dirty files left as they were must pass: $(out)"
grep -qx 'gate: ignoring 3 file(s) changed before the feature, unchanged since: config.yml, notes.txt, old.txt' "$WORK/out" \
  || die "one line naming the ignored files: $(out)"
pass "pre-dirty files (modified, deleted, untracked) unchanged: ignored, named in one line"

printf 'a: more\n' > "$P/config.yml"
gate && die "a pre-dirty file changed further must be listed: $(out)"
grep -A3 'CHANGED BUT NOT LISTED' "$WORK/out" | grep -qx 'config.yml' || die "config.yml must be named: $(out)"
grep -q 'ignoring 2 file(s)' "$WORK/out" || die "the others stay ignored: $(out)"
printf '# f\n\n**Files**\n- `src/app.txt`\n- `config.yml`\n' > "$P/docs/features/f.md"
gate || die "listed under Files it passes: $(out)"
g -C "$P" checkout -q -- config.yml
printf '# f\n\n**Files**\n- `src/app.txt`\n' > "$P/docs/features/f.md"
gate && die "a pre-dirty file put back to HEAD is a change too: $(out)"
grep -A3 'CHANGED BUT NOT LISTED' "$WORK/out" | grep -qx 'config.yml' || die "config.yml put back must be named: $(out)"
printf 'a: local\n' > "$P/config.yml"
printf 'theirs\n' > "$P/notes.txt"
gate && die "an untracked pre-existing file changed must be listed: $(out)"
grep -A3 'CHANGED BUT NOT LISTED' "$WORK/out" | grep -qx 'notes.txt' || die "notes.txt must be named: $(out)"
printf 'mine\n' > "$P/notes.txt"
gate || die "back to the recorded content: $(out)"
chmod +x "$P/notes.txt"
gate && die "a chmod on a pre-dirty file is a change: $(out)"
grep -A3 'CHANGED BUT NOT LISTED' "$WORK/out" | grep -qx 'notes.txt' || die "notes.txt (chmod) must be named: $(out)"
chmod -x "$P/notes.txt"
gate || die "mode back as recorded: $(out)"
pass "a pre-dirty file changed further (tracked, put back to HEAD, untracked, chmod) must be under Files"

echo "2. features pinned before dirty.sha"
rm "$D"
gate && die "without dirty.sha every change counts: $(out)"
grep -A4 'CHANGED BUT NOT LISTED' "$WORK/out" | grep -qx 'config.yml' || die "old behaviour names config.yml: $(out)"
grep -q 'gate: ignoring' "$WORK/out" && die "no ignoring line without dirty.sha: $(out)"
lib lean_pin "$P" f 2>/dev/null
[ ! -f "$D" ] || die "a pinned feature must not get a dirty.sha later"
rm "$(state)/lean/f/trusted.sha"
lib lean_pin "$P" f 2>/dev/null
[ -f "$(state)/lean/f/trusted.sha" ] && [ ! -f "$D" ] || die "re-pinning after deleting trusted.sha must not record the sessions' work"
lib lean_pin "$P" f --again 2>/dev/null
[ ! -f "$D" ] || die "--again (a later claim) must not record one either: $(cat "$D")"
pass "no dirty.sha: today's behaviour; a re-pin or a later claim never records one"

echo "3. chain's next: line"
P="$WORK/p3"; new_project "$P" harness; dirty "$P"
mkdir -p "$SCN"; printf 'printf "done\\n" > src/app.txt\n' > "$SCN/implement"; : > "$CALLS"
(cd "$P" && bash "$L/run.sh" chain f) > "$WORK/out" 2>&1 || die "chain with pre-dirty files should pass: $(out)"
next=$(grep '^next:' "$WORK/out") || die "no next: line: $(out)"
[[ "$next" == *"--changes src/app.txt --verification"* ]] || die "next: --changes must hold only the feature's files: $next"
grep -q '^  gate: ignoring 3 file(s)' "$WORK/out" || die "the chain shows the ignoring line: $(out)"
pass "chain: ignored files are not in next:'s --changes"

echo "4. lean.acceptance_command"
P="$WORK/p4"; new_project "$P"
printf 'grep -q done src/app.txt\n' > "$P/acceptance/f two.test.sh"
g -C "$P" add -A && g -C "$P" commit -qm acc
printf 'done\n' > "$P/src/app.txt"
M="$WORK/manifest.sha"; (cd "$P" && shasum -a 256 acceptance/f.test.sh "acceptance/f two.test.sh") > "$M"
lib lean_pin "$P" f 2>/dev/null
conf "$P" '.lean.acceptance_command = "bash run_tests.sh --acc {paths} --end"'
: > "$P/.args"; gate --frozen "$M" || die "acceptance_command with {paths}: $(out)"
grep -qxF -- '--acc|acceptance/f.test.sh|acceptance/f two.test.sh|--end|' "$P/.args" || die "{paths} replaced, quoted: $(cat "$P/.args")"
grep -q 'compound' "$WORK/out" && die "no warning with acceptance_command: $(out)"
conf "$P" '.lean.acceptance_command = "bash run_tests.sh --acc"'
: > "$P/.args"; gate --frozen "$M" || die "acceptance_command without {paths}: $(out)"
grep -qxF -- '--acc|acceptance/f.test.sh|acceptance/f two.test.sh|' "$P/.args" || die "paths appended: $(cat "$P/.args")"
pass "acceptance_command: {paths} replaced or the paths appended, shell-quoted"

conf "$P" 'del(.lean.acceptance_command) | .verify_command = "true && bash run_tests.sh"'
: > "$P/.args"; gate --frozen "$M"
grep -q '^\[WARN\] lean: verify_command is a compound command' "$WORK/out" || die "warning on a compound verify_command: $(out)"
conf "$P" '.verify_command = "bash run_tests.sh"'
gate --frozen "$M" >/dev/null; grep -q 'compound' "$WORK/out" && die "no warning on a simple verify_command: $(out)"
for c in 'find a -exec x {} \;' 'echo "a;b"' 'echo $(a; b)' 'npm test' 'npm test 2>&1' 'npm test &>log' 'x >&2' 'a`b;c`' 'echo "a&b"' $'echo "a\nb"'; do
  lib lean_is_compound "$c" && die "not compound: $c"
done
for c in 'a && b' 'a || b' 'a | b' 'a; b' 'a & b' $'a\nb' 'find h src -name "*.js" -exec node --check {} + && npm test'; do
  lib lean_is_compound "$c" || die "compound: $c"
done
pass "unset: verify_command with the paths appended, [WARN] only when compound (top level)"

rm -rf "$(state)/frozen"
conf "$P" '.lean.acceptance_command = "bash run_tests.sh --freeze {paths}"'
printf 'todo\n' > "$P/src/app.txt"
rm -f "$(state)/lean/f/trusted.sha"   # the config edits above are the user's
: > "$P/.args"; (cd "$P" && bash "$L/run.sh" freeze f) > "$WORK/out" 2>&1 || die "freeze: $(out)"
grep -qxF -- '--freeze|acceptance/f.test.sh|' "$P/.args" || die "freeze runs acceptance_command: $(cat "$P/.args") / $(out)"
pass "run.sh freeze runs lean.acceptance_command"

echo "5. invalid lean.acceptance_command"
for v in 5 '["npm test"]' true '{"a":1}'; do
  conf "$P" ".lean.acceptance_command = $v"
  gate --frozen "$M"; rc=$?
  [ "$rc" = 2 ] && grep -q 'invalid .harness.json::lean.acceptance_command' "$WORK/out" || die "gate with $v: exit $rc / $(out)"
  : > "$CALLS"
  rm -f "$(state)/lean/f/trusted.sha"
  (cd "$P" && bash "$L/run.sh" implement f --headless) > "$WORK/out" 2>&1; rc=$?
  [ "$rc" = 2 ] && [ ! -s "$CALLS" ] || die "run.sh with $v must exit 2 before any session: exit $rc / $(out)"
done
pass "non-string acceptance_command: exit 2 (gate; run.sh before any session)"

echo "6. dirty.sha is written once, before the feature's first session"
# The reviewer's sequence: run.sh pins by itself (the feature's first pin), a session writes
# files, the feature is claimed afterwards (--again): the session's files must still count.
P="$WORK/p6"; new_project "$P"; dirty "$P"
lib lean_pin "$P" f 2>/dev/null || die "first pin"
D="$(state)/lean/f/dirty.sha"; cp "$D" "$WORK/dirty.first"
printf 'done\n' > "$P/src/app.txt"; printf 'evil\n' > "$P/src/backdoor.txt"
lib lean_pin "$P" f --again 2>/dev/null || die "claim's pin"
cmp -s "$D" "$WORK/dirty.first" || die "a later claim must not rewrite dirty.sha: $(cat "$D")"
gate && die "the session's files must not be taken as already there: $(out)"
grep -A4 'CHANGED BUT NOT LISTED' "$WORK/out" | grep -qx 'src/backdoor.txt' || die "src/backdoor.txt must be named: $(out)"
grep 'gate: ignoring' "$WORK/out" | grep -q 'src/' && die "no src/ file is ignored: $(out)"
[ "$(lib lean_feature_changes "$P" f HEAD | tr '\n' ' ')" = "src/app.txt src/backdoor.txt " ] \
  || die "the feature's changes: $(lib lean_feature_changes "$P" f HEAD)"
# The user edits .harness.json and deletes trusted.sha to re-pin: dirty.sha stays as it was.
rm "$(state)/lean/f/trusted.sha"
lib lean_pin "$P" f 2>/dev/null && [ -f "$(state)/lean/f/trusted.sha" ] || die "re-pin"
cmp -s "$D" "$WORK/dirty.first" || die "a re-pin after deleting trusted.sha must not rewrite dirty.sha: $(cat "$D")"
gate && die "still failing after the re-pin: $(out)"
grep -A4 'CHANGED BUT NOT LISTED' "$WORK/out" | grep -qx 'src/backdoor.txt' || die "src/backdoor.txt after the re-pin: $(out)"
pass "a later claim and a re-pin after deleting trusted.sha keep the first dirty.sha: session files count"
# A session result left for the feature means it ran: no first pin, even with no lean/f/ folder.
P="$WORK/p6b"; new_project "$P"; dirty "$P"
mkdir -p "$(state)/lean"; printf '{}\n' > "$(state)/lean/f.implement.20260101000000.json"
lib lean_pin "$P" f 2>/dev/null || die "pin after a session"
[ ! -f "$(state)/lean/f/dirty.sha" ] || die "a pin after a session ran must not record dirty.sha"
pass "a pin after one of the feature's sessions ran records no dirty.sha"

echo "7. renames"
P="$WORK/p7"; new_project "$P"
g -C "$P" mv config.yml cfg2.yml
lib lean_pin "$P" f 2>/dev/null || die "pin"
D="$(state)/lean/f/dirty.sha"
grep -q '^deleted  config.yml$' "$D" && grep -q '  cfg2.yml$' "$D" || die "a rename is recorded under both paths: $(cat "$D")"
printf 'done\n' > "$P/src/app.txt"
gate || die "a pre-dirty rename left as it was: $(out)"
g -C "$P" checkout -q HEAD -- config.yml
gate && die "the renamed file put back is a change: $(out)"
grep -A4 'CHANGED BUT NOT LISTED' "$WORK/out" | grep -qx 'config.yml' || die "config.yml must be named: $(out)"
pass "a rename is recorded under both paths; its old path put back counts"

echo "8. the feature's own files are never in the baseline (risk mode)"
P="$WORK/p8"; new_project "$P" harness
# Written before the first pin and uncommitted, as in the lean flow: the plan, the acceptance
# test, an earlier review report; plus a frozen manifest naming a shared acceptance helper.
rm "$P/docs/features/f.md" "$P/acceptance/f.test.sh"; g -C "$P" commit -qam no-plan
printf '# f\n\n**Files**\n- `src/app.txt`\n' > "$P/docs/features/f.md"
printf 'grep -q done src/app.txt || { echo "FAIL: acceptance expects done"; exit 1; }\n' > "$P/acceptance/f.test.sh"
printf 'old\nVERDICT: changes\n' > "$P/docs/features/f.review.md"
printf 'true\n' > "$P/acceptance/helper.sh"
printf 'mine\n' > "$P/notes.txt"
mkdir -p "$(state)/frozen"; (cd "$P" && shasum -a 256 acceptance/helper.sh) > "$(state)/frozen/x.sha"
lib lean_dirty_manifest "$P" x | grep -q 'acceptance/helper.sh' && die "a feature's frozen manifest files stay out of its baseline"
rm "$(state)/frozen/x.sha"; rm "$P/acceptance/helper.sh"
(cd "$P" && bash "$L/run.sh" freeze f) > "$WORK/out" 2>&1 || die "freeze: $(out)"
D="$(state)/lean/f/dirty.sha"
[ "$(awk '{print $2}' "$D" | tr '\n' ' ')" = "notes.txt " ] || die "only the user's file in dirty.sha: $(cat "$D")"
: > "$CALLS"; printf 'printf "done\\n" > src/app.txt\n' > "$SCN/implement"
printf 'printf "fine\\nVERDICT: approve\\n" > docs/features/f.review.md\n' > "$SCN/review"
(cd "$P" && bash "$L/run.sh" chain f) > "$WORK/out" 2>&1 || die "risk chain: $(out)"
grep -q '^lean chain: f (risk mode' "$WORK/out" || die "risk mode: $(out)"
next=$(grep '^next:' "$WORK/out") || die "no next: line: $(out)"
[[ "$next" == *"--changes acceptance/f.test.sh docs/features/f.md docs/features/f.review.md src/app.txt --verification"* ]] \
  || die "next: --changes must hold the plan, review report and acceptance test: $next"
grep -qx '  gate: ignoring 1 file(s) changed before the feature, unchanged since: notes.txt' "$WORK/out" \
  || die "the ignoring line names only the user's file: $(out)"
pass "risk: plan, review report, acceptance tests and frozen files stay out of dirty.sha and in next:'s --changes"

echo "9. acceptance file names with a space"
P="$WORK/p9"; new_project "$P"
# Uncommitted, as in the lean flow: one with a space in its name, one in a folder with a space.
printf 'grep -q done src/app.txt || { echo "FAIL: two words"; exit 1; }\n' > "$P/acceptance/f.two words.test.sh"
mkdir -p "$P/acceptance/sub dir"
printf 'grep -q done src/app.txt || { echo "FAIL: sub dir"; exit 1; }\n' > "$P/acceptance/sub dir/f.more.test.sh"
want=$(printf '%s\n' "acceptance/f.test.sh" "acceptance/f.two words.test.sh" "acceptance/sub dir/f.more.test.sh")
# has_args — the runner got every acceptance path, each as one argument (.args: "a|b|").
has_args() {
  local p
  while IFS= read -r p; do sed 's/^/|/' "$P/.args" | grep -qF -- "|$p|" || return 1; done <<<"$want"
}
: > "$P/.args"; (cd "$P" && bash "$L/run.sh" freeze f) > "$WORK/out" 2>&1 || die "freeze with spaced names: $(out)"
[ "$(lib lean_manifest_paths "$(state)/frozen/f.sha" | sort)" = "$(sort <<<"$want")" ] || die "manifest paths: $(cat "$(state)/frozen/f.sha")"
(cd "$P" && shasum -a 256 -c "$(state)/frozen/f.sha") >/dev/null 2>&1 || die "the manifest checks: $(cat "$(state)/frozen/f.sha")"
has_args || die "freeze runs verify_command with each path quoted: $(cat "$P/.args")"
# The hand-run freeze pins first (no manifest yet): an acceptance file in a subfolder is the
# feature's own, like find's recursive match in run.sh, never the user's earlier change.
! grep -qF 'acceptance/sub dir/f.more.test.sh' "$(state)/lean/f/dirty.sha" 2>/dev/null \
  || die "a subfolder acceptance file must stay out of dirty.sha: $(cat "$(state)/lean/f/dirty.sha")"
[ "$(sed -n 's/^\[lean\] before implementing: //p' "$WORK/out" | grep -o 'fail' | wc -l | tr -d ' ')" = 3 ] || die "red before green over the 3 files: $(out)"
: > "$P/.args"; (cd "$P" && bash "$L/run.sh" freeze f) > "$WORK/out" 2>&1 || die "freeze again (already frozen): $(out)"
grep -q 'already frozen' "$WORK/out" && has_args || die "freeze again reads the manifest's spaced paths: $(cat "$P/.args") / $(out)"
pass "freeze: spaced acceptance file names hashed, frozen and run as one argument each"

printf 'done\n' > "$P/src/app.txt"
: > "$P/.args"; (cd "$P" && bash "$L/run.sh" gate f) > "$WORK/out" 2>&1 || die "risk gate with spaced names: $(out)"
grep -q '^ALL CHECKS PASS' "$WORK/out" && has_args || die "gate ran the spaced acceptance files: $(cat "$P/.args") / $(out)"
conf "$P" '.lean.acceptance_command = "bash run_tests.sh --acc {paths} --end"'
rm -f "$(state)/lean/f/trusted.sha"   # the user's config edit
: > "$P/.args"; (cd "$P" && bash "$L/run.sh" gate f) > "$WORK/out" 2>&1 || die "risk gate, {paths}, spaced names: $(out)"
grep -q -- '^--acc|.*|--end|$' "$P/.args" && has_args || die "{paths} holds each spaced path quoted: $(cat "$P/.args")"
printf 'grep -q nope src/app.txt\n' > "$P/acceptance/f.two words.test.sh"
(cd "$P" && bash "$L/run.sh" gate f) > "$WORK/out" 2>&1 && die "a changed spaced acceptance file must fail the gate: $(out)"
grep -q 'acceptance/f.two words.test.sh' "$WORK/out" || die "the gate names the changed spaced file: $(out)"
pass "gate: spaced acceptance files checked against the manifest and run (verify_command and {paths})"

echo "PASS: $PASS checks"
