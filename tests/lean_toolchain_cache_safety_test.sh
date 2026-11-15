#!/usr/bin/env bash
# lean_toolchain_cache_safety_test.sh — what the harness does with the toolchain cache folders
# outside the sandbox, and who may read or write them (lean/lib.sh lean_cache_prepare,
# lean_cargo_target, lean_seed, lean_toolchain_env, lean_toolchain_setup, lean_sandboxed;
# lean/sandbox.sh; the claude and codex adapters). A temp HOME holding a fake key, stub `claude`
# and `codex`, no network, no Docker, no model; the real ~/.ssh and $HOME are never touched.
#
#   1. Seeding (H1): a cargo target is cloned only from the project's own real target/ (or the
#      workspace root's, not $HOME or /): never from a .cargo/config target-dir, $CARGO_TARGET_DIR,
#      ~/.cargo/config.toml, a target/ that is a link or that holds a link leaving it.
#   2. Planted links (M1): the cache root, the project's folder, its subfolders and the seed
#      destinations are refused when they are links (nothing written through them), not ours or
#      not mode 700.
#   3. Isolation (M2): the gate reads and writes only its own folder (not another project's, not
#      the sessions'), and can't create anything in the cache root; the Claude settings deny the
#      root and open only the session folder (the default root lies outside allowWrite); the
#      Codex table denies the root and writes only the session folder.
#   4. The gate trusts nothing a session wrote (M3): the gate and the sessions use different
#      folders (GOCACHE, CARGO_TARGET_DIR, pytest's cache_dir), and Go never reuses a cached test
#      result in the gate (GOFLAGS -count=1).
#   5. Low findings: no clone across file systems (L1); a seed racing another leaves no nested
#      copy or litter (L2); lean.toolchain_env takes only cache/temp-folder names and checks
#      paths inside tokens (L3); lean.cache "run" is a fresh folder per run, unsandboxed too, and
#      `$LEAN_CACHEX` is refused with a clear message (L4).
#   6. Second review: the gate (only) gets a Gradle init script forcing Test tasks to run,
#      never written through a link (N-M1); a project folder named with a space, a double quote
#      and a backslash works (sanitized cache folder name; pytest in the gate) (N-M2); a
#      workspace member's sessions are not seeded from the workspace root's target/ (N-L1); no
#      pytest cache_dir option with `no:cacheprovider` (N-L2); a bad root names
#      `cache-clear --all` (N-L3); a session folder chmod-ed by a session is set back to 700,
#      a link still refused (N-L4).
#   7. Claude sessions (Claude Code makes Edit deny rules denyWrite, which wins over allowWrite):
#      no Read/Edit rule holds the session folder (the per-user cache dir and the cache root are
#      carved into rules for their other entries), the folder allowed as given and resolved; in
#      a seatbelt emulation of those semantics the session writes and reads $LEAN_CACHE while the
#      gate's folder, other projects', the root, the per-user cache dir and $HOME stay denied; with
#      the old rendering the env file's probe falls back to the session TMPDIR (LEAN_CACHE_FALLBACK);
#      TMPPREFIX stays in the session TMPDIR (a zsh here-document works). Fix round: the gate's
#      folder gets Read/Edit rules (path and /**) whether it exists or not, every project's gate/
#      a glob rule, the adapter creates the gate's folder; the cache root's pieces in both
#      spellings (/var and /private/var); realpath and BSD mkdir -p of $LEAN_CACHE work (Claude
#      Code allows folder metadata) while listing the folders above it stays denied.
#
# Usage: bash tests/lean_toolchain_cache_safety_test.sh   (exits non-zero on the first failure;
# KEEP_GOING=1 reports them all)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UTMP=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}")
WORK="$(cd "$(mktemp -d "${UTMP%/}/lean-tcs-test.XXXXXX")" && pwd -P)"
cleanup() { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0 FAILED=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
# KEEP_GOING=1 reports every failure instead of stopping at the first (to see a base fail everywhere).
die() { echo "  FAIL $1" >&2; FAILED=$((FAILED + 1)); [ "${KEEP_GOING:-}" = 1 ] || exit 1; }
g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

mkdir -p "$WORK/home/.ssh" "$WORK/home/Documents" "$WORK/bin" "$WORK/socks"
echo FAKE-PRIVATE-KEY > "$WORK/home/.ssh/id_ed25519"
export HOME="$WORK/home" LEAN_CACHE_BASE="$WORK/cache-base" LEAN_CLAUDE_TMP="$WORK/no-claude-tmp" \
  LEAN_DB_SOCK_DIR="$WORK/socks" GIT_CONFIG_GLOBAL=/dev/null CARGO_HOME="$WORK/home/.cargo"
unset LEAN_GATE_UNSANDBOXED GOCACHE GOFLAGS UV_CACHE_DIR XDG_CACHE_HOME BUNDLE_USER_HOME PIP_CACHE_DIR \
  TMPPREFIX JAVA_TOOL_OPTIONS MAVEN_ARGS GRADLE_USER_HOME CARGO_TARGET_DIR CARGO_BUILD_TARGET_DIR PYTEST_ADDOPTS
ROOT="$WORK/cache-base/lean-cache"

SBX=0
if command -v sandbox-exec >/dev/null 2>&1 && sandbox-exec -p '(version 1)(allow default)' true 2>/dev/null; then SBX=1; fi

# project <dir> [<harness.json>] — a git project with a .harness.json.
project() {
  local def='{"verify_command":"true"}'
  mkdir -p "$1"
  printf '%s\n' "${2:-$def}" > "$1/.harness.json"
  [ -d "$1/.git" ] || { g -C "$1" init -q && g -C "$1" add -A && g -C "$1" commit -qm base; } >/dev/null 2>&1 || die "git setup in $1"
}
# setup <project> <tmpdir> <role> — lean_toolchain_setup: the cache folder, then NAME=value lines.
setup() { bash -c '. "$1/lean/lib.sh"; lean_toolchain_setup "$2" "$3" "$4" || exit 1; printf "%s\n" "$LEAN_CACHE_PATH" ${LEAN_TOOLCHAIN_ENV[@]+"${LEAN_TOOLCHAIN_ENV[@]}"}' _ "$TOOLKIT_DIR" "$@"; }
# gate <project> <command> — lean_sandbox_prepare + lean_sandboxed, as the gate runs its suite.
gate() { bash -c '. "$1/lean/lib.sh"; lean_sandbox_prepare "$2" >/dev/null 2>&1; lean_sandboxed "$2" "$3"' _ "$TOOLKIT_DIR" "$1" "$2"; }
val() { sed -n "s/^$1=//p" <<<"$2" | tail -1; }
# no_key — the fake key was copied nowhere under the cache base.
no_key() { ! grep -rqs FAKE-PRIVATE-KEY "$WORK/cache-base" 2>/dev/null || die "$1: the fake key was copied into the cache: $(grep -rls FAKE-PRIVATE-KEY "$WORK/cache-base")"; }
mkt() { mktemp -d "$WORK/t.XXXX"; }
cargo_project() { mkdir -p "$1"; printf '[package]\nname = "p"\nversion = "0.1.0"\n' > "$1/Cargo.toml"; project "$1"; }

echo "1. cargo seeding reads only the project's own target (H1)"
P="$HOME/dev/proj"; cargo_project "$P"
mkdir -p "$P/.cargo"; printf '[build]\ntarget-dir = "%s"\n' "$HOME/.ssh" > "$P/.cargo/config.toml"
lines=$(setup "$P" "$(mkt)" codex 2>&1) || die "setup with a target-dir: $lines"
no_key "a .cargo/config.toml target-dir naming ~/.ssh"
case "$(val CARGO_TARGET_DIR "$lines")" in "$(head -1 <<<"$lines")"/cargo-target) ;; *) die "the redirect should stay in the cache: $lines" ;; esac
lines=$(setup "$P" "$(mkt)" gate 2>&1) || die "gate setup with a target-dir: $lines"
no_key "the gate with a target-dir naming ~/.ssh"
rm -rf "$P/.cargo"
# $CARGO_TARGET_DIR (a shared target) and ~/.cargo/config.toml's target-dir: other projects' artefacts.
mkdir -p "$WORK/shared/debug"; echo FAKE-PRIVATE-KEY > "$WORK/shared/debug/libother.rlib"
lines=$(CARGO_TARGET_DIR="$WORK/shared" setup "$P" "$(mkt)" codex 2>&1) || die "setup with CARGO_TARGET_DIR: $lines"
no_key "\$CARGO_TARGET_DIR"
mkdir -p "$HOME/.cargo"; printf '[build]\ntarget-dir = "%s"\n' "$WORK/shared" > "$HOME/.cargo/config.toml"
lines=$(setup "$P" "$(mkt)" gate 2>&1) || die "setup with ~/.cargo/config.toml: $lines"
no_key "~/.cargo/config.toml's target-dir"
[ -n "$(val CARGO_TARGET_DIR "$lines")" ] || die "a target-dir in ~/.cargo/config.toml lies outside the project: the gate should redirect"
rm -f "$HOME/.cargo/config.toml"
# target/ a link, or holding a link that leaves it.
ln -s "$HOME/.ssh" "$P/target"
lines=$(setup "$P" "$(mkt)" codex 2>&1) || die "setup with target/ a link: $lines"
no_key "target/ a link to ~/.ssh"
rm "$P/target"; mkdir -p "$P/target/debug"; ln -s "$HOME/.ssh" "$P/target/debug/keys"; echo ok > "$P/target/debug/x"
lines=$(setup "$P" "$(mkt)" codex 2>&1) || die "setup with a link in target/: $lines"
c=$(head -1 <<<"$lines")
[ ! -e "$c/cargo-target/debug/keys" ] && [ ! -L "$c/cargo-target/debug/keys" ] || die "a link leaving target/ must not be cloned"
rm "$P/target/debug/keys"
# The project's own target/: seeded (Codex), once.
lines=$(setup "$P" "$(mkt)" codex 2>&1) || die "setup with a plain target/: $lines"
c=$(head -1 <<<"$lines")
[ -f "$c/cargo-target/debug/x" ] || die "the project's own target/ should seed the Codex cache: $(ls -la "$c" 2>&1)"
# A workspace root at $HOME is not one: its target is never read.
mkdir -p "$HOME/target/debug"; echo FAKE-PRIVATE-KEY > "$HOME/target/debug/k"
printf '[workspace]\nmembers = ["m"]\n' > "$HOME/Cargo.toml"
M="$HOME/m"; cargo_project "$M"
t=$(bash -c '. "$1/lean/lib.sh"; lean_cargo_target "$2"' _ "$TOOLKIT_DIR" "$M")
case "$t" in *"$HOME/target") die "the workspace walk must stop below \$HOME: $t" ;; esac
lines=$(setup "$M" "$(mkt)" codex 2>&1) || die "setup under a \$HOME workspace: $lines"
no_key "a workspace root at \$HOME"
rm -rf "$HOME/target" "$HOME/Cargo.toml"
pass "no clone from a target-dir, \$CARGO_TARGET_DIR, ~/.cargo/config.toml, a linked target/ or a \$HOME workspace; the project's own target/ seeds"

