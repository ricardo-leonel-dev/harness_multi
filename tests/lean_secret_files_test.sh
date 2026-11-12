#!/usr/bin/env bash
# lean_secret_files_test.sh — secret files in the project are unreadable to the sessions
# lean/run.sh opens, and stay readable to the gate (suites load .env).
#
#   1. lean/lib.sh lean_secret_files: .env, .env.local, .env.production, config/app.key, x.pem, a
#      *secret* file, a *credential* file and a *secret* folder are found, in the project and
#      in the rest of its repository; .env.example / .env.sample / .env.template (any case), a
#      normal source file and dependencies (node_modules) are not; a repository folder named
#      like a secret that holds the project is entered, never listed.
#   2. lean/sandbox.sh session settings: denyRead and Read deny rules name those paths (a link
#      also by its target) and the LEAN_SECRET_GLOBS globs; nothing in denyRead or the rules
#      reaches .env.example, src/app.js or the dependency's credentials module.
#   3. lean/sandbox.sh --seatbelt (the gate's profile): no secret path or glob in it.
#   4. sandbox-exec (macOS): the session settings applied as Claude Code's macOS sandbox applies
#      them (literal paths as subpaths, globs as regexes: `**/` -> `(.*/)?`, `*` -> `[^/]*`):
#      cat .env, .env.local, config/app.key, x.pem, the *secret* file, the repository root's .env
#      and a .env created after the settings were built fail; .env.example and src/app.js read.
#      The gate (lean_sandbox_prepare + lean_sandboxed, its real profile) reads .env.
#   5. lean/adapters/codex.sh: the permission profile denies the same paths and globs, not
#      .env.example; its self-check refuses (exit 3) when the secret file it probes is readable.
#      With LEAN_TEST_REAL_CODEX=1 and codex on PATH, the profile is also applied for real
#      through `codex sandbox` (no model call, temp HOME and CODEX_HOME).
#   6. lean/run.sh brief: a keyword inside a secret file is not shown.
#
# Usage: bash tests/lean_secret_files_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }
g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

REAL_CODEX=$(command -v codex 2>/dev/null || true)
mkdir -p "$WORK/home" "$WORK/socks" "$WORK/bin"
export HOME="$WORK/home" GIT_CONFIG_GLOBAL=/dev/null
export LEAN_CLAUDE_TMP="$WORK/no-claude-tmp" LEAN_DB_SOCK_DIR="$WORK/socks"
unset LEAN_GATE_UNSANDBOXED

# A repository with the project in a subfolder named like a secret (it must stay readable).
R="$WORK/repo"; P="$R/secret-api"
mkdir -p "$P/src" "$P/config/secrets" "$P/node_modules/aws/dist" "$R/web"
printf '{"verify_command":"true"}\n' > "$P/.harness.json"
printf 'SUPABASE_JWT_SECRET=s3cr3t-value\n' > "$P/.env"
printf 'LOCAL_AUTH_SECRET=local-value\n' > "$P/.env.local"
printf 'SUPABASE_JWT_SECRET=\n' > "$P/.env.example"
printf 'X=\n' > "$P/.ENV.Sample"
printf 'X=\n' > "$P/.env.template"
printf 'key-value\n' > "$P/config/app.key"
printf 'pem-value\n' > "$P/x.pem"
printf 'token: db-secret-value\n' > "$P/config/db_secret.yml"
printf 'aws: cred-value\n' > "$P/config/credentials.json"
printf 'k8s: secret-folder-value\n' > "$P/config/secrets/prod.yml"
printf 'console.log("app")\n' > "$P/src/app.js"
printf 'module.exports = 1\n' > "$P/node_modules/aws/dist/credential-provider.js"
ln -s .env "$P/env-link"   # a link to a secret: unreadable through its target
mkdir -p "$R/shared" && printf 'SHARED_SECRET=shared-value\n' > "$R/shared/env.txt"
ln -s ../shared/env.txt "$P/.env.dev"   # a secret-named link: its target is denied too
printf 'ROOT_SECRET=root-value\n' > "$R/.env"
printf 'WEB_SECRET=web-value\n' > "$R/web/.env.production"
printf '.env*\n!.env.example\nnode_modules/\n' > "$R/.gitignore"
g -C "$R" init -q && g -C "$R" add -A && g -C "$R" commit -qm base || die "git setup"

