#!/usr/bin/env bash
# lean_install_repin_test.sh — a reinstall (install.sh) doesn't strand in-flight lean features.
# Each feature pins the hashes of the harness-owned files (lean/lib.sh lean_pin); a reinstall
# refreshes some of them. Against a temp HOME and a temp project installed from a copy of this
# toolkit, then reinstalled from a changed copy:
#   - a pinned feature is re-pinned for exactly the files the install changed: its trusted check
#     (what every lean step and log-out --lean run) passes, accept-config has nothing to accept,
#     the kept copy follows, one [OK] line names it and a note is recorded on the feature;
#   - a feature with an unaccepted change from before the install keeps that change flagged
#     (only the install's files are re-pinned) and gets one [WARN] line with the accept-config
#     command;
#   - a finished feature (no plan.lists / dirty.sha) is re-pinned without a word;
#   - a reinstall that changes nothing touches no pin;
#   - a reinstall that also rewrites .harness.json (--hide-harness) refreshes no kept copy of a file
#     it didn't re-pin: g's earlier verify_command edit still shows in the trusted check and in
#     accept-config (it isn't laundered into the copy);
#   - a feature pinned before copies were kept gets copies only of what was re-pinned, and a later
#     mismatch shows no unchanged file as changed.
# No model, no network, no Docker (sync skipped: no mirror env configured).
#
# Usage: bash tests/lean_install_repin_test.sh

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

mkdir -p "$WORK/home"
export HOME="$WORK/home" GIT_CONFIG_GLOBAL=/dev/null

TK="$WORK/toolkit"
mkdir -p "$TK"
(cd "$TOOLKIT_DIR" && tar cf - --exclude .git --exclude ./progress --exclude ./state --exclude ./harness.db --exclude ./.claude/worktrees .) | (cd "$TK" && tar xf -) \
  || die "copy the toolkit"

P="$WORK/p"
mkdir -p "$P"
git -C "$P" init -q || die "git init"
install_p() { (cd "$P" && bash "$TK/install.sh" --slug t --human-user Tester --verify-command true \
  --supabase-url-env LEAN_TEST_NO_URL --supabase-key-env LEAN_TEST_NO_KEY) > "$WORK/install.log" 2>&1; }
install_p || die "first install: $(cat "$WORK/install.log")"

H() { (cd "$P" && HARNESS_AGENT=leader bash scripts/harness.sh "$@") 2>&1; }
L() { (cd "$P" && bash -c '. lean/lib.sh; "$@"' _ "$@"); }
state=$(L lean_state_dir "$P")
mkdir -p "$P/docs/features"
feature() {
  H add-feature --name "$1" --title "$1" --mode normal >/dev/null || die "add $1"
  printf '# %s\n\n**Files**\n- `src/a.txt`\n' "$1" > "$P/docs/features/$1.md"
  L lean_pin "$P" "$1" 2>/dev/null || die "pin $1"
}
# g: pinned, then a .harness.json edit nobody accepted for it, made before the reinstall
# (f and h are pinned after it, with it).
feature g
jq '.verify_command = "true # edited"' "$P/.harness.json" > "$WORK/hj" && cp "$WORK/hj" "$P/.harness.json"
feature f
feature h
# k: pinned by an older version, before copies were kept (no pinned/ folder).
feature k
rm -rf "$state/lean/k/pinned"
# h finished: its lean lifecycle ended (harness.sh lean_forget_baseline).
rm -f "$state/lean/h/plan.lists" "$state/lean/h/dirty.sha"
g_before_install=$(L lean_check_trusted "$P" g 2>&1) && die "test setup: g should be flagged"

echo "1. a reinstall that changes nothing touches no pin"
for f in f g h; do cp "$state/lean/$f/trusted.sha" "$WORK/$f.pin"; done
install_p || die "reinstall: $(cat "$WORK/install.log")"
for f in f g h; do cmp -s "$state/lean/$f/trusted.sha" "$WORK/$f.pin" || die "$f's pin changed"; done
grep -q 'lean feature' "$WORK/install.log" && die "nothing to say: $(cat "$WORK/install.log")"
pass "an identical reinstall leaves every pin and says nothing"