echo "2. planted links and foreign modes (M1)"
G="$WORK/dev/gradle"; mkdir -p "$G"; touch "$G/build.gradle"; project "$G"
mkdir -p "$HOME/.gradle/wrapper/dists/gradle-8/x"; echo dist > "$HOME/.gradle/wrapper/dists/gradle-8/x/f"
lines=$(setup "$G" "$(mkt)" session 2>&1) || die "gradle setup: $lines"
gc=$(head -1 <<<"$lines")
[ -f "$gc/gradle/wrapper/dists/gradle-8/x/f" ] || die "the wrapper dists should be seeded: $(ls -laR "$gc" 2>&1 | head)"
# A session replaces gradle/ with a link to a folder under $HOME: nothing is written there.
rm -rf "$gc/gradle"; ln -s "$HOME/Documents" "$gc/gradle"
out=$(setup "$G" "$(mkt)" session 2>&1) && die "a planted link in the cache folder should refuse the setup: $out"
[ -z "$(ls -A "$HOME/Documents")" ] || die "the setup wrote through a planted link: $(ls -R "$HOME/Documents")"
grep -q 'link' <<<"$out" || die "the refusal should name the link: $out"
rm "$gc/gradle"; mkdir -m 700 "$gc/gradle"; ln -s "$HOME/Documents" "$gc/gradle/wrapper"
out=$(setup "$G" "$(mkt)" session 2>&1) && die "a planted link deeper in the cache folder should refuse: $out"
[ -z "$(ls -A "$HOME/Documents")" ] || die "the setup wrote through gradle/wrapper: $(ls -R "$HOME/Documents")"
rm -rf "$gc/gradle"
# The cargo seed destination planted as a link.
C="$WORK/dev/crate"; cargo_project "$C"; mkdir -p "$C/target/debug"; echo ok > "$C/target/debug/x"
lines=$(setup "$C" "$(mkt)" codex 2>&1) || die "crate setup: $lines"
cc=$(head -1 <<<"$lines"); rm -rf "$cc/cargo-target"; ln -s "$HOME/Documents" "$cc/cargo-target"
out=$(setup "$C" "$(mkt)" codex 2>&1) && die "a planted cargo-target link should refuse: $out"
[ -z "$(ls -A "$HOME/Documents")" ] || die "the cargo seed wrote through a link: $(ls -R "$HOME/Documents")"
rm "$cc/cargo-target"
# The root and the project's folder: links, foreign modes.
lines=$(setup "$C" "$(mkt)" codex 2>&1) || die "setup after the cleanup: $lines"
chmod 755 "$ROOT"
out=$(setup "$C" "$(mkt)" codex 2>&1) && die "a cache root not mode 700 must be refused: $out"
grep -q 'mode 700' <<<"$out" || die "the mode refusal should say why: $out"
chmod 700 "$ROOT"
pdir=$(dirname "$cc"); chmod 750 "$pdir"
out=$(setup "$C" "$(mkt)" codex 2>&1) && die "a project cache folder not mode 700 must be refused: $out"
chmod 700 "$pdir"
mv "$ROOT" "$WORK/root.real"; mkdir -m 700 "$WORK/elsewhere"; ln -s "$WORK/elsewhere" "$ROOT"
out=$(setup "$C" "$(mkt)" codex 2>&1) && die "a cache root that is a link must be refused: $out"
[ -z "$(ls -A "$WORK/elsewhere")" ] || die "nothing may be created through a linked root: $(ls "$WORK/elsewhere")"
rm "$ROOT"; mv "$WORK/root.real" "$ROOT"
pass "links in the cache (gradle/, gradle/wrapper, cargo-target, the root) refused, nothing written through them; foreign modes refused"