. "$TOOLKIT_DIR/lean/lib.sh"

echo "1. lean_secret_files"
found=$(lean_secret_files "$P" | tr '\0' '\n')
for f in .env .env.local config/app.key x.pem config/db_secret.yml config/credentials.json config/secrets; do
  grep -qxF "$P/$f" <<<"$found" || die "lean_secret_files should find $f: $found"
done
for f in .env.example .ENV.Sample .env.template src/app.js node_modules/aws/dist/credential-provider.js config/secrets/prod.yml; do
  grep -qxF "$P/$f" <<<"$found" && die "lean_secret_files must not list $f"
done
found_top=$(lean_secret_files "$R" "$P" | tr '\0' '\n')
for f in .env web/.env.production; do grep -qxF "$R/$f" <<<"$found_top" || die "repository root: $f should be found: $found_top"; done
grep -qF "$P" <<<"$found_top" && die "the repository walk must not enter or list the project: $found_top"
pass "secret files found in the project and the repository; templates, sources and dependencies left out"

echo "2. session settings"
S=$(cd "$P" && bash "$TOOLKIT_DIR/lean/sandbox.sh" "$P" 2>/dev/null) || die "sandbox.sh"
deny_read=$(jq -r '.sandbox.filesystem.denyRead[]' <<<"$S")
rules=$(jq -r '.permissions.deny[]' <<<"$S")
for f in "$P/.env" "$P/.env.local" "$P/config/app.key" "$P/x.pem" "$P/config/db_secret.yml" \
         "$P/config/credentials.json" "$P/config/secrets" "$P/.env.dev" "$R/shared/env.txt" "$R/.env" "$R/web/.env.production"; do
  grep -qxF "$f" <<<"$deny_read" || die "denyRead should name $f"
  grep -qxF "Read(/$f)" <<<"$rules" || die "a Read deny rule should name $f"
done
grep -qxF "Read(/$P/config/secrets/**)" <<<"$rules" || die "a secret folder needs a Read rule for what it holds"
for n in .env .env.local '.env.*.local' '*.key' '*.p12' '*.pfx'; do
  for root in "$P" "$R"; do
    grep -qxF "$root/**/$n" <<<"$deny_read" || die "denyRead should hold the glob $root/**/$n"
    grep -qxF "Read(/$root/**/$n)" <<<"$rules" || die "a Read deny rule should hold the glob $root/**/$n"
  done