echo "2. a reinstall that refreshes harness files"
printf '\n# toolkit v2\n' >> "$TK/lean/gate.sh"
printf '\n# toolkit v2\n' >> "$TK/scripts/harness.sh"
printf '\ntoolkit v2\n' >> "$TK/AGENTS.md"
L lean_check_trusted "$P" f 2>/dev/null || die "test setup: f matches its pin before the reinstall"
install_p || die "reinstall v2: $(cat "$WORK/install.log")"

out=$(L lean_check_trusted "$P" f 2>&1) || die "f's trusted check after the reinstall: $out"
out=$( (cd "$P" && bash lean/run.sh accept-config f) 2>&1) && grep -q 'nothing to accept' <<<"$out" || die "f: nothing left to accept: $out"
grep -q "^\[OK\]    lean feature f ($P): re-pinned the harness-owned files this install refreshed" "$WORK/install.log" || die "the [OK] line for f: $(cat "$WORK/install.log")"
grep -q 'toolkit v2' "$state/lean/f/pinned/AGENTS.md" || die "the kept copy of AGENTS.md follows"
sqlite3 "$P/harness.db" "SELECT entry FROM feature_notes;" | grep -q 'lean: install.sh re-pinned the harness-owned files it refreshed: AGENTS.md CLAUDE.md lean/gate.sh scripts/harness.sh' \
  || die "a note on f: $(sqlite3 "$P/harness.db" 'SELECT entry FROM feature_notes;')"
pass "an in-flight feature is re-pinned for the install's files: its steps and log-out are not stopped"

out=$(L lean_check_trusted "$P" g 2>&1) && die "g's unaccepted .harness.json edit must stay flagged"
[ "$(printf '%s\n' "$out" | grep -cE '^  [^ ]+$')" = 1 ] && grep -qxF '  .harness.json' <<<"$out" || die "only .harness.json is left for g: $out"
grep -q "^\[WARN\]  lean feature g: harness-owned files changed before this install still differ from its pin (.harness.json) .*lean/run.sh accept-config g$" "$WORK/install.log" \
  || die "the [WARN] line for g: $(cat "$WORK/install.log")"
pass "an earlier unaccepted change stays flagged, with one line naming the accept-config command"

L lean_check_trusted "$P" h 2>/dev/null || die "h is re-pinned too"
grep -q 'lean feature h' "$WORK/install.log" && die "a finished feature is re-pinned without a word: $(cat "$WORK/install.log")"
pass "a finished feature is re-pinned silently"

echo "3. a reinstall that rewrites .harness.json keeps g's earlier change visible"
printf '\n# toolkit v3\n' >> "$TK/lean/gate.sh"
(cd "$P" && bash "$TK/install.sh" --slug t --human-user Tester --verify-command true --hide-harness \
  --supabase-url-env LEAN_TEST_NO_URL --supabase-key-env LEAN_TEST_NO_KEY) > "$WORK/install.log" 2>&1 \
  || die "reinstall v3: $(cat "$WORK/install.log")"
[ "$(jq -r .hide_harness "$P/.harness.json")" = true ] || die "test setup: --hide-harness rewrites .harness.json"
out=$(L lean_check_trusted "$P" g 2>&1) && die "g must stay flagged after a reinstall that rewrites .harness.json"
grep -qF '+  "verify_command": "true # edited"' <<<"$out" || die "g's trusted check still shows the verify_command edit: $out"
out=$( (cd "$P" && bash lean/run.sh accept-config g --by Tester) 2>&1)
grep -qF '+  "verify_command": "true # edited"' <<<"$out" || die "accept-config g shows the verify_command edit before accepting it: $out"
L lean_check_trusted "$P" f 2>/dev/null || die "f is re-pinned for the .harness.json the install rewrote"
pass "a reinstall's rewrite of .harness.json doesn't refresh the copy of a file it didn't re-pin"

L lean_check_trusted "$P" k 2>/dev/null || die "k (no kept copies) is re-pinned too"
printf '\n# a later local edit\n' >> "$P/lean/lib.sh"
out=$(L lean_check_trusted "$P" k 2>&1) && die "test setup: k flags the lean/lib.sh edit"
grep -qE 'no copy|^    [-+@]' <<<"$out" && die "k: an unchanged file is shown as changed: $out"
grep -qxF '  lean/lib.sh' <<<"$out" || die "k names lean/lib.sh: $out"
pass "a feature pinned before copies were kept shows no unchanged file as changed"

echo "PASS: $PASS checks"