echo "3. per-project isolation (M2)"
A="$WORK/dev/a"; B="$WORK/dev/b"; project "$A"; project "$B"
sa=$(setup "$A" "$(mkt)" session | head -1) && ga=$(setup "$A" "$(mkt)" gate | head -1) || die "setup a"
sb=$(setup "$B" "$(mkt)" session | head -1) && gb=$(setup "$B" "$(mkt)" gate | head -1) || die "setup b"
[ "$sa" != "$ga" ] || die "the gate and the sessions must not share a folder: $sa"
for f in "$sa" "$ga" "$sb" "$gb"; do echo FAKE-OTHER > "$f/probe"; done
if [ "$SBX" = 1 ]; then
  out=$(gate "$A" 'echo own > "$LEAN_CACHE/w" && cat "$LEAN_CACHE/w" && cd "$LEAN_CACHE" && /bin/realpath .' 2>&1) || die "the gate should use its own folder: $out"
  grep -qx "$ga" <<<"$out" || die "the gate's LEAN_CACHE should be its own folder $ga: $out"
  for f in "$sb/probe" "$gb/probe" "$sa/probe"; do
    gate "$A" "cat '$f'" >/dev/null 2>&1 && die "the gate of a must not read $f"
    gate "$A" "echo x >> '$f'" >/dev/null 2>&1 && die "the gate of a must not write $f"
  done
  gate "$A" "ls '$ROOT'" >/dev/null 2>&1 && die "the gate must not list the cache root"
  gate "$A" "mkdir '$ROOT/planted'" >/dev/null 2>&1 && die "the gate must not create folders in the cache root"
  [ ! -e "$ROOT/planted" ] || die "a folder was planted in the cache root"
fi
# Claude: the root denied, the session folder opened; the default root lies outside allowWrite.
cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$STUB_ARGV"; echo '{}'
SH
chmod +x "$WORK/bin/claude"
export STUB_ARGV="$WORK/claude.argv"
out=$(cd "$A" && PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/adapters/claude.sh" "$A" headless - /dev/null hi "$WORK/res.json" 2>&1) || die "claude.sh: $out"
settings=$(tr '\0' '\n' < "$STUB_ARGV" | grep -A1 -x -- --settings | tail -1)
jq -e --arg r "$ROOT" '.sandbox.filesystem.denyRead | index($r)' <<<"$settings" >/dev/null || die "claude: denyRead should hold the cache root $ROOT"
jq -e --arg s "$sa" '(.sandbox.filesystem.allowRead | index($s)) and (.sandbox.filesystem.allowWrite | index($s))' <<<"$settings" >/dev/null \
  || die "claude: the session folder should be in allowRead and allowWrite: $(jq -c .sandbox.filesystem <<<"$settings" | cut -c1-400)"
jq -e --arg g "$ga" --arg p "$(dirname "$sa")" '[.sandbox.filesystem.allowRead[], .sandbox.filesystem.allowWrite[]] | any(. == $g or . == $p)' <<<"$settings" >/dev/null \
  && die "claude: neither the gate folder nor the project's cache folder may be opened"
def=$(env -u LEAN_CACHE_BASE bash "$TOOLKIT_DIR/lean/sandbox.sh" "$A" 2>/dev/null) || die "sandbox.sh (default base)"
droot="$(cd "$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || echo /nonexistent)" 2>/dev/null && pwd -P)/lean-cache"
jq -e --arg r "$droot" '.sandbox.filesystem.denyRead | index($r)' <<<"$def" >/dev/null || die "sandbox.sh: the default cache root $droot should be read-denied"
jq -e --arg r "$droot" '.sandbox.filesystem.allowWrite | any(. as $w | ($r + "/") | startswith($w + "/"))' <<<"$def" >/dev/null \
  && die "sandbox.sh: the default cache root must not lie under an allowWrite entry (sessions could plant folders there): $(jq -c .sandbox.filesystem.allowWrite <<<"$def")"
