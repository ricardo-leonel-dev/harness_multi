#!/usr/bin/env bash
# lean_claude_output_test.sh — a lean Claude Code session can use its Bash commands' stdout.
#
# Claude Code sends each Bash command's stdout/stderr to a file in its temp folder
# (/private/tmp/claude-<uid>/<project slug>/<session>/tasks/<id>.output). lean/sandbox.sh denies
# that folder and re-opens the project's entry; when the entry did not exist yet (the first
# session from the project after a reboot cleared /tmp) it was not re-opened, and every new
# process that checks its stdout failed (`cat: stdout: Operation not permitted`, node aborting).
# A fake temp folder (LEAN_CLAUDE_TMP), a temp HOME and a stub `claude`: no model is called.
#
#   1. session settings: the project's entry is created (mode 700) and re-opened, as written and
#      resolved (a project reached through a link); other entries stay denied; --seatbelt (the
#      gate) creates nothing and opens nothing.
#   2. sandbox-exec (when available): with the entry denied, `cat` and node fail on a stdout
#      file inside it (the bug); with the settings' rules they work, and another project's
#      entry stays unreadable.
#   3. lean/adapters/claude.sh refuses before starting claude when the settings deny the
#      folder without re-opening an entry in it, and starts it otherwise.
#
# Usage: bash tests/lean_claude_output_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }
g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
slug() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

mkdir -p "$WORK/home" "$WORK/bin" "$WORK/dev/proj/src"
export HOME="$WORK/home" LEAN_CACHE_BASE="$WORK/cache-base" GIT_CONFIG_GLOBAL=/dev/null LEAN_DB_SOCK_DIR="$WORK/socks"
CT="$WORK/claude-tmp"; mkdir -p "$CT/other-project/s"; printf 'other\n' > "$CT/other-project/s/x.txt"
export LEAN_CLAUDE_TMP="$CT"
P="$WORK/dev/proj"; printf 'a\n' > "$P/src/a.txt"; echo '{}' > "$P/.harness.json"
g -C "$P" init -q && g -C "$P" add -A && g -C "$P" commit -qm base || die "project setup"
E="$CT/$(slug "$P")"

echo "1. session settings"
[ ! -e "$E" ] || die "test setup: the project's entry must not exist yet"
S=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$P" 2>"$WORK/err") || die "sandbox.sh: $(cat "$WORK/err")"
[ -d "$E" ] || die "the project's entry should be created: $(ls "$CT")"
[ "$(stat -f %Lp "$E" 2>/dev/null || stat -c %a "$E")" = 700 ] || die "the entry should be mode 700"
jq -r '.sandbox.filesystem.denyRead[]' <<<"$S" | grep -qxF "$CT" || die "denyRead should hold the temp folder"
jq -r '.sandbox.filesystem.allowRead[]' <<<"$S" | grep -qxF "$E" || die "allowRead should re-open the entry: $(jq -c .sandbox.filesystem.allowRead <<<"$S")"
jq -r '.sandbox.filesystem.allowRead[]' <<<"$S" | grep -q "^$CT/other-project" && die "another entry must not be re-opened"
# A project reached through a link: Claude Code names the entry after its resolved directory.
ln -s "$WORK/dev" "$WORK/devlink"; L="$WORK/devlink/proj"
SL=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$L" 2>/dev/null) || die "sandbox.sh through a link"
for x in "$CT/$(slug "$L")" "$E"; do
  [ -d "$x" ] || die "the entry $x should exist"
  jq -r '.sandbox.filesystem.allowRead[]' <<<"$SL" | grep -qxF "$x" || die "allowRead should hold $x: $(jq -c .sandbox.filesystem.allowRead <<<"$SL")"
