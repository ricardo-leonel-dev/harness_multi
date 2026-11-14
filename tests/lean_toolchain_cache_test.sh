#!/usr/bin/env bash
# lean_toolchain_cache_test.sh — the toolchain caches of the lean sandboxes (lean/lib.sh
# lean_cache_dir, lean_cache_prepare, lean_toolchain_env, lean_toolchain_setup): one cache folder
# per project outside $HOME, writable by the gate's profile and both session sandboxes, and the
# variables that point the toolchains there. A temp HOME outside /private/tmp (the gate's profile
# can write anywhere in /private/tmp, which would hide failures), stub `claude` / `codex`, no
# network, no Docker, no model. Empirical toolchain checks skip when the toolchain is missing.
#
#   1. The always-safe set (GOCACHE, UV_CACHE_DIR, XDG_CACHE_HOME, BUNDLE_USER_HOME,
#      PIP_CACHE_DIR, TMPPREFIX ...) reaches the gate's commands (lean_sandboxed), the Claude
#      session (claude.sh's SessionStart hook; the cache in allowWrite) and the Codex session
#      (shell_environment_policy.set; the cache a `write` entry, checked by the self-check),
#      pointing into the cache folder or TMPDIR, never under $HOME. A caller's value inside the
#      project is kept. lean.cache "run" and an invalid lean.cache.
#   2. The cache folder: under the per-user cache dir, mode 700, one per project (gate/ and
#      session/ in it); refused when it is a link, foreign-owned or under $HOME (nothing created
#      there). The gate can write its folder, not $HOME/.cargo or $HOME/Library/Caches/go-build
#      nor another project's, nor read ~/.ssh. run.sh cache-clear.
#   3. Cargo, workspace member (ws/member, target ws/target): fails under the gate's profile
#      without the redirect, passes through lean_sandboxed; the clone seed recompiles 0 crates.
#   4. Cargo, Codex model (the gate's profile plus a directory-unlink deny in the project):
#      fails in target/, passes with the Codex redirect (CARGO_TARGET_DIR in the cache).
#   5. Java: File.createTempFile fails under the profile without JAVA_TOOL_OPTIONS, passes with
#      it when a pom.xml is present; no JAVA_TOOL_OPTIONS without a JVM build file. Gradle and
#      Maven variables, the Gradle wrapper dists cloned once.
#   6. zsh: with /private/tmp write-denied, a here-document fails without TMPPREFIX and passes
#      with it.
#   7. LEAN_TEST_REAL_CODEX=1 only: the real `codex sandbox` (no model, temp CODEX_HOME) with the
#      adapter's flags: the cache is writable and ~/.cargo is not; `mkdir d && rmdir d` in the
#      project is reported with and without the `**` deny globs (lean/SECURITY.md "Codex sessions").
#   8. Postgres: initdb/start/query pass in the gate's profile; with (deny ipc-sysv-shm) they fail
#      on shmget even with shared_memory_type=mmap; a server started outside is reachable from
#      the profile through its socket and 127.0.0.1 (a free port, never 54329/5439/3001).
#   9. lean.toolchain_env: $LEAN_CACHE / $TMPDIR expanded; secret-looking or reserved names,
#      other `$`, `~`, `..` and paths outside the cache/TMPDIR/project refused (the gate exits
#      125); a changed .harness.json still trips the pin.
#  10. LEAN_HOME_READ no longer opens Go's build caches; cargo, npm and python tests still run in
#      the gate.
#
# Usage: bash tests/lean_toolchain_cache_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="$HOME"
UTMP=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}")
WORK="$(cd "$(mktemp -d "${UTMP%/}/lean-tc-test.XXXXXX")" && pwd -P)"
PG_STOP=""
cleanup() {
  [ -z "$PG_STOP" ] || eval "$PG_STOP" >/dev/null 2>&1
  chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0 SKIP=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  skip $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }
g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

# Toolchains, found before HOME moves (rustup's proxies need the real RUSTUP_HOME).
CARGO=$(rustup which cargo 2>/dev/null || command -v cargo 2>/dev/null || true)
RUSTC=$(rustup which rustc 2>/dev/null || command -v rustc 2>/dev/null || true)
JAVA=""; JAVAC=""
if command -v javac >/dev/null 2>&1 && javac -version >/dev/null 2>&1 && java -version >/dev/null 2>&1; then
  JAVA=$(command -v java) JAVAC=$(command -v javac)
fi
ZSH=$(command -v zsh 2>/dev/null || true)
PGBIN=""
for d in "$(dirname "$(command -v initdb 2>/dev/null || echo /nonexistent/x)")" /opt/homebrew/opt/postgresql@17/bin /opt/homebrew/opt/postgresql@16/bin /usr/local/opt/postgresql@17/bin; do
  [ -x "$d/initdb" ] && [ -x "$d/pg_ctl" ] && [ -x "$d/psql" ] && { PGBIN="$d"; break; }
done
NPM=$(command -v npm 2>/dev/null || true)
PY=$(command -v python3 2>/dev/null || true)
REAL_CODEX=$(command -v codex 2>/dev/null || true)

mkdir -p "$WORK/home/.ssh" "$WORK/home/.cargo" "$WORK/home/Library/Caches/go-build" "$WORK/bin" "$WORK/socks"
echo private-key > "$WORK/home/.ssh/id"
export HOME="$WORK/home" LEAN_CACHE_BASE="$WORK/cache-base" LEAN_CLAUDE_TMP="$WORK/no-claude-tmp" \
  LEAN_DB_SOCK_DIR="$WORK/socks" GIT_CONFIG_GLOBAL=/dev/null CARGO_HOME="$WORK/cargo-home"