# Codex: the root denied, the session folder written.
cat > "$WORK/bin/codex" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo "codex-cli 0.0.0-stub"; exit 0; }
mkdir -p "$CALLS"; n=$(ls "$CALLS" | grep -c '\.argv$')
printf '%s\0' "$@" > "$CALLS/$n.${1:-x}.argv"
case "${1:-}" in debug) echo '[]'; exit 0 ;; sandbox) ;; *) exit 0 ;; esac
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift
canary="$5"; chmod 000 "$canary"; chmod 300 "${11}" "${12}"   # the root and project folder: `deny`
rc=0; env CODEX_SANDBOX=seatbelt HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 CODEX_NETWORK_PROXY_ACTIVE=1 "$@" || rc=$?
chmod 700 "$canary" "${11}" "${12}"; exit "$rc"
SH
chmod +x "$WORK/bin/codex"
export CALLS="$WORK/calls"
out=$(cd "$A" && PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/adapters/codex.sh" "$A" check - /dev/null - 2>&1) || die "codex check: $out"
fs=$(tr '\0' '\n' < "$(ls "$CALLS"/*.sandbox.argv | tail -1)" | sed -n 's/^permissions\.lean\.filesystem=//p')
grep -qF "$(jq -Rn --arg k "$ROOT" '$k')=\"deny\"" <<<"$fs" || die "codex: the cache root should be denied: $fs"
grep -qF "$(jq -Rn --arg k "$sa" '$k')=\"write\"" <<<"$fs" || die "codex: the session folder should be a write entry: $fs"
grep -qF "$(jq -Rn --arg k "$ga" '$k')=" <<<"$fs" && die "codex: the gate folder must not be listed: $fs"
pass "the gate uses only its own folder; Claude and Codex deny the cache root and open only the session folder"

echo "4. the gate trusts nothing a session wrote (M3)"
sl=$(setup "$A" "$(mkt)" session) && gl=$(setup "$A" "$(mkt)" gate) || die "setup"
for n in GOCACHE LEAN_CACHE UV_CACHE_DIR XDG_CACHE_HOME; do
  [ "$(val "$n" "$sl")" != "$(val "$n" "$gl")" ] || die "$n must differ between the sessions and the gate: $(val "$n" "$gl")"
done
case "$(val GOCACHE "$gl")" in "$ga"/*) ;; *) die "the gate's GOCACHE should be in its own folder: $(val GOCACHE "$gl")" ;; esac
case " $(val GOFLAGS "$gl") " in *" -count=1 "*) ;; *) die "the gate's GOFLAGS should hold -count=1: '$(val GOFLAGS "$gl")'" ;; esac
case " $(val GOFLAGS "$sl") " in *" -count=1 "*) die "sessions keep Go's test cache: '$(val GOFLAGS "$sl")'" ;; esac
case "$(val PYTEST_ADDOPTS "$gl")" in *"cache_dir=$ga/pytest"*) ;; *) die "the gate's pytest cache should be its own: '$(val PYTEST_ADDOPTS "$gl")'" ;; esac
gl=$(GOFLAGS=-mod=mod setup "$A" "$(mkt)" gate) || die "setup"
[ "$(val GOFLAGS "$gl")" = "-mod=mod -count=1" ] || die "a caller's GOFLAGS should be kept: $(val GOFLAGS "$gl")"
if [ "$SBX" = 1 ]; then
  out=$(gate "$A" 'echo "$GOFLAGS|$GOCACHE"' 2>&1) || die "gate: $out"
  [ "$out" = "-count=1|$ga/go-build" ] || die "the gate's commands: $out"
fi
pass "separate session and gate folders; -count=1 and pytest's cache_dir in the gate"

echo "5. low findings"
# L1: another file system (lean_dev differs): no clone, cold start.
L1="$WORK/dev/l1"; cargo_project "$L1"; mkdir -p "$L1/target/debug"; echo ok > "$L1/target/debug/x"
lines=$(bash -c '. "$1/lean/lib.sh"; lean_dev() { case "$1" in *target*) echo 1 ;; *) echo 2 ;; esac; }
  lean_toolchain_setup "$2" "$3" codex || exit 1; printf "%s\n" "$LEAN_CACHE_PATH"' _ "$TOOLKIT_DIR" "$L1" "$(mkt)" 2>&1) || die "setup (l1): $lines"
[ ! -e "$(head -1 <<<"$lines")/cargo-target" ] || die "a target on another file system must not be seeded (cp -c would copy it whole)"
# L2: the destination appears while cloning (another setup won): no nested copy, no litter.
L2="$WORK/dev/l2"; cargo_project "$L2"; mkdir -p "$L2/target/debug"; echo ok > "$L2/target/debug/x"
lines=$(bash -c '. "$1/lean/lib.sh"; cp() { command cp "$@"; local d; for d in "$LEAN_CACHE_PATH_HINT"/cargo-target; do mkdir -p "$d/debug"; echo theirs > "$d/debug/x"; done; }
  export LEAN_CACHE_PATH_HINT; LEAN_CACHE_PATH_HINT="$(lean_cache_dir "$2")/session"
  lean_toolchain_setup "$2" "$3" codex || exit 1; printf "%s\n" "$LEAN_CACHE_PATH"' _ "$TOOLKIT_DIR" "$L2" "$(mkt)" 2>&1) || die "setup (l2): $lines"
c=$(head -1 <<<"$lines")
[ "$(cat "$c/cargo-target/debug/x")" = theirs ] || die "the first seed should stay"
[ -z "$(find "$c/cargo-target" -mindepth 1 -maxdepth 1 ! -name debug)" ] || die "a nested seed was left: $(ls -a "$c/cargo-target")"
[ -z "$(find "$c" -maxdepth 1 -name '*seed*')" ] || die "seed litter left: $(ls -a "$c")"
# L3: only cache and temp-folder names; paths inside tokens.
K="$WORK/dev/knob"
okk() { printf '%s\n' "$1" > "$K/.harness.json"; out=$(setup "$K" "$(mkt)" gate 2>&1) || die "lean.toolchain_env $1 should pass: $out"; }
bad() {
  printf '%s\n' "$1" > "$K/.harness.json"
  out=$(setup "$K" "$(mkt)" gate 2>&1) && die "lean.toolchain_env $1 should be refused: $out"
  grep -q "$2" <<<"$out" || die "lean.toolchain_env $1: the refusal should say '$2': $out"
}
project "$K"
okk '{"lean":{"toolchain_env":{"JEST_CACHE":"$LEAN_CACHE/jest","npm_config_cache":"${LEAN_CACHE}/npm","TURBO_CACHE_DIR":"./.turbo"}}}'
for n in HTTPS_PROXY https_proxy ALL_PROXY RUSTC RUSTC_WORKSPACE_WRAPPER CARGO_BUILD_RUSTC CARGO_HOME CARGO_TARGET_DIR \
         GIT_DIR JAVA_TOOL_OPTIONS MAVEN_ARGS GRADLE_USER_HOME GOCACHE GOFLAGS UV_CACHE_DIR XDG_CACHE_HOME CC NODE_OPTIONS; do
  bad "{\"lean\":{\"toolchain_env\":{\"$n\":\"x\"}}}" "can't be set there"
done
bad "{\"lean\":{\"toolchain_env\":{\"X_CACHE\":\"-I$HOME/.ssh\"}}}" "outside the cache"
bad '{"lean":{"toolchain_env":{"X_CACHE":"@/etc/hosts"}}}' "outside the cache"
bad '{"lean":{"toolchain_env":{"X_CACHE":"--x=-/etc"}}}' "outside the cache"
bad '{"lean":{"toolchain_env":{"X_CACHE":"$LEAN_CACHEX"}}}' 'LEAN_CACHE}'
# L4: lean.cache "run": a fresh folder per run, unsandboxed too, removed after.
R="$WORK/dev/run"; project "$R" '{"verify_command":"true","lean":{"cache":"run"}}'
r1=$(LEAN_GATE_UNSANDBOXED=1 gate "$R" 'echo "$LEAN_CACHE"' 2>&1) && r2=$(LEAN_GATE_UNSANDBOXED=1 gate "$R" 'echo "$LEAN_CACHE"' 2>&1) || die "unsandboxed run mode: $r1 $r2"
[ "$r1" != "$r2" ] || die "lean.cache run: each unsandboxed run needs a fresh folder: $r1"
[ ! -e "$r1" ] || die "lean.cache run: the unsandboxed run's folder should be removed: $r1"
# A run TMPDIR inside Claude Code's temp folder (a leader run from Claude Code): run mode still works.
mkdir -p "$WORK/ctmp"; ctmp=$(cd "$WORK/ctmp" && pwd -P)
out=$(LEAN_CLAUDE_TMP="$ctmp" TMPDIR="$ctmp/" LEAN_GATE_UNSANDBOXED=1 gate "$R" 'echo "$LEAN_CACHE"' 2>&1) || die "run mode with TMPDIR in Claude's temp folder: $out"
pass "no cross-volume clone; no nested seed; names allowlisted, paths in tokens checked; run mode fresh per run"

echo "6. second review: Gradle in the gate, odd folder names, seeds, pytest, refusals, repairs"
PYTEST=$(command -v pytest 2>/dev/null || true)
PY=$(command -v python3 2>/dev/null || true)
# N-M1, N3-L1: the gate's Gradle init script (test tasks never UP-TO-DATE, never from cache), written
# outside the sandbox and never through a link; the sessions get none.
lines=$(setup "$G" "$(mkt)" gate 2>&1) || die "gradle gate setup: $lines"
gg=$(head -1 <<<"$lines"); init="${gg:?}/gradle/init.d/lean-rerun-tests.gradle"
[ "$(val GRADLE_USER_HOME "$lines")" = "$gg/gradle" ] || die "the gate's GRADLE_USER_HOME should be its own: $lines"
[ -f "$init" ] && [ ! -L "$init" ] || die "the gate should get $init: $(ls -laR "$gg/gradle" 2>&1 | head)"
grep -q 'withType(org.gradle.api.tasks.testing.AbstractTestTask)' "$init" && ! grep -q 'withType(Test)' "$init" && grep -q 'upToDateWhen { false }' "$init" && grep -q 'cacheIf { false }' "$init" \
  || die "the init script should force Test tasks to run: $(cat "$init")"
lines=$(setup "$G" "$(mkt)" session 2>&1) || die "gradle session setup: $lines"
[ ! -e "$(head -1 <<<"$lines")/gradle/init.d" ] || die "sessions get no init.d: $(ls -la "$(head -1 <<<"$lines")/gradle/init.d")"
rm -f "${init:?}"; ln -s "$HOME/Documents/evil.gradle" "$init"
lines=$(setup "$G" "$(mkt)" gate 2>&1) || die "gate setup over a linked init script: $lines"
[ -f "$init" ] && [ ! -L "$init" ] && [ -z "$(ls -A "$HOME/Documents")" ] || die "the init script must replace a link, not write through it: $(ls -la "$init" "$HOME/Documents")"
rm -rf "${gg:?}/gradle/init.d"; ln -s "$HOME/Documents" "$gg/gradle/init.d"
out=$(setup "$G" "$(mkt)" gate 2>&1) && die "a linked init.d should refuse the gate: $out"
grep -q 'link' <<<"$out" && [ -z "$(ls -A "$HOME/Documents")" ] || die "a linked init.d: refused by name, nothing written: $out $(ls "$HOME/Documents")"
rm -f "${gg:?}/gradle/init.d"
# N-M2: a project folder named with a space, a double quote and a backslash.
Q="$WORK/dev/My Pro\"j\\ect"; mkdir -p "$Q"; touch "$Q/pom.xml" "$Q/build.gradle"; project "$Q"
for who in gate session codex; do
  lines=$(setup "$Q" "$(mkt)" "$who" 2>&1) || die "setup ($who) for a folder named 'My Pro\"j\\ect': $lines"
  qc=$(head -1 <<<"$lines")
  case "$qc" in *[[:space:]\"\'\\]*) die "$who: the cache path must hold no whitespace, quote or backslash: $qc" ;; esac
  case "$(basename "$(dirname "$qc")")" in My_Pro_j_ect-*) ;; *) die "$who: the cache folder should be the sanitized name plus the hash: $qc" ;; esac
  for w in $(val MAVEN_ARGS "$lines"); do case "$w" in -D*) ;; *) die "$who: MAVEN_ARGS splits into a stray word '$w': $(val MAVEN_ARGS "$lines")" ;; esac; done
  [ "$who" != gate ] || [ -z "$PY" ] || [ "$("$PY" -c 'import shlex,sys; print(len(shlex.split(sys.argv[1])))' "$(val PYTEST_ADDOPTS "$lines")")" = 2 ] \
    || die "$who: PYTEST_ADDOPTS should split into -o and cache_dir=...: $(val PYTEST_ADDOPTS "$lines")"
done
if [ "$SBX" = 1 ]; then
  out=$(gate "$Q" 'echo w > "$LEAN_CACHE/w" && cat "$LEAN_CACHE/w"' 2>&1) && [ "$(tail -1 <<<"$out")" = w ] || die "the gate in 'My Pro\"j\\ect': $out"
  if [ -n "$PYTEST" ]; then
    printf 'def test_ok():\n    assert True\n' > "$Q/test_ok.py"
    out=$(gate "$Q" 'pytest -q test_ok.py' 2>&1) || die "pytest in the gate in 'My Pro\"j\\ect': $out"
  fi
fi
# N-L1: a workspace member's session cache is never seeded from the workspace root's target/
# (other members' artefacts); the gate's still is.
W="$WORK/dev/ws"; mkdir -p "$W/target/debug"; echo member-artefact > "$W/target/debug/other"
printf '[workspace]\nmembers = ["m"]\n' > "$W/Cargo.toml"; cargo_project "$W/m"
for who in session codex; do
  lines=$(setup "$W/m" "$(mkt)" "$who" 2>&1) || die "workspace member setup ($who): $lines"
  [ "$(val CARGO_TARGET_DIR "$lines")" = "$(head -1 <<<"$lines")/cargo-target" ] || die "$who: a member builds in the cache: $lines"
  [ ! -e "$(head -1 <<<"$lines")/cargo-target/debug/other" ] || die "$who: the session cache must not be seeded from the workspace root's target/"
done
lines=$(setup "$W/m" "$(mkt)" gate 2>&1) || die "workspace member setup (gate): $lines"
[ -f "$(head -1 <<<"$lines")/cargo-target/debug/other" ] || die "the gate's cache should still be seeded from the workspace root's target/: $(ls -laR "$(head -1 <<<"$lines")" | head)"
# N-L2: no `-o cache_dir=` when the project's pytest config turns the cache plugin off.
Y="$WORK/dev/nocache"; project "$Y"
[ -n "$(val PYTEST_ADDOPTS "$(setup "$Y" "$(mkt)" gate)")" ] || die "the gate should set PYTEST_ADDOPTS by default"
for f in pytest.ini pyproject.toml setup.cfg tox.ini; do
  case "$f" in pytest.ini) h='[pytest]' ;; pyproject.toml) h='[tool.pytest.ini_options]' ;; *) h='[tool:pytest]' ;; esac
  printf '%s\naddopts = "-p no:cacheprovider"\n' "$h" > "$Y/$f"
  lines=$(setup "$Y" "$(mkt)" gate 2>&1) || die "setup with $f: $lines"
  [ -z "$(val PYTEST_ADDOPTS "$lines")" ] || die "$f turning the cache plugin off: no cache_dir option: $(val PYTEST_ADDOPTS "$lines")"
  rm -f "${Y:?}/${f:?}"
done
lines=$(PYTEST_ADDOPTS='-p no:cacheprovider' setup "$Y" "$(mkt)" gate 2>&1) || die "setup with the caller's no:cacheprovider: $lines"
[ -z "$(val PYTEST_ADDOPTS "$lines")" ] || die "the caller's no:cacheprovider: no cache_dir option: $(val PYTEST_ADDOPTS "$lines")"
if [ "$SBX" = 1 ] && [ -n "$PYTEST" ]; then
  printf '[pytest]\naddopts = -p no:cacheprovider --strict-config\nfilterwarnings = error\n' > "$Y/pytest.ini"
  printf 'def test_ok():\n    assert True\n' > "$Y/test_ok.py"
  out=$(gate "$Y" 'pytest -q test_ok.py' 2>&1) || die "pytest with no:cacheprovider and --strict-config in the gate: $out"
fi
# N-L3: a bad cache root names cache-clear --all; a bad project folder plain cache-clear.
chmod 755 "$ROOT"
out=$(setup "$C" "$(mkt)" codex 2>&1) && die "a cache root not mode 700 must be refused: $out"
grep -q 'cache-clear --all starts it afresh' <<<"$out" || die "the root's refusal should name cache-clear --all: $out"
chmod 700 "$ROOT"; chmod 750 "$pdir"
out=$(setup "$C" "$(mkt)" codex 2>&1) && die "a project cache folder not mode 700 must be refused: $out"
grep -q 'cache-clear starts it afresh' <<<"$out" || die "the project folder's refusal should name cache-clear: $out"
chmod 700 "$pdir"
# N-L4: the sessions' leaf folder chmod-ed by a session is repaired; a link or the gate's is not.
sc="${pdir:?}/session"; chmod 755 "$sc"
for m in 755 600 000 300 500; do   # N3-L2: modes without owner x (600, 000) too
  chmod "$m" "$sc"
  out=$(setup "$C" "$(mkt)" codex 2>&1) || { chmod 700 "$sc"; die "a session folder chmod-ed to $m should be repaired: $out"; }
  [ "$(stat -f %Lp "$sc" 2>/dev/null || stat -c %a "$sc")" = 700 ] || { chmod 700 "$sc"; die "the session folder chmod-ed to $m should be mode 700 again"; }
done
mv "$sc" "$WORK/session.real"; mkdir -m 755 "$WORK/elsewhere2"; ln -s "$WORK/elsewhere2" "$sc"
out=$(setup "$C" "$(mkt)" session 2>&1) && die "a session folder replaced by a link must be refused: $out"
grep -q 'link' <<<"$out" && [ -z "$(ls -A "$WORK/elsewhere2")" ] || die "a linked session folder: refused, nothing written: $out"
[ "$(stat -f %Lp "$WORK/elsewhere2" 2>/dev/null || stat -c %a "$WORK/elsewhere2")" = 755 ] || die "the repair must not chmod a linked session folder's target"
rm -f "${sc:?}"; mv "$WORK/session.real" "$sc"
setup "$C" "$(mkt)" gate >/dev/null 2>&1 || die "gate setup for $C"
chmod 755 "$pdir/gate"
out=$(setup "$C" "$(mkt)" gate 2>&1) && die "the gate's folder is never repaired (no session can write it): $out"
chmod 700 "$pdir/gate"
pass "Gradle init script in the gate only, never through a link; odd folder names; member sessions not seeded from the workspace; no:cacheprovider; cache-clear --all named; session folder mode repaired"

echo "7. Claude sessions write and read their own cache folder; the rest stays closed"
# Claude Code turns every Edit deny rule into a sandbox denyWrite entry, and denyWrite wins over
# allowWrite: an `Edit(/<per-user cache dir>/**)` rule made `touch "$LEAN_CACHE/x"` fail in a
# real session. The per-user cache dir is emulated by a folder named through a link (as
# /var/folders/... names /private/var/folders/...), holding another app's cache and the cache
# root. claude_profile turns the session settings into a seatbelt profile with Claude Code's
# documented precedence (allowRead over denyRead and Read rules; writes only in the working
# directory, /dev and allowWrite; denyWrite and Edit rules over allowWrite), so the old rendering
# fails here the way the real session did. Like Claude Code's own macOS profile builder (2.1.325:
# `(allow file-read-metadata (vnode-type DIRECTORY))` after the read rules whenever a read is
# denied), folders' metadata stays readable: realpath works, listing a denied folder doesn't.
mkdir -p "$WORK/ucache-real/C/com.other.app"; ln -s "$WORK/ucache-real" "$WORK/ucache"
echo FAKE-APP-CACHE > "$WORK/ucache-real/C/com.other.app/data"
UC="$WORK/ucache/C" UCR="$WORK/ucache-real/C"
CROOT="$UCR/lean-cache"
# rforms <path> — the path, then its resolved form (a missing one through its parent) when it differs.
rforms() {
  local r
  r=$(/bin/realpath "$1" 2>/dev/null) || { r=$(/bin/realpath "$(dirname "$1")" 2>/dev/null) && r="$r/$(basename "$1")"; } || r=""
  printf '%s\n' "$1"; [ -z "$r" ] || [ "$r" = "$1" ] || printf '%s\n' "$r"
}
# rule_paths <settings> <Read|Edit> — the absolute paths of the permission deny rules of that
# kind, without a trailing /** (rules with another glob are left out).
rule_paths() {
  jq -r --arg k "$2" '.permissions.deny[] | select(startswith($k + "(/"))
    | ltrimstr($k + "(/") | rtrimstr(")") | rtrimstr("/**") | select(test("[*?\\[]") | not)' <<<"$1"
}
# sb_rule <action> — one seatbelt rule per path on stdin, as written and resolved.
sb_rule() { local p f; while IFS= read -r p; do [ -z "$p" ] || rforms "$p" | while IFS= read -r f; do printf '(%s (subpath "%s"))\n' "$1" "$f"; done; done; }
# claude_profile <settings> <cwd> — the user temp dir's allowWrite entry stands for the session
# TMPDIR only ($stmp): this test's folders (the emulated per-user cache dir among them) live in
# the user temp dir, while the real per-user cache dir lies beside it.
claude_profile() {
  echo '(version 1)(allow default)'
  { jq -r '.sandbox.filesystem.denyRead[]' <<<"$1"; rule_paths "$1" Read; } | sb_rule 'deny file-read*'
  jq -r '.sandbox.filesystem.allowRead[]' <<<"$1" | sb_rule 'allow file-read*'
  echo '(allow file-read-metadata (vnode-type DIRECTORY))'
  echo '(deny file-write*)'
  { printf '%s\n' "$2" /dev; jq -r --arg u "${UTMP%/}" --arg s "$stmp" '.sandbox.filesystem.allowWrite[] | if . == $u then $s else . end' <<<"$1"; } | sb_rule 'allow file-write*'
  { jq -r '.sandbox.filesystem.denyWrite[]' <<<"$1"; rule_paths "$1" Edit; } | sb_rule 'deny file-write*'
}
D="$WORK/dev/d"; E="$WORK/dev/e"; project "$D"; project "$E"
sess() { LEAN_CACHE_BASE="$UC" LEAN_USER_CACHE="$UC" setup "$@"; }
sd=$(sess "$D" "$(mkt)" session | head -1) && gd=$(sess "$D" "$(mkt)" gate | head -1) \
  && se=$(sess "$E" "$(mkt)" session | head -1) || die "setup in the emulated per-user cache dir"
case "$sd" in "$CROOT"/*) ;; *) die "the session folder should be resolved, in $CROOT: $sd" ;; esac
for f in "$gd" "$se"; do echo FAKE-OTHER > "$f/probe"; done
# The interactive mode execs the stub, so the session TMPDIR (the fallback's home) outlives claude.sh.
out=$(cd "$D" && LEAN_CACHE_BASE="$UC" LEAN_USER_CACHE="$UC" PATH="$WORK/bin:$PATH" \
  bash "$TOOLKIT_DIR/lean/adapters/claude.sh" "$D" interactive - /dev/null hi < /dev/null 2>&1) || die "claude.sh: $out"
settings=$(tr '\0' '\n' < "$STUB_ARGV" | grep -A1 -x -- --settings | tail -1)
hook=$(jq -r '.hooks.SessionStart[-1].hooks[0].command' <<<"$settings")
envf="$WORK/claude-env"; : > "$envf"
CLAUDE_ENV_FILE="$envf" /bin/sh -c "$hook" || die "the SessionStart hook: $hook"
stmp=$(sed -n 's/^export TMPDIR=//p' "$envf" | head -1); stmp="${stmp%/}"
case "$stmp" in */lean-session.*) ;; *) die "the hook should export the session TMPDIR: $(head -3 "$envf")" ;; esac
cleanup_stmp() { [ -z "${stmp:-}" ] || { chmod -R u+w "$stmp" 2>/dev/null; rm -rf "$stmp"; }; cleanup; }
trap cleanup_stmp EXIT
# The rendering: the folder in allowRead and allowWrite, resolved (/private/var/...) and in its
# /var/... spelling; no Read/Edit rule over it in any spelling, the link's included (the root and
# the per-user cache dir are carved: the gate's folder, the other project's, the other app's
# cache, each its own rule); the root and the per-user cache dir stay whole in denyRead.
sd_link="$UC/lean-cache/${sd#"$CROOT"/}"
for k in allowRead allowWrite; do
  jq -e --arg s "$sd" --arg v "${sd#/private}" --arg k "$k" '.sandbox.filesystem[$k] | index($s) and index($v)' <<<"$settings" >/dev/null \
    || die "claude: $k should hold the session folder resolved and as /var/...: $(jq -c --arg k "$k" '.sandbox.filesystem[$k]' <<<"$settings")"