done
grep -qxF "$P" <<<"$deny_read" && die "the project itself must not be denied"
grep -qxF "$R" <<<"$deny_read" && die "the repository root must not be denied"
# glob_rx <glob>: Claude Code's macOS glob-to-regex (a match also covers what it holds).
glob_rx() {
  printf '%s' "$1" | perl -pe 's/([.+^\$(){}|\\])/\\$1/g; s#\?#[^/]#g; s#\*\*/#\x00#g; s#\*#[^/]*#g; s#\x00#(.*/)?#g; $_ = "^$_(/.*)?\$"'
}
# denied_by_settings <path>: some denyRead entry covers it.
denied_by_settings() {
  local e
  while IFS= read -r e; do
    case "$e" in
      *'*'*|*'?'*) printf '%s\n' "$1" | grep -qE "$(glob_rx "$e")" && return 0 ;;
      *) case "$1/" in "$e"/*) return 0 ;; esac ;;
    esac
  done <<<"$deny_read"
  return 1
}
for f in .env.example .ENV.Sample .env.template src/app.js node_modules/aws/dist/credential-provider.js .harness.json; do
  denied_by_settings "$P/$f" && die "$f must stay readable to the session"
done
denied_by_settings "$P/later/.env" || die "a .env created later should match a glob"
denied_by_settings "$P/node_modules/pkg/.env" || die "a .env inside a dependency should match a glob"
grep -E '^Read\(.*(\.env\.example|src/app\.js|credential-provider)' <<<"$rules" && die "no Read rule may name a readable file"
pass "session settings deny the secret paths and globs by denyRead and Read rules; templates and sources stay readable"

echo "3. the gate's profile"
SB=$(cd "$P" && bash "$TOOLKIT_DIR/lean/sandbox.sh" "$P" --seatbelt 2>/dev/null) || die "sandbox.sh --seatbelt"
grep -E '\.env|\.key|\.pem|secret"|db_secret|credentials\.json|\*\*' <<<"$SB" && die "the gate's profile must not deny secret files"
pass "the gate's profile names no secret file or glob"

echo "4. sandbox-exec"
have_sbx=0
command -v sandbox-exec >/dev/null 2>&1 && sandbox-exec -p '(version 1)(allow default)' true 2>/dev/null && have_sbx=1
if [ "$have_sbx" = 0 ]; then
  echo "  skip sandbox-exec not available"
else
  # The session's read rules as Claude Code's macOS sandbox writes them.
  session_profile() {
    local e
    printf '(version 1)\n(allow default)\n'
    while IFS= read -r e; do
      case "$e" in
        *'*'*|*'?'*) printf '(deny file-read* (regex #"%s"))\n' "$(glob_rx "$e")" ;;
        *) printf '(deny file-read* (subpath %s))\n' "$(jq -Rn --arg p "$e" '$p')" ;;
      esac
    done <<<"$deny_read"
  }
  PROF=$(session_profile)
  mkdir -p "$P/later" && printf 'LATER=later-value\n' > "$P/later/.env"
  for f in .env .env.local config/app.key x.pem config/db_secret.yml config/credentials.json config/secrets/prod.yml env-link .env.dev later/.env ../.env ../web/.env.production; do
    (cd "$P" && sandbox-exec -p "$PROF" cat "$f") >/dev/null 2>&1 && die "session: cat $f must fail"
  done
  for f in .env.example .ENV.Sample .env.template src/app.js node_modules/aws/dist/credential-provider.js; do
    (cd "$P" && sandbox-exec -p "$PROF" cat "$f") >/dev/null 2>&1 || die "session: cat $f should work"
  done
  rm -rf "$P/later"
  lean_sandbox_prepare "$P"
  [ "$LEAN_SANDBOX" = sandbox ] || die "the gate's sandbox should be ready: $LEAN_SANDBOX"
  out=$(lean_sandboxed "$P" 'cat .env && cat config/app.key && cat ../.env' 2>&1) || die "gate: reading .env failed: $out"
  grep -q 's3cr3t-value' <<<"$out" && grep -q 'key-value' <<<"$out" && grep -q 'root-value' <<<"$out" \
    || die "gate: .env, config/app.key and the root .env should be read: $out"
  pass "sandboxed: the session can't read the secret files (one created later included), the gate reads .env"
fi

echo "5. codex adapter"
CALLS="$WORK/calls"; export CALLS
# A stub `codex`: records argv; `sandbox` runs the self-check as the real one would see it
# (seatbelt, Codex's proxy, the lean-state canary unreadable) and, unless STUB_PROBE=open,
# the probed secret file unreadable too.
cat > "$WORK/bin/codex" <<'SH'
#!/usr/bin/env bash
mkdir -p "$CALLS"
n=$(ls "$CALLS" | grep -c '\.argv$')
printf '%s\0' "$@" > "$CALLS/$n.${1:-x}.argv"
[ "${1:-}" = sandbox ] || exit 0
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift
canary="$5" secret="${7:-}"
chmod 000 "$canary"; [ -z "$secret" ] || [ "${STUB_PROBE:-}" = open ] || chmod 000 "$secret"
rc=0; env CODEX_SANDBOX=seatbelt HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 CODEX_NETWORK_PROXY_ACTIVE=1 "$@" || rc=$?
chmod 700 "$canary"; [ -z "$secret" ] || chmod 644 "$secret"
exit "$rc"
SH
chmod +x "$WORK/bin/codex"
A="$TOOLKIT_DIR/lean/adapters/codex.sh"
out=$(cd "$P" && PATH="$WORK/bin:$PATH" bash "$A" "$P" check - /dev/null - 2>&1) || die "codex check: $out"
f=$(ls "$CALLS"/*.sandbox.argv | tail -1)
fs=$(tr '\0' '\n' < "$f" | sed -n 's/^permissions\.lean\.filesystem=//p')
probed=$(tr '\0' '\n' < "$f" | tail -3 | head -1)   # args: ... <secret> <codex binary> <Codex home>
case "$probed" in "$P"/*) ;; *) die "the self-check should probe a secret file of the project: $probed" ;; esac
for k in "$P/.env" "$P/.env.local" "$P/config/app.key" "$P/x.pem" "$P/config/db_secret.yml" "$P/config/secrets" "$R/.env" \
         "$P/**/.env" "$P/**/.env.local" "$P/**/*.key" "$R/**/.env"; do
  grep -qF "$(jq -Rn --arg k "$k" '$k')=\"deny\"" <<<"$fs" || die "the Codex profile should deny $k"