unset LEAN_GATE_UNSANDBOXED GOCACHE UV_CACHE_DIR XDG_CACHE_HOME BUNDLE_USER_HOME PIP_CACHE_DIR TMPPREFIX \
  JAVA_TOOL_OPTIONS MAVEN_ARGS GRADLE_USER_HOME CARGO_TARGET_DIR CARGO_BUILD_TARGET_DIR
[ -z "$RUSTC" ] || export RUSTC

SBX=0
if command -v sandbox-exec >/dev/null 2>&1 && sandbox-exec -p '(version 1)(allow default)' true 2>/dev/null; then SBX=1; fi

# project <dir> [<harness.json>] — a git project with a .harness.json.
project() {
  local def='{"verify_command":"true"}'
  mkdir -p "$1"
  printf '%s\n' "${2:-$def}" > "$1/.harness.json"
  [ -d "$1/.git" ] || { g -C "$1" init -q && g -C "$1" add -A && g -C "$1" commit -qm base; } >/dev/null 2>&1 || die "git setup in $1"
}
# gate <project> <command> — lean_sandbox_prepare + lean_sandboxed, as the gate runs its suite.
gate() { bash -c '. "$1/lean/lib.sh"; lean_sandbox_prepare "$2" >/dev/null 2>&1; lean_sandboxed "$2" "$3"' _ "$TOOLKIT_DIR" "$1" "$2"; }
# raw <project> <extra rules> <command> [NAME=value...] — the gate's profile and a run TMPDIR of
# its own, without lean_sandboxed's toolchain variables or cache folder (unless given).
raw() {
  local p="$1" extra="$2" cmd="$3" rt prof; shift 3
  prof=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$p" --seatbelt 2>/dev/null) || die "sandbox.sh --seatbelt $p"
  rt=$(cd "$(mktemp -d "$WORK/r.XXXX")" && pwd -P)
  (cd "$p" && env TMPDIR="$rt/" "$@" sandbox-exec -p "$prof
(allow file-write* (subpath \"$rt\"))
$extra" bash -c "$cmd")
}
# tc <project> <tmpdir> [codex] — lean_toolchain_setup's cache folder, then its NAME=value lines.
tc() { bash -c '. "$1/lean/lib.sh"; lean_toolchain_setup "$2" "$3" ${4:+"$4"} || exit 1; printf "%s\n" "$LEAN_CACHE_PATH" "${LEAN_TOOLCHAIN_ENV[@]}"' _ "$TOOLKIT_DIR" "$@"; }
val() { sed -n "s/^$1=//p" <<<"$2" | tail -1; }

P="$WORK/dev/app"; project "$P"
CDIR=$(bash -c '. "$1/lean/lib.sh"; lean_cache_dir "$2"' _ "$TOOLKIT_DIR" "$P")
GCACHE="$CDIR/gate" SCACHE="$CDIR/session"   # the gate's and the sessions' folders
SAFE="GOCACHE UV_CACHE_DIR XDG_CACHE_HOME BUNDLE_USER_HOME PIP_CACHE_DIR"
# check_safe <env lines> <cache> <tmpdir> <where> — the always-safe set, under the cache / TMPDIR.
check_safe() {
  local n v
  for n in $SAFE; do
    v=$(val "$n" "$1")
    case "$v/" in "$2"/*) ;; *) die "$4: $n should point into the cache folder $2: '$v'" ;; esac
  done
  v=$(val TMPPREFIX "$1"); case "$v" in "${3%/}"/zsh) ;; *) die "$4: TMPPREFIX should be <TMPDIR>/zsh: '$v' (TMPDIR $3)" ;; esac
  [ "$(val NG_CLI_ANALYTICS "$1")" = false ] || die "$4: NG_CLI_ANALYTICS=false missing"
  [ "$(val LEAN_CACHE "$1")" = "$2" ] || die "$4: LEAN_CACHE should be $2"
  for n in $SAFE TMPPREFIX LEAN_CACHE; do
    v=$(val "$n" "$1"); case "$v/" in "$HOME"/*|"$REAL_HOME"/*) die "$4: $n points under \$HOME: $v" ;; esac
  done
}

echo "1. the variables reach the gate and both session adapters"
out=$(gate "$P" 'env; echo "TMPDIR_IS=$TMPDIR"' 2>&1) || die "gate env: $out"
run_tmp=$(sed -n 's/^TMPDIR_IS=//p' <<<"$out")
check_safe "$out" "$GCACHE" "$run_tmp" gate
[ -d "$GCACHE" ] || die "the gate should create its cache folder $GCACHE"
# A caller's own value inside the project is kept; one elsewhere is replaced.
out=$(GOCACHE="$P/.gocache" UV_CACHE_DIR="$REAL_HOME/.cache/uv" gate "$P" 'env' 2>&1) || die "gate env (own values): $out"
[ "$(val GOCACHE "$out")" = "$P/.gocache" ] || die "a GOCACHE inside the project should be kept: $(val GOCACHE "$out")"
[ "$(val UV_CACHE_DIR "$out")" = "$GCACHE/uv" ] || die "a UV_CACHE_DIR outside the project should be replaced: $(val UV_CACHE_DIR "$out")"
# Claude: a stub records argv; the SessionStart hook is run as Claude Code would.
cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$STUB_ARGV"; env -0 > "$STUB_ARGV.env"; echo '{}'
SH
chmod +x "$WORK/bin/claude"
export STUB_ARGV="$WORK/claude.argv"
out=$(cd "$P" && PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/adapters/claude.sh" "$P" headless - /dev/null hi "$WORK/res.json" 2>&1) || die "claude.sh: $out"
settings=$(tr '\0' '\n' < "$STUB_ARGV" | grep -A1 -x -- --settings | tail -1)
jq -r '.sandbox.filesystem.allowWrite[]' <<<"$settings" | grep -qxF "$SCACHE" || die "claude: allowWrite should hold the session cache: $(jq -c .sandbox.filesystem.allowWrite <<<"$settings")"
hook=$(jq -r '.hooks.SessionStart[-1].hooks[0].command' <<<"$settings")
: > "$WORK/claude.envfile"
CLAUDE_ENV_FILE="$WORK/claude.envfile" sh -c "$hook" || die "claude: the SessionStart hook failed: $hook"
out=$(env -i PATH=/bin:/usr/bin bash -c '. "$1"; env' _ "$WORK/claude.envfile") || die "claude: the env file doesn't source: $(cat "$WORK/claude.envfile")"
check_safe "$out" "$SCACHE" "$(val TMPDIR "$out")" claude
tr '\0' '\n' < "$STUB_ARGV.env" | grep -q '^GOCACHE=' && die "claude: GOCACHE must reach the session's commands only, not Claude Code's process"
# Codex: a stub records argv; `sandbox` runs the self-check as the real one would see it.
cat > "$WORK/bin/codex" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo "codex-cli 0.0.0-stub"; exit 0; }
mkdir -p "$CALLS"; n=$(ls "$CALLS" | grep -c '\.argv$')
printf '%s\0' "$@" > "$CALLS/$n.${1:-x}.argv"
case "${1:-}" in debug) echo '[]'; exit 0 ;; sandbox) ;; *) exit 0 ;; esac
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift
canary="$5"; chmod 000 "$canary"; [ "${STUB_CACHE:-}" != ro ] || chmod 500 "${10}"
# The cache root and the project's cache folder are `deny`: unlistable (still traversable).
[ "${STUB_CACHE:-}" = rootopen ] || chmod 300 "${11}" "${12}"
rc=0; env CODEX_SANDBOX=seatbelt HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 CODEX_NETWORK_PROXY_ACTIVE=1 "$@" || rc=$?
chmod 700 "$canary" "${11}" "${12}"; [ "${STUB_CACHE:-}" != ro ] || chmod 700 "${10}"; exit "$rc"
SH
chmod +x "$WORK/bin/codex"
export CALLS="$WORK/calls"
printf '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n' > "$P/Cargo.toml"
out=$(cd "$P" && PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/adapters/codex.sh" "$P" check - /dev/null - 2>&1) || die "codex check: $out"
f=$(ls "$CALLS"/*.sandbox.argv | tail -1)
args=$(tr '\0' '\n' < "$f")
[ "$(tail -3 <<<"$args" | tr '\n' ' ')" = "$SCACHE $(dirname "$CDIR") $CDIR " ] \
  || die "codex: the self-check should be given the cache folder, the root and the project's folder: $(tail -3 <<<"$args")"
fs=$(sed -n 's/^permissions\.lean\.filesystem=//p' <<<"$args")
grep -qF "$(jq -Rn --arg k "$SCACHE" '$k')=\"write\"" <<<"$fs" || die "codex: the cache should be a write entry: $fs"
tr "," "\n" <<<"$fs" | grep -F "$CDIR" | grep -q '\*' && die "codex: no glob may lie under the cache"
cenv=$(sed -n 's/^shell_environment_policy\.set\.\([A-Z_]*\)=\(".*"\)$/\1 \2/p' <<<"$args" | while read -r n v; do printf '%s=%s\n' "$n" "$(jq -r . <<<"$v")"; done)
ctmp=$(val TMPDIR "$cenv")
check_safe "$cenv" "$SCACHE" "$ctmp" codex
[ "$(val CARGO_TARGET_DIR "$cenv")" = "$SCACHE/cargo-target" ] || die "codex: a cargo project should build in the cache: $(val CARGO_TARGET_DIR "$cenv")"
out=$(gate "$P" 'env' 2>&1); [ -z "$(val CARGO_TARGET_DIR "$out")" ] || die "the gate builds a standalone crate in its own target/: $(val CARGO_TARGET_DIR "$out")"
# The self-check refuses when the cache folder isn't writable.
export STUB_CACHE=ro
out=$(cd "$P" && PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/adapters/codex.sh" "$P" check - /dev/null - 2>&1); rc=$?
unset STUB_CACHE
[ "$rc" = 3 ] && grep -q 'cache folder is not writable' <<<"$out" || die "codex: an unwritable cache should refuse (exit 3): rc=$rc $out"
# ... and when the rest of the cache root stays listable (Codex letting the `write` entry
# re-open more than the session folder, or the root's `deny` not taking effect).
export STUB_CACHE=rootopen
out=$(cd "$P" && PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/adapters/codex.sh" "$P" check - /dev/null - 2>&1); rc=$?
unset STUB_CACHE
[ "$rc" = 3 ] && grep -q 'the rest of the toolchain cache root is readable' <<<"$out" || die "codex: a listable cache root should refuse (exit 3): rc=$rc $out"
rm -f "$P/Cargo.toml"
# lean.cache "run": a folder in the run's TMPDIR; anything else refused.
R="$WORK/dev/runmode"; project "$R" '{"verify_command":"true","lean":{"cache":"run"}}'
out=$(gate "$R" 'env; echo "TMPDIR_IS=$TMPDIR"' 2>&1) || die "gate (lean.cache run): $out"
rt=$(sed -n 's/^TMPDIR_IS=//p' <<<"$out"); rt="${rt%/}"
[ "$(val LEAN_CACHE "$out")" = "$rt/lean-cache" ] || die "lean.cache run: the cache should be in the run's TMPDIR: $(val LEAN_CACHE "$out") vs $rt"
printf '{"verify_command":"true","lean":{"cache":"global"}}\n' > "$R/.harness.json"
out=$(gate "$R" 'echo ran' 2>&1); rc=$?
[ "$rc" = 125 ] && grep -q 'invalid .harness.json::lean.cache' <<<"$out" && ! grep -q '^ran$' <<<"$out" || die "an invalid lean.cache should refuse (125): rc=$rc $out"
pass "the gate, the Claude hook and the Codex profile carry the cache variables (cache or TMPDIR, never \$HOME)"

echo "2. the cache folder"
base=$(cd "$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}")" && pwd -P)
d=$(env -u LEAN_CACHE_BASE bash -c '. "$1/lean/lib.sh"; lean_cache_dir "$2"' _ "$TOOLKIT_DIR" "$P")
case "$d" in "$base"/lean-cache/app-????????????) ;; *) die "the default cache folder should be <user cache dir>/lean-cache/app-<hash>: $d" ;; esac
for x in "$GCACHE" "$CDIR" "$(dirname "$CDIR")"; do
  [ "$(stat -f %Lp "$x" 2>/dev/null || stat -c %a "$x")" = 700 ] || die "$x should be mode 700"
done
Q="$WORK/other/app"; project "$Q"
d2=$(bash -c '. "$1/lean/lib.sh"; lean_cache_dir "$2"' _ "$TOOLKIT_DIR" "$Q")
[ "$d2" != "$CDIR" ] || die "two projects named alike must not share a cache folder"
prep() { bash -c '. "$1/lean/lib.sh"; '"${3:-}"' lean_cache_prepare "$2" "$(lean_cache_base)" "$(lean_cache_dir "$2")/gate"' _ "$TOOLKIT_DIR" "$1" 2>&1; }
mv "$CDIR" "$CDIR.real"; ln -s "$WORK/elsewhere" "$CDIR"; mkdir -p "$WORK/elsewhere"
out=$(prep "$P") && die "a link as the cache folder must be refused"
grep -q 'is a link' <<<"$out" || die "the link refusal should say why: $out"
rm "$CDIR"; mv "$CDIR.real" "$CDIR"
out=$(prep "$P" "" 'lean_owner() { echo 4242; };') && die "a foreign-owned cache folder must be refused"
grep -q 'not owned by uid' <<<"$out" || die "the owner refusal should say why: $out"
out=$(LEAN_CACHE_BASE="$HOME/caches" prep "$P") && die "a cache folder under \$HOME must be refused"
grep -q 'under \$HOME' <<<"$out" || die "the \$HOME refusal should say why: $out"
[ ! -e "$HOME/caches/lean-cache" ] || die "nothing may be created under \$HOME"
ln -s "$HOME" "$WORK/homelink"
out=$(LEAN_CACHE_BASE="$WORK/homelink" prep "$P") && die "a cache folder reaching \$HOME through a link must be refused: $out"
[ ! -e "$HOME/lean-cache" ] || die "nothing may be created under \$HOME through a link"
out=$(LEAN_CACHE_BASE="$P/sub" prep "$P") && die "a cache folder in the project must be refused"
out=$(gate "$P" 'echo ran' 2>&1) || die "the gate after the refusals: $out"
if [ "$SBX" = 1 ]; then
  out=$(gate "$P" 'echo x > "$LEAN_CACHE/w" && cat "$LEAN_CACHE/w"' 2>&1) || die "the gate can't write the cache folder: $out"
  for t in "$HOME/.cargo/x" "$HOME/Library/Caches/go-build/x" "$Q/x"; do
    gate "$P" "echo x > '$t'" >/dev/null 2>&1 && die "the gate must not write $t"
  done
  gate "$P" "cat '$HOME/.ssh/id'" >/dev/null 2>&1 && die "the gate must not read ~/.ssh"
  # Another project's cache folder: not writable from this project's gate.
  bash -c '. "$1/lean/lib.sh"; lean_cache_prepare "$2" "$(lean_cache_base)" "$3/gate"' _ "$TOOLKIT_DIR" "$Q" "$d2" || die "prepare $d2"
  gate "$P" "echo x > '$d2/gate/x'" >/dev/null 2>&1 && die "the gate must not write another project's cache folder"
  pass "per-project, mode 700, refused as a link / foreign-owned / under \$HOME / in the project; the gate writes it, not \$HOME or ~/.ssh"
else
  pass "per-project, mode 700, refused as a link / foreign-owned / under \$HOME / in the project (sandbox-exec unavailable: profile checks skipped)"
fi
out=$(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" cache-clear 2>&1) || die "cache-clear: $out"
[ ! -e "$CDIR" ] || die "cache-clear should remove $CDIR"
out=$(cd "$P" && LEAN_SESSION=1 bash "$TOOLKIT_DIR/lean/run.sh" cache-clear 2>&1) && die "cache-clear inside a session must be refused: $out"
pass "run.sh cache-clear removes the folder (refused inside a session)"

echo "3. cargo, a workspace member"
if [ -z "$CARGO" ] || [ "$SBX" = 0 ]; then skip "cargo or sandbox-exec missing"
else
  WS="$WORK/ws"; M="$WS/member"; mkdir -p "$M/src"
  printf '[workspace]\nmembers = ["member"]\nresolver = "2"\n' > "$WS/Cargo.toml"
  printf '[package]\nname = "member"\nversion = "0.1.0"\nedition = "2021"\n' > "$M/Cargo.toml"
  printf 'pub fn two() -> u32 { 2 }\n#[cfg(test)]\nmod t { #[test] fn two() { assert_eq!(super::two(), 2); } }\n' > "$M/src/lib.rs"
  project "$M"
  [ "$(bash -c '. "$1/lean/lib.sh"; lean_cargo_target "$2"' _ "$TOOLKIT_DIR" "$M")" = "workspace $WS/target" ] || die "lean_cargo_target should find the workspace's target"
  (cd "$M" && "$CARGO" test --offline -q) >/dev/null 2>&1 || die "cargo test outside the sandbox"
  out=$(raw "$M" "" "'$CARGO' test --offline 2>&1") && die "cargo test in a workspace member should fail without the redirect: $out"
  grep -qiE 'not permitted|permission denied' <<<"$out" || die "the workspace failure should be a denied write: $out"
  out=$(gate "$M" "'$CARGO' test --offline 2>&1") || die "cargo test through lean_sandboxed should pass: $out"
  grep -q 'test result: ok' <<<"$out" || die "cargo test output: $out"
  n=$(grep -c 'Compiling' <<<"$out" || true)
  [ "$n" = 0 ] || die "the clone seed should recompile nothing: $n Compiling line(s): $out"
  [ -d "$(bash -c '. "$1/lean/lib.sh"; lean_cache_dir "$2"' _ "$TOOLKIT_DIR" "$M")/gate/cargo-target/debug" ] || die "the cargo target should be seeded in the cache"
  pass "a workspace member's ws/target: fails in the gate's profile alone, passes redirected, 0 crates recompiled"
fi

echo "4. cargo, the Codex model (no directory unlink in the project)"
if [ -z "$CARGO" ] || [ "$SBX" = 0 ]; then skip "cargo or sandbox-exec missing"
else
  C="$WORK/crate"; mkdir -p "$C/src"
  printf '[package]\nname = "crate"\nversion = "0.1.0"\nedition = "2021"\n' > "$C/Cargo.toml"
  printf 'pub fn one() -> u32 { 1 }\n#[cfg(test)]\nmod t { #[test] fn one() { assert_eq!(super::one(), 1); } }\n' > "$C/src/lib.rs"
  printf 'target/\n' > "$C/.gitignore"
  project "$C"
  nounlink="(deny file-write-unlink (require-all (subpath \"$C\") (vnode-type DIRECTORY)))"
  out=$(raw "$C" "$nounlink" "'$CARGO' test --offline 2>&1") && die "cargo test in target/ should fail without folder removal: $out"
  grep -qiE 'not permitted|failed to create directory' <<<"$out" || die "the Codex-model failure should be a denied operation: $out"
  lines=$(tc "$C" "$WORK/codex-tmp" codex) || die "lean_toolchain_setup codex: $lines"
  ccache=$(head -1 <<<"$lines"); ct=$(val CARGO_TARGET_DIR "$lines")
  [ "$ct" = "$ccache/cargo-target" ] || die "codex: CARGO_TARGET_DIR should be in the cache: $ct"
  # The cache root is denied in every profile; the folder is re-opened as lean_sandboxed does.
  out=$(raw "$C" "$nounlink
$(bash -c '. "$1/lean/lib.sh"; lean_cache_rules "$2"' _ "$TOOLKIT_DIR" "$ccache")" "'$CARGO' test --offline 2>&1" CARGO_TARGET_DIR="$ct") || die "cargo test with the Codex redirect should pass: $out"
  grep -q 'test result: ok' <<<"$out" || die "cargo test output: $out"
  pass "Codex model: target/ fails, the cache redirect passes"
fi

echo "5. java, gradle, maven"
J="$WORK/java"; project "$J"
lines=$(tc "$J" /tmp/x) || die "tc $J"
[ -z "$(val JAVA_TOOL_OPTIONS "$lines")" ] || die "no JAVA_TOOL_OPTIONS without a JVM build file"
touch "$J/pom.xml"
lines=$(tc "$J" "$WORK/jt") || die "tc $J"
[ "$(val JAVA_TOOL_OPTIONS "$lines")" = "-Djava.io.tmpdir=$WORK/jt" ] || die "pom.xml: JAVA_TOOL_OPTIONS: $(val JAVA_TOOL_OPTIONS "$lines")"
jc=$(head -1 <<<"$lines")
case "$(val MAVEN_ARGS "$lines")" in "-Dmaven.repo.local=$jc/m2") ;; *) die "pom.xml: MAVEN_ARGS: $(val MAVEN_ARGS "$lines")" ;; esac
lines=$(JAVA_TOOL_OPTIONS=-Xmx1g tc "$J" "$WORK/jt") || die "tc $J"
[ "$(val JAVA_TOOL_OPTIONS "$lines")" = "-Xmx1g -Djava.io.tmpdir=$WORK/jt" ] || die "an existing JAVA_TOOL_OPTIONS should be kept: $(val JAVA_TOOL_OPTIONS "$lines")"
G="$WORK/gradle"; mkdir -p "$G"; touch "$G/build.gradle.kts"; project "$G"
mkdir -p "$HOME/.gradle/caches/modules-2" "$HOME/.gradle/wrapper/dists/gradle-8.0-bin/x" "$HOME/.m2/repository"
echo dist > "$HOME/.gradle/wrapper/dists/gradle-8.0-bin/x/gradle.zip"; echo 'secret=1' > "$HOME/.gradle/gradle.properties"
lines=$(tc "$G" /tmp/x) || die "tc $G"
gc=$(head -1 <<<"$lines")
[ "$(val GRADLE_USER_HOME "$lines")" = "$gc/gradle" ] || die "gradle: GRADLE_USER_HOME: $(val GRADLE_USER_HOME "$lines")"
[ "$(val GRADLE_RO_DEP_CACHE "$lines")" = "$HOME/.gradle/caches" ] || die "gradle: GRADLE_RO_DEP_CACHE: $(val GRADLE_RO_DEP_CACHE "$lines")"
[ -n "$(val JAVA_TOOL_OPTIONS "$lines")" ] || die "gradle: JAVA_TOOL_OPTIONS"
[ -f "$gc/gradle/wrapper/dists/gradle-8.0-bin/x/gradle.zip" ] || die "gradle: wrapper/dists should be seeded"
[ ! -e "$gc/gradle/gradle.properties" ] || die "gradle: gradle.properties (credentials) must not be carried"
lines=$(tc "$J" /tmp/x) || die "tc $J"
case "$(val MAVEN_ARGS "$lines")" in *"-Dmaven.repo.local.tail=$HOME/.m2/repository") ;; *) die "maven: the tail: $(val MAVEN_ARGS "$lines")" ;; esac
if [ -z "$JAVAC" ] || [ "$SBX" = 0 ]; then skip "javac or sandbox-exec missing (java check)"
else
  printf 'public class Tmp { public static void main(String[] a) throws Exception { System.out.println(java.io.File.createTempFile("lean", null)); } }\n' > "$J/Tmp.java"
  (cd "$J" && "$JAVAC" Tmp.java) >/dev/null 2>&1 || die "javac outside the sandbox"
  out=$(raw "$J" "" "'$JAVA' -cp . Tmp 2>&1") && die "File.createTempFile should fail in the profile without JAVA_TOOL_OPTIONS: $out"
  grep -qiE 'not permitted|IOException' <<<"$out" || die "the java failure should be a denied temp file: $out"
  out=$(gate "$J" "'$JAVA' -cp . Tmp 2>&1") || die "File.createTempFile should pass with JAVA_TOOL_OPTIONS: $out"
  pass "java: createTempFile fails without the variable, passes with it"
fi
pass "JAVA_TOOL_OPTIONS only with a JVM build file; Gradle (read-only dependency cache, wrapper dists seeded, no gradle.properties) and Maven (read-only tail)"

echo "6. zsh here-documents"
if [ -z "$ZSH" ] || [ "$SBX" = 0 ]; then skip "zsh or sandbox-exec missing"
else
  notmp='(deny file-write* (subpath "/private/tmp"))'
  heredoc="'$ZSH' -fc 'cat <<EOF
here-ok
EOF'"
  out=$(raw "$P" "$notmp" "$heredoc 2>&1") && die "a zsh here-document should fail with /private/tmp denied and no TMPPREFIX: $out"
  grep -qi 'here document' <<<"$out" || die "the zsh failure should be the here-document temp file: $out"
  out=$(raw "$P" "$notmp" "TMPPREFIX=\"\${TMPDIR%/}/zsh\" $heredoc 2>&1") || die "a zsh here-document should pass with TMPPREFIX: $out"
  grep -qx here-ok <<<"$out" || die "here-document output: $out"
  out=$(gate "$P" "$heredoc" 2>&1) && grep -qx here-ok <<<"$out" || die "the gate's zsh here-document: $out"
  pass "zsh here-documents: fail without TMPPREFIX, pass with it"
fi

echo "7. real codex sandbox (LEAN_TEST_REAL_CODEX=1)"
if [ "${LEAN_TEST_REAL_CODEX:-}" != 1 ] || [ -z "$REAL_CODEX" ]; then skip "LEAN_TEST_REAL_CODEX=1 and codex on PATH needed"
else
  K="$WORK/codexp"; project "$K"
  mkdir -p "$HOME/.codex"
  # The adapter's flags, applied by the real `codex sandbox` (no model), the probe swapped in;
  # STRIP_GLOBS=1 drops the `/**/` deny entries from the filesystem table.
  cat > "$WORK/bin/codex" <<SH
#!/usr/bin/env bash
case "\${1:-}" in sandbox) ;; debug) echo '[]'; exit 0 ;; *) exec "$REAL_CODEX" "\$@" ;; esac
args=(); while [ \$# -gt 0 ] && [ "\$1" != -- ]; do
  a="\$1"
  if [ "\${STRIP_GLOBS:-}" = 1 ]; then case "\$a" in permissions.lean.filesystem=*) a=\$(printf '%s' "\$a" | sed -E 's/,?"[^"]*\/\*\*\/[^"]*"="deny"//g; s/\{,/{/') ;; esac; fi
  case "\$a" in permissions.lean.filesystem=*) printf '%s\n' "\$a" > "\$REAL_OUT.table" ;; esac
  args+=("\$a"); shift
done
shift; cache="\${10}"
CODEX_HOME="$HOME/.codex" "$REAL_CODEX" "\${args[@]}" -- /bin/sh -c '
  (mkdir d && rmdir d) 2>/dev/null && echo "rmdir ok" || echo "rmdir denied"; rm -rf d 2>/dev/null
  (: > "\$1/w" && rm -f "\$1/w") 2>/dev/null && echo "cache ok" || echo "cache denied"
  (mkdir "\$1/d" && rmdir "\$1/d") 2>/dev/null && echo "cache rmdir ok" || echo "cache rmdir denied"; rm -rf "\$1/d" 2>/dev/null
  (: > "\$2/w") 2>/dev/null && echo "home written" || echo "home denied"' sh "\$cache" "$HOME/.cargo" > "\$REAL_OUT" 2>&1
echo LEAN-CODEX-SANDBOX-OK
SH
  chmod +x "$WORK/bin/codex"
  REAL_OUT="$WORK/real.globs" PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/adapters/codex.sh" "$K" check - /dev/null - >/dev/null 2>&1 || die "real codex check (globs)"
  REAL_OUT="$WORK/real.noglobs" STRIP_GLOBS=1 PATH="$WORK/bin:$PATH" bash "$TOOLKIT_DIR/lean/adapters/codex.sh" "$K" check - /dev/null - >/dev/null 2>&1 || die "real codex check (no globs)"
  grep -qF '/**/' "$WORK/real.globs.table" || die "real codex: the adapter's table should hold the ** deny globs"
  grep -qF '/**/' "$WORK/real.noglobs.table" && die "real codex: STRIP_GLOBS should drop the ** deny globs: $(cat "$WORK/real.noglobs.table")"
  for r in globs noglobs; do
    grep -qx 'cache ok' "$WORK/real.$r" || die "real codex ($r): the cache should be writable: $(cat "$WORK/real.$r")"
    grep -qx 'home denied' "$WORK/real.$r" || die "real codex ($r): ~/.cargo must not be writable: $(cat "$WORK/real.$r")"
    grep -qx 'cache rmdir ok' "$WORK/real.$r" || die "real codex ($r): folders in the cache should be removable (cargo builds there): $(cat "$WORK/real.$r")"
  done
  echo "  (real codex, mkdir+rmdir in the project: with the ** deny globs: $(grep -v cache "$WORK/real.globs" | grep rmdir); without: $(grep -v cache "$WORK/real.noglobs" | grep rmdir))"
  pass "real codex sandbox: the cache is writable, ~/.cargo is not"
fi

echo "8. postgres"
if [ -z "$PGBIN" ] || [ "$SBX" = 0 ]; then skip "initdb/pg_ctl/psql or sandbox-exec missing"
else
  free_port() {
    local p
    for p in 55433 55437 55441 55447 55453 55459; do
      ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && { echo "$p"; return 0; }
    done
    return 1
  }
  PORT=$(free_port) || die "no free port for Postgres"
  case "$PORT" in 54329|5439|3001) die "the test must never use the mirror's or the local test ports" ;; esac
  pg_in="trap '\"$PGBIN/pg_ctl\" -D \"\$TMPDIR/pg\" -m immediate stop >/dev/null 2>&1' EXIT
\"$PGBIN/initdb\" -D \"\$TMPDIR/pg\" -A trust -U postgres > \"\$TMPDIR/initdb.log\" 2>&1 || { cat \"\$TMPDIR/initdb.log\"; exit 1; }
\"$PGBIN/pg_ctl\" -D \"\$TMPDIR/pg\" -l \"\$TMPDIR/pg.log\" -w -o \"-p $PORT -k \${TMPDIR%/} -c listen_addresses='' -c shared_memory_type=mmap -c dynamic_shared_memory_type=posix\" start >/dev/null 2>&1 || { cat \"\$TMPDIR/pg.log\"; exit 1; }
\"$PGBIN/psql\" -h \"\${TMPDIR%/}\" -p $PORT -U postgres -Atc 'select 40 + 2' postgres"
  out=$(gate "$P" "$pg_in" 2>&1) || die "initdb/start/query in the gate's profile should pass: $out"
  grep -qx 42 <<<"$out" || die "the query in the gate: $out"
  out=$(raw "$P" "(deny ipc-sysv-shm)" "$pg_in" 2>&1) && die "Postgres must fail without SysV shared memory: $out"
  grep -q 'shmget' <<<"$out" && grep -q 'size=56' <<<"$out" || die "the failure should be shmget(size=56): $out"
  # A server started outside the sandbox, reached from it through its socket and 127.0.0.1.
  "$PGBIN/initdb" -D "$WORK/pgout" -A trust -U postgres >/dev/null 2>&1 || die "initdb outside"
  PG_STOP="'$PGBIN/pg_ctl' -D '$WORK/pgout' -m immediate stop"
  "$PGBIN/pg_ctl" -D "$WORK/pgout" -l "$WORK/pgout.log" -w -o "-p $PORT -k $WORK/socks -c listen_addresses=127.0.0.1" start >/dev/null 2>&1 \
    || die "pg_ctl start outside: $(cat "$WORK/pgout.log")"
  out=$(gate "$P" "'$PGBIN/psql' -h '$WORK/socks' -p $PORT -U postgres -Atc 'select 1' postgres && '$PGBIN/psql' -h 127.0.0.1 -p $PORT -U postgres -Atc 'select 2' postgres" 2>&1) \
    || die "the gate should reach a server started outside: $out"
  [ "$(printf '%s\n' "$out" | tr -d '\r' | paste -sd, -)" = "1,2" ] || die "the queries through the socket and TCP: $out"
  eval "$PG_STOP" >/dev/null 2>&1; PG_STOP=""
  pass "Postgres: runs in the gate, fails on shmget(size=56) without SysV shm, an outside server is reachable"
fi

echo "9. lean.toolchain_env"
T="$WORK/dev/knob"
project "$T" '{"verify_command":"true","lean":{"toolchain_env":{"JEST_CACHE":"--cacheDirectory=$LEAN_CACHE/jest","SCRATCH_TMPDIR":"${TMPDIR}/s:./rel/dir"}}}'
out=$(gate "$T" 'env; echo "TMPDIR_IS=$TMPDIR"' 2>&1) || die "gate with lean.toolchain_env: $out"
tcache=$(val LEAN_CACHE "$out"); ttmp=$(sed -n 's/^TMPDIR_IS=//p' <<<"$out"); ttmp="${ttmp%/}"
[ "$(val JEST_CACHE "$out")" = "--cacheDirectory=$tcache/jest" ] || die "\$LEAN_CACHE should be expanded: $(val JEST_CACHE "$out")"
[ "$(val SCRATCH_TMPDIR "$out")" = "$ttmp/s:./rel/dir" ] || die "\${TMPDIR} should be expanded: $(val SCRATCH_TMPDIR "$out")"
bad() {
  printf '%s\n' "$1" > "$T/.harness.json"
  out=$(gate "$T" 'echo ran' 2>&1); rc=$?
  [ "$rc" = 125 ] && ! grep -qx ran <<<"$out" && grep -q "$2" <<<"$out" || die "lean.toolchain_env $1 should refuse (125, '$2'): rc=$rc $out"
}
bad '{"lean":{"toolchain_env":{"NPM_TOKEN":"x"}}}' "can't be set there"
bad '{"lean":{"toolchain_env":{"DATABASE_URL":"x"}}}' "can't be set there"
bad '{"lean":{"toolchain_env":{"PATH":"/x"}}}' "can't be set there"
bad '{"lean":{"toolchain_env":{"DYLD_INSERT_LIBRARIES":"x"}}}' "can't be set there"
bad '{"lean":{"toolchain_env":{"LEAN_SESSION":"0"}}}' "can't be set there"
bad '{"lean":{"toolchain_env":{"bad-name":"x"}}}' "can't be set there"
bad "{\"lean\":{\"toolchain_env\":{\"X_CACHE\":\"$HOME/.ssh\"}}}" "outside the cache"
bad '{"lean":{"toolchain_env":{"X_CACHE":"/etc"}}}' "outside the cache"
bad '{"lean":{"toolchain_env":{"X_CACHE":"--dir=$HOME/x"}}}' "only \$LEAN_CACHE"
bad '{"lean":{"toolchain_env":{"X_CACHE":"~/x"}}}' "only \$LEAN_CACHE"
bad '{"lean":{"toolchain_env":{"X_CACHE":"$LEAN_CACHE/../../x"}}}' "no \.\."
bad '{"lean":{"toolchain_env":{"X_CACHE":1}}}' "object of strings"
bad '{"lean":{"toolchain_env":["X"]}}' "object of strings"
# The knob lives in .harness.json, which the feature's pin covers.
project "$T" '{"verify_command":"true","lean":{"toolchain_env":{"A_CACHE":"$LEAN_CACHE/a"}}}'
mkdir -p "$T/docs/features" && echo '# f' > "$T/docs/features/f.md"
bash -c '. "$1/lean/lib.sh"; lean_pin "$2" f' _ "$TOOLKIT_DIR" "$T" >/dev/null 2>&1 || die "lean_pin"
bash -c '. "$1/lean/lib.sh"; lean_check_trusted "$2" f' _ "$TOOLKIT_DIR" "$T" >/dev/null 2>&1 || die "the pin should hold before the change"
printf '%s\n' '{"verify_command":"true","lean":{"toolchain_env":{"A_CACHE":"$LEAN_CACHE/b"}}}' > "$T/.harness.json"
bash -c '. "$1/lean/lib.sh"; lean_check_trusted "$2" f' _ "$TOOLKIT_DIR" "$T" >/dev/null 2>&1 && die "a changed lean.toolchain_env must trip the pin"
pass "lean.toolchain_env: expanded, refused names and values (exit 125), pinned with .harness.json"

echo "10. LEAN_HOME_READ without Go's build caches; cargo, npm and python still run in the gate"
mkdir -p "$HOME/.cache/go-build" "$HOME/.cargo/registry"
prof=$(bash "$TOOLKIT_DIR/lean/sandbox.sh" "$P" --seatbelt 2>/dev/null) || die "sandbox.sh --seatbelt"
grep -q 'allow file-read\*.*go-build' <<<"$prof" && die "the profile must not open a go-build cache: $(grep go-build <<<"$prof")"
grep -qF "(allow file-read* (subpath \"$HOME/.cargo\"))" <<<"$prof" || die "the profile should still open ~/.cargo"
if [ "$SBX" = 1 ]; then
  echo cached-test-output > "$HOME/Library/Caches/go-build/x"
  gate "$P" "cat '$HOME/Library/Caches/go-build/x'" >/dev/null 2>&1 && die "the gate must not read ~/Library/Caches/go-build"
  ran=""
  if [ -n "$CARGO" ] && [ -d "${C:-}" ]; then
    out=$(gate "$C" "'$CARGO' test --offline 2>&1") || die "cargo test in the gate: $out"; ran="$ran cargo"
  fi
  if [ -n "$NPM" ]; then
    N="$WORK/npmp"; mkdir -p "$N"; printf '{"name":"n","version":"1.0.0","scripts":{"test":"node -e \\"console.log(40+2)\\""}}\n' > "$N/package.json"
    project "$N"
    out=$(gate "$N" "'$NPM' test 2>&1") || die "npm test in the gate: $out"
    grep -qx 42 <<<"$out" || die "npm test output: $out"; ran="$ran npm"
  fi
  if [ -n "$PY" ]; then
    Y="$WORK/pyp"; mkdir -p "$Y"; printf 'import unittest\nclass T(unittest.TestCase):\n    def test_x(self): self.assertEqual(2, 2)\n' > "$Y/test_x.py"
    project "$Y"
    if "$PY" -c 'import pytest' >/dev/null 2>&1; then
      out=$(gate "$Y" "'$PY' -m pytest -q 2>&1") || die "pytest in the gate: $out"; ran="$ran pytest"
    else
      out=$(gate "$Y" "'$PY' -m unittest -q 2>&1") || die "python unittest in the gate: $out"; ran="$ran unittest"
    fi
  fi
  pass "no go-build cache readable; ran in the gate:${ran:- nothing installed}"
else
  pass "no go-build cache in the profile (sandbox-exec unavailable: runs skipped)"
fi

echo "lean_toolchain_cache_test: $PASS passed, $SKIP skipped"