done
# holds <path> <dir...> — prints <path> when it is one of the dirs or holds one.
holds() { local p="$1" d; shift; for d in "$@"; do case "$d/" in "$p"/*) echo "$p"; return ;; esac; done; }
for k in Read Edit; do
  held=$(rule_paths "$settings" "$k" | while IFS= read -r p; do holds "$p" "$sd" "${sd#/private}" "$sd_link"; done)
  [ -z "$held" ] || die "claude: a $k deny rule holds the session folder (Claude Code makes Edit rules denyWrite, which wins over allowWrite): $held"
  for p in "$gd" "$(dirname "$se")" "$UCR/com.other.app"; do
    rule_paths "$settings" "$k" | grep -qxF "$p" || die "claude: $p should keep a $k deny rule"
  done
done
for p in "$CROOT" "$UC"; do
  jq -e --arg p "$p" '.sandbox.filesystem.denyRead | index($p)' <<<"$settings" >/dev/null || die "claude: denyRead should hold $p whole"
done
# L1: the cache root's pieces (the gate's folder, the other project's) also in the /var spelling.
case "$CROOT" in /private/*) ;; *) die "the emulated cache root should resolve under /private: $CROOT" ;; esac
for k in Read Edit; do
  for p in "${gd#/private}" "$(dirname "${se#/private}")" "$gd"; do
    jq -e --arg r "$k(/$p/**)" --arg b "$k(/$p)" '.permissions.deny | index($r) and index($b)' <<<"$settings" >/dev/null \
      || die "claude: $k deny rules for $p and $p/** expected"
  done
done
# M1: every project's gate/ as a glob in both spellings, which never matches a session folder.
for r in "$CROOT" "${CROOT#/private}"; do
  for k in Read Edit; do
    jq -e --arg r "$k(/$r/*/gate/**)" '.permissions.deny | index($r)' <<<"$settings" >/dev/null || die "claude: the glob rule $k(/$r/*/gate/**) expected"
  done
done
globs=$(jq -r '.permissions.deny[] | select(test("^(Read|Edit)\\(/")) | sub("^(Read|Edit)\\(/"; "") | rtrimstr(")") | select(test("[*?\\[]"))
  | gsub("\\."; "\\.") | gsub("\\*\\*"; "\u0001") | gsub("\\*"; "[^/]*") | gsub("\u0001"; ".*")' <<<"$settings")
for f in "$sd" "${sd#/private}" "$sd/x" "${sd#/private}/x"; do
  while IFS= read -r g; do [ -z "$g" ] || ! printf '%s\n' "$f" | grep -qE "^$g\$" || die "claude: the glob rule $g holds the session folder ($f)"; done <<<"$globs"
done
jq -e --arg r "$UCR" --arg l "$UC" '.sandbox.filesystem.allowWrite | any(. == $r or . == $l or . == ($r + "/lean-cache") or . == ($l + "/lean-cache"))' <<<"$settings" >/dev/null \
  && die "claude: neither the per-user cache dir nor the cache root may be writable"
# M1: with the gate's folder missing (a session before the first gate run), sandbox.sh still
# names it (path and /**, both spellings); claude.sh creates it (mode 700) before rendering.
mv "$gd" "$WORK/gate.away"
ms=$(LEAN_CACHE_BASE="$UC" LEAN_USER_CACHE="$UC" bash "$TOOLKIT_DIR/lean/sandbox.sh" "$D" --cache "$sd" 2>&1) || die "sandbox.sh --cache with no gate folder: $ms"
for p in "$gd" "${gd#/private}"; do
  for k in Read Edit; do
    jq -e --arg r "$k(/$p/**)" --arg b "$k(/$p)" '.permissions.deny | index($r) and index($b)' <<<"$ms" >/dev/null \
      || die "claude: a missing gate folder still needs $k rules for $p and $p/**"
  done
done
out=$(cd "$D" && LEAN_CACHE_BASE="$UC" LEAN_USER_CACHE="$UC" PATH="$WORK/bin:$PATH" \
  bash "$TOOLKIT_DIR/lean/adapters/claude.sh" "$D" headless - /dev/null hi "$WORK/res-gate.json" < /dev/null 2>&1) || die "claude.sh with no gate folder: $out"
[ -d "$gd" ] && [ ! -L "$gd" ] && [ "$(stat -f %Lp "$gd" 2>/dev/null || stat -c %a "$gd")" = 700 ] || die "claude.sh should create the gate's folder (mode 700) before the session"
rmdir "$gd" && mv "$WORK/gate.away" "$gd" || die "restoring the gate's folder"
# The fallback lines: the probe, the session TMPDIR's lean-cache otherwise.
grep -qF ".lean-write-probe" "$envf" && grep -qx 'export LEAN_CACHE_FALLBACK=1' "$envf" \
  || die "the env file should hold the probe and the fallback: $(cat "$envf")"
if [ "$SBX" = 1 ]; then
  prof=$(claude_profile "$settings" "$D")
  inbox() { sandbox-exec -p "$prof" /bin/bash -c ". '$envf'; $1" 2>&1; }
  # (`mkdir`, not BSD `mkdir -p`: that one mkdir()s every level from /, and the per-user cache
  # dir above the folder is denied; Go's MkdirAll, Python's makedirs and Node start from the
  # folder and work.)
  out=$(cd "$D" && inbox 'printf "%s\n" "$LEAN_CACHE" "${LEAN_CACHE_FALLBACK:-0}"; touch "$LEAN_CACHE/x" && echo hi > "$LEAN_CACHE/x" && cat "$LEAN_CACHE/x"; mkdir "$GOCACHE" && echo go > "$GOCACHE/f" && cat "$GOCACHE/f" && rm -r "$GOCACHE"')
  [ "$out" = "$(printf '%s\n' "$sd" 0 hi go)" ] || die "in the emulated Claude sandbox, the session should write and read its own cache folder (no fallback): $out"
  # I2: realpath(3) and BSD mkdir -p of $LEAN_CACHE (folder metadata above it readable).
  out=$(cd "$D" && inbox '/bin/realpath "$LEAN_CACHE" && mkdir -p "$LEAN_CACHE/a/b" && cd "$LEAN_CACHE" && /bin/pwd -P && rm -r "$LEAN_CACHE/a"')
  [ "$out" = "$(printf '%s\n' "$sd" "$sd")" ] || die "in the emulated Claude sandbox, realpath, mkdir -p and pwd -P of \$LEAN_CACHE should work: $out"
  for c in "ls '$UC'" "ls '$UCR'" "ls '$CROOT'" "ls '$gd'" "cat '$gd/probe'" "cat '$se/probe'" "cat '$UCR/com.other.app/data'" \
           "echo x > '$gd/w'" "echo x > '$se/w'" "mkdir '$CROOT/planted'" "echo x > '$UCR/planted'" "echo x > '$UCR/com.other.app/w'" \
           "echo x > '$(dirname "$sd")/w'" "ls '$(dirname "$sd")'" "mkdir \"\$HOME/planted\""; do
    out=$(cd "$D" && inbox "$c") && die "the emulated Claude sandbox should deny: $c ($out)"
  done
  [ ! -e "$CROOT/planted" ] && [ ! -e "$UCR/planted" ] && [ ! -e "$HOME/planted" ] || die "something was planted"
  # TMPPREFIX (zsh's here-documents) is in the session TMPDIR, writable: a here-document works.
  if [ -x /bin/zsh ]; then
    out=$(cd "$D" && sandbox-exec -p "$prof" /bin/zsh -fc ". '$envf'; case \"\$TMPPREFIX\" in \"\$TMPDIR\"*) ;; *) echo bad-prefix ;; esac; cat <<EOF
heredoc
EOF
touch \"\$LEAN_CACHE/z\" && echo \"\${LEAN_CACHE_FALLBACK:-0}\"" 2>&1)
    [ "$out" = "$(printf 'heredoc\n0')" ] || die "zsh in the emulated sandbox: TMPPREFIX in TMPDIR, a here-document, the cache writable: $out"
  fi
  # The old rendering (an Edit rule over the cache root) is refused by the same emulation: the
  # write fails...
  old=$(jq -c --arg r "$CROOT" '.permissions.deny += ["Edit(/" + $r + "/**)"]' <<<"$settings")
  oprof=$(claude_profile "$old" "$D")
  out=$(cd "$D" && sandbox-exec -p "$oprof" /bin/bash -c "touch '$sd/y'" 2>&1) && die "the emulation should deny a write under an Edit rule (else it proves nothing): $out"
  # ...and the fail-safe moves every cache variable to the session TMPDIR's lean-cache, which
  # the session can write, and says so.
  out=$(cd "$D" && sandbox-exec -p "$oprof" /bin/bash -c ". '$envf'; printf '%s\n' \"\$LEAN_CACHE\" \"\$GOCACHE\" \"\$XDG_CACHE_HOME\" \"\${LEAN_CACHE_FALLBACK:-0}\"; echo f > \"\$LEAN_CACHE/x\" && cat \"\$LEAN_CACHE/x\"" 2>&1)
  [ "$out" = "$(printf '%s\n' "$stmp/lean-cache" "$stmp/lean-cache/go-build" "$stmp/lean-cache/xdg" 1 f)" ] \
    || die "the fallback should point the caches at the session TMPDIR when the cache folder can't be written: $out"
  [ "$(/bin/ls -A "$stmp/lean-cache")" = x ] || die "the fallback folder should hold only what the session wrote: $(/bin/ls -A "$stmp/lean-cache")"
fi
# lean.cache "run": the folder is already the session TMPDIR's: no probe.
R="$WORK/dev/r"; project "$R" '{"verify_command":"true","lean":{"cache":"run"}}'
out=$(cd "$R" && LEAN_CACHE_BASE="$UC" LEAN_USER_CACHE="$UC" PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/adapters/claude.sh" "$R" headless - /dev/null hi "$WORK/res.json" 2>&1) || die "claude.sh (run): $out"
rs=$(tr '\0' '\n' < "$STUB_ARGV" | grep -A1 -x -- --settings | tail -1)
jq -r '.hooks.SessionStart[-1].hooks[0].command' <<<"$rs" | grep -q 'lean-write-probe' && die "lean.cache run: no probe expected"
# sandbox.sh refuses --cache with --seatbelt, a missing folder and one under $HOME.
bash "$TOOLKIT_DIR/lean/sandbox.sh" "$D" --seatbelt --cache "$sd" >/dev/null 2>&1 && die "sandbox.sh: --cache with --seatbelt must be refused"
bash "$TOOLKIT_DIR/lean/sandbox.sh" "$D" --cache "$WORK/nope" >/dev/null 2>&1 && die "sandbox.sh: a missing --cache folder must be refused"
mkdir -p "$HOME/c"; bash "$TOOLKIT_DIR/lean/sandbox.sh" "$D" --cache "$HOME/c" >/dev/null 2>&1 && die "sandbox.sh: a --cache folder under \$HOME must be refused"
no_key "claude sessions"
pass "Claude: the session folder written and read (no Read/Edit rule over it, both spellings allowed); the gate's, other projects', the root and the per-user cache dir denied; fail-safe to the session TMPDIR; TMPPREFIX in TMPDIR"

if [ "$FAILED" = 0 ]; then echo "lean_toolchain_cache_safety_test: $PASS passed"; else echo "lean_toolchain_cache_safety_test: $PASS passed, $FAILED failure(s)"; fi
[ "$FAILED" = 0 ]