done
# The gate's profile: nothing created, nothing opened.
CT2="$WORK/claude-tmp2"; mkdir -p "$CT2"
SB=$(LEAN_CLAUDE_TMP="$CT2" bash "$TOOLKIT_DIR/lean/sandbox.sh" "$P" --seatbelt 2>/dev/null) || die "sandbox.sh --seatbelt"
[ -z "$(ls -A "$CT2")" ] || die "--seatbelt must not create an entry: $(ls "$CT2")"
grep -qF "(deny file-read* (subpath \"$CT2\"))" <<<"$SB" || die "the gate's profile should deny the temp folder"
pass "the project's entry is created (700) and re-opened, also by its resolved name; other entries stay denied; the gate's profile is unchanged"

echo "2. stdout in the entry, under sandbox-exec"
if command -v sandbox-exec >/dev/null 2>&1 && sandbox-exec -p '(version 1)(allow default)' true 2>/dev/null; then
  # The settings' read rules as Claude Code's runtime applies them (allowRead wins inside denyRead).
  prof() {
    printf '(version 1)\n(allow default)\n'
    jq -r '.sandbox.filesystem.denyRead[] | "(deny file-read* (subpath \(tojson)))"' <<<"$1"
    [ "$2" = deny ] || jq -r '.sandbox.filesystem.allowRead[] | "(allow file-read* (subpath \(tojson)))"' <<<"$1"
  }
  mkdir -p "$E/session/tasks"; out="$E/session/tasks/x.output"
  sandbox-exec -p "$(prof "$S" deny)" cat "$P/src/a.txt" > "$out" 2>&1
  grep -q 'stdout: Operation not permitted' "$out" || die "test setup: with the entry denied, cat should fail on its stdout: $(cat "$out")"
  sandbox-exec -p "$(prof "$S" open)" cat "$P/src/a.txt" > "$out" 2>&1 || die "cat with the settings' rules: $(cat "$out")"
  [ "$(cat "$out")" = a ] || die "cat should write to its stdout: $(cat "$out")"
  if command -v node >/dev/null 2>&1; then
    sandbox-exec -p "$(prof "$S" open)" node -e 'console.log("n")' > "$out" 2>&1 || die "node with the settings' rules: $(head -c 300 "$out")"
    [ "$(cat "$out")" = n ] || die "node should write to its stdout: $(head -c 300 "$out")"
  fi
  sandbox-exec -p "$(prof "$S" open)" cat "$CT/other-project/s/x.txt" > "$out" 2>&1 && die "another project's entry must stay unreadable"
  pass "cat and node write to a stdout file in the entry; another entry stays unreadable"
else
  echo "  skip sandbox-exec not available"
fi

echo "3. lean/adapters/claude.sh"
cat > "$WORK/bin/claude" <<SH
#!/usr/bin/env bash
: > "$WORK/claude.called"; echo '{}'
SH
chmod +x "$WORK/bin/claude"; printf 'sys\n' > "$WORK/sys.md"
adapt() { PATH="$WORK/bin:$PATH" bash "$1/adapters/claude.sh" "$P" headless - "$WORK/sys.md" go "$WORK/r.json" 2>"$WORK/err"; }
rm -f "$WORK/claude.called"
adapt "$TOOLKIT_DIR/lean" || die "adapter: $(cat "$WORK/err")"
[ -e "$WORK/claude.called" ] || die "the adapter should start claude"
cp -R "$TOOLKIT_DIR/lean" "$WORK/lean-stub"
printf '#!/usr/bin/env bash\necho %s\n' "'{\"sandbox\":{\"filesystem\":{\"denyRead\":[\"$CT\"],\"allowRead\":[\"$P\"]}}}'" > "$WORK/lean-stub/sandbox.sh"
rm -f "$WORK/claude.called"
adapt "$WORK/lean-stub" && die "the adapter must refuse settings that leave the entry denied"
[ -e "$WORK/claude.called" ] && die "claude must not start when the entry stays denied"
grep -q "Bash output would be unreadable" "$WORK/err" || die "the refusal should say why: $(cat "$WORK/err")"
pass "the adapter refuses (before claude) settings that deny the temp folder without re-opening the entry"

echo "PASS ($PASS checks)"