done
grep -qF '.env.example' <<<"$fs" && die "the Codex profile must not name .env.example"
grep -qF 'src/app.js' <<<"$fs" && die "the Codex profile must not name src/app.js"
out=$(cd "$P" && STUB_PROBE=open PATH="$WORK/bin:$PATH" bash "$A" "$P" check - /dev/null - 2>&1); rc=$?
[ "$rc" = 3 ] && grep -q 'a secret file in the project is readable' <<<"$out" || die "codex check with a readable secret should refuse (exit 3): rc=$rc $out"
if [ "${LEAN_TEST_REAL_CODEX:-}" = 1 ] && [ -n "$REAL_CODEX" ]; then
  # The adapter's flags, applied by the real `codex sandbox` (no model), the probe swapped in.
  mkdir -p "$HOME/.codex"
  cat > "$WORK/bin/codex" <<SH
#!/usr/bin/env bash
args=(); while [ \$# -gt 0 ] && [ "\$1" != -- ]; do args+=("\$1"); shift; done
CODEX_HOME="$HOME/.codex" "$REAL_CODEX" "\${args[@]}" -- /bin/sh -c 'for f in "\$@"; do cat "\$f" >/dev/null 2>&1 && echo "R \$f" || echo "- \$f"; done' sh \
  .env .env.local config/app.key x.pem config/db_secret.yml ../.env .env.example src/app.js > "$WORK/real.txt" 2>&1
echo LEAN-CODEX-SANDBOX-OK
SH
  (cd "$P" && PATH="$WORK/bin:$PATH" bash "$A" "$P" check - /dev/null -) >/dev/null 2>&1 || die "real codex check"
  [ "$(grep -c '^- ' "$WORK/real.txt")" = 6 ] && grep -qx 'R .env.example' "$WORK/real.txt" && grep -qx 'R src/app.js' "$WORK/real.txt" \
    || die "real codex sandbox: $(cat "$WORK/real.txt")"
  echo "  (real codex sandbox applied the profile)"
fi
pass "the Codex profile denies the secret paths and globs, not the templates; its self-check fails closed"

echo "6. brief"
printf 'NEEDLE in a secret\n' >> "$P/config/db_secret.yml"
printf 'NEEDLE in a key\n' >> "$P/config/app.key"
printf '// NEEDLE in source\n' >> "$P/src/app.js"
out=$(cd "$P" && bash "$TOOLKIT_DIR/lean/run.sh" brief f NEEDLE 2>&1) || die "brief: $out"
grep -q 'src/app.js:.*NEEDLE' <<<"$out" || die "brief should show the source match: $out"
grep -E 'NEEDLE in a (secret|key)' <<<"$out" && die "brief must not show a secret file's lines"
pass "brief leaves secret files out of its search"

echo "lean_secret_files_test: $PASS passed"
