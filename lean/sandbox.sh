#!/usr/bin/env bash
# sandbox.sh — Claude Code --settings JSON for one lean session in a project (or, with
# --seatbelt, the same rules as a macOS sandbox-exec profile, which the gate runs the suite in).
#
#   lean/sandbox.sh <project_dir> [--seatbelt]
#
# What it protects against, and what it doesn't: lean/SECURITY.md. In short:
#
# Reads: every entry of $HOME is denied, except what is carved out (the entries holding it are
# replaced by their other entries, level by level, so nothing else opens): the project; the
# toolchains and package caches (LEAN_HOME_READ) and .harness.json::lean.allowed_read (`~`
# expanded, `..` normalised; an entry that holds the project or lies in a hard-protected path,
# as written or resolved, is refused whole and named on stderr); the targets of the top-level
# symlinks git tracks (committed at HEAD, unchanged) or ignores, and the project's git
# directories; this project's own Claude Code folder. Credentials (the `protected` list below)
# never open, and the seatbelt profile denies them again after its allows. Outside $HOME:
# /Volumes, /Users/Shared, the per-user cache dir and Claude Code's temp folder
# (/private/tmp/claude-<uid>; LEAN_CLAUDE_TMP replaces it, for tests) are denied; the session
# settings re-open that folder's entry named after this project (the session's own outputs).
#
# Writes: the project and the temp dir. Inside the project the harness-owned paths
# (LEAN_DENY_WRITE) and the git state (.git, the git dir, the common dir) are write-denied by
# name, and CLAUDE.md / CLAUDE.local.md / .claude/ anywhere get Edit deny globs (the profile:
# a regex, any case). Network: localhost and lean.allowed_domains; unix sockets only in the
# project and the local database sockets (.s.PGSQL.<port>, mysql.sock, redis*.sock,
# memcached*.sock in /private/tmp; LEAN_DB_SOCK_DIR replaces that folder, for tests).
#
# --seatbelt adds what Claude Code's settings can't say: writes only in the project, /dev
# (but the terminals: no write or ioctl on /dev/tty*) and /private/tmp (lean/lib.sh
# lean_sandboxed adds the run's own TMPDIR); never $SSH_AUTH_SOCK; mach services only from an
# allowlist (LEAN_MACH_ALLOW and lean.allowed_mach, never LEAN_MACH_NEVER: no LaunchServices
# `open`, Apple Events `osascript`, pasteboard or cfprefsd agent); no /bin/launchctl; signals
# only within the sandbox. With lean.allowed_domains seatbelt can't filter by host name: the
# profile leaves outbound network open and says so with a [WARN] on stderr.
#
# The session environment: RUSTC_WRAPPER and CARGO_BUILD_RUSTC_WRAPPER empty (sccache can't
# reach its server from the sandbox), GIT_OPTIONAL_LOCKS=0 (git status/diff don't write the
# index, which in a worktree lives outside the project), GIT_CONFIG_GLOBAL=/dev/null and
# SSH_AUTH_SOCK empty. Secret-looking variables are dropped by the callers (lean/lib.sh
# lean_env_args).
set -euo pipefail

# real_path <path> — the resolved path, or nothing when it does not exist.
real_path() {
  if command -v realpath >/dev/null 2>&1; then realpath "$1" 2>/dev/null || true
  else python3 -c 'import os, sys; p = os.path.realpath(sys.argv[1]); print(p) if os.path.exists(p) else None' "$1"; fi
}
# under <path> <dir> — <path> is <dir> or inside it.
under() { case "$1/" in "$2"/*) return 0 ;; *) return 1 ;; esac; }

usage="usage: lean/sandbox.sh <project_dir> [--seatbelt]"
project="$(cd "${1:?$usage}" && pwd)"; shift
seatbelt=0
while [ $# -gt 0 ]; do
  case "$1" in
    --seatbelt) seatbelt=1; shift ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
domains=$(jq -c '.lean.allowed_domains // []' "$project/.harness.json" 2>/dev/null || echo '[]')
project_real=$(real_path "$project")

# Toolchains and package caches, readable under $HOME (relative to it).
LEAN_HOME_READ=".cargo .rustup .npm .nvm .pyenv .rbenv .gem .bun .deno .volta .asdf .sdkman
  .local/share/mise .local/share/pnpm .local/share/nvm .local/share/fnm .local/share/uv
  .local/share/pipx .local/share/virtualenv .local/share/rtx .local/bin .local/lib
  go/pkg go/bin .gradle .m2 .yarn .pnpm-store Library/pnpm
  .cache/pip .cache/uv .cache/go-build .cache/yarn .cache/node Library/Caches/go-build
  Library/Caches/pip Library/Caches/Yarn"
# Harness-owned paths in the project that sessions must not write.
db_path=$(jq -r '.db_path // "harness.db"' "$project/.harness.json" 2>/dev/null || echo harness.db)
LEAN_DENY_WRITE=(lean scripts .harness.json "$db_path" "$db_path-journal" "$db_path-wal" "$db_path-shm"
  init.sh harness .claude .codex AGENTS.md CLAUDE.md CLAUDE.local.md .mcp.json)

# Protected: never opened through a link. The hard ones not through lean.allowed_read either
# (Documents, Desktop, Downloads and Library may be opened there, one subfolder at a time).
# Credential files inside the allowed toolchain folders are matched by name, plus whatever
# matches their patterns now (~/.m2/settings-*.xml, ~/.cargo/credentials.*).
creds=".cargo/credentials .cargo/credentials.toml .gradle/gradle.properties .m2/settings.xml
  .m2/settings-security.xml .gem/credentials .local/share/uv/credentials"
for f in "$HOME"/.m2/settings*.xml "$HOME"/.cargo/credentials*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  case " $(echo $creds) " in *" ${f#"$HOME"/} "*) ;; *) creds="$creds ${f#"$HOME"/}" ;; esac
done
protected=() hard=()
for p in .ssh .aws .gnupg .netrc .docker .kube .config/gh .config/fish .config/git .gitconfig \
         .npmrc .yarnrc .yarnrc.yml .pypirc $creds Library/Keychains \
         .local/share/fish .local/share/keyrings .local/share/Trash .cache/harness \
         .zsh_history .zsh_sessions .bash_history .python_history .node_repl_history .psql_history \
         .sqlite_history .mysql_history .lesshst .irb_history \
         - Documents Desktop Downloads Library; do
  [ "$p" = - ] && { hard=(${protected[@]+"${protected[@]}"}); continue; }
  p="$HOME/$p"
  under "$project" "$p" && continue   # a private folder holding the project (~/Documents/...)
  protected+=("$p")
  r=$(real_path "$p"); [ -z "$r" ] || [ "$r" = "$p" ] || protected+=("$r")
done
# Other projects' Claude Code transcripts (this project's own folder stays readable: it
# holds the large outputs Claude Code persists for the session).
projects_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
own_slug=$(printf '%s' "$project" | sed 's/[^a-zA-Z0-9]/-/g')
others=()
while IFS= read -r d; do
  [ "$(basename "$d")" = "$own_slug" ] || { others+=("$d"); protected+=("$d"); hard+=("$d"); }
done < <(find "$projects_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
holds_project() { case "$1" in /|"$HOME") return 0 ;; esac; under "$project" "$1" || { [ -n "$project_real" ] && under "$project_real" "$1"; }; }
# refused_target <path> — a link target: overlaps a protected path, or holds the project.
refused_target() {
  local p
  holds_project "$1" && return 0
  for p in ${protected[@]+"${protected[@]}"}; do under "$1" "$p" || under "$p" "$1" && return 0; done
  return 1
}
# refused_allow <path> — a lean.allowed_read entry: inside a hard-protected path, or holds the
# project (hard-protected paths inside it stay denied).
refused_allow() {
  local p
  holds_project "$1" && return 0
  for p in ${hard[@]+"${hard[@]}"}; do under "$1" "$p" && return 0; done
  return 1
}

# denyRead: every entry of $HOME, and the other transcripts (CLAUDE_CONFIG_DIR may be elsewhere).
private=()
while IFS= read -r s; do private+=("$s"); done < <(find "$HOME" -mindepth 1 -maxdepth 1 2>/dev/null | LC_ALL=C sort)
private+=(${others[@]+"${others[@]}"})
# Outside $HOME: removable and shared volumes.
tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)"; tmp="${tmp%/}"
tmp_real=$(real_path "$tmp"); tmp_real="${tmp_real:-$tmp}"
for d in /Volumes /Users/Shared; do [ ! -d "$d" ] || private+=("$d"); done
# The per-user cache dir (DARWIN_USER_CACHE_DIR, /var/folders/.../C: other apps' caches;
# clang's module cache, unwritable anyway), unless it holds the project, $HOME or the temp dir.
user_cache=$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true); user_cache="${user_cache%/}"
if [ -n "$user_cache" ] && [ -d "$user_cache" ]; then
  for x in "$project" "$project_real" "$HOME" "$tmp" "$tmp_real"; do
    [ -n "$x" ] || continue
    if under "$x" "$user_cache" || under "$x" "$(real_path "$user_cache")"; then user_cache=""; break; fi
  done
  [ -z "$user_cache" ] || private+=("$user_cache")
fi
# Claude Code's temp folder (/private/tmp/claude-<uid>: every session's scratchpads and task
# outputs, the leader's included) is denied as a whole. The session settings re-open its entry
# named after this project (the session's own task outputs); the seatbelt profile doesn't (the
# gate's commands are not Claude Code). Added after the carving below, which would otherwise
# list its entries. Left open (named on stderr) when the project, $HOME or the temp dir is
# inside it, or it is inside the project.
claude_tmps=() claude_open=()
r=$(real_path "${LEAN_CLAUDE_TMP:-/tmp/claude-$(id -u)}")
if [ -n "$r" ] && [ -d "$r" ]; then
  inside=""
  for x in "$project" "$project_real" "$HOME" "$tmp" "$tmp_real"; do
    [ -n "$x" ] || continue
    if under "$x" "$r" || { { [ "$x" = "$project" ] || [ "$x" = "$project_real" ]; } && under "$r" "$x"; }; then inside="$x"; break; fi
  done
  if [ -n "$inside" ]; then echo "lean/sandbox.sh: $r stays readable ($inside is inside it or holds it)" >&2
  else
    claude_tmps=("$r")
    [ ! -d "$r/$own_slug" ] || claude_open=("$r/$own_slug")
  fi
fi

# carve <target> — drop the denied entries inside <target> and replace each one that holds it
# by the siblings along the path down to it, so <target> is no longer denied while the rest
# of the entry still is.
carve() {
  local t="$1" p d parent s out=()
  for p in ${private[@]+"${private[@]}"}; do
    if under "$p" "$t"; then continue   # <target> itself, or a piece an earlier carve left inside it
    elif under "$t" "$p"; then
      d="$t"
      while [ "$d" != "$p" ]; do
        parent="$(dirname "$d")"
        while IFS= read -r s; do [ "$s" = "$d" ] || out+=("$s"); done \
          < <(find "$parent" -mindepth 1 -maxdepth 1 2>/dev/null)
        d="$parent"
      done
    else out+=("$p"); fi
  done
  private=(${out[@]+"${out[@]}"})
}
carve "$project"; [ -z "$project_real" ] || [ "$project_real" = "$project" ] || carve "$project_real"
[ ! -d "$projects_dir/$own_slug" ] || carve "$projects_dir/$own_slug"

# norm_path <absolute path> — `.`, `..` and repeated slashes removed, without resolving links.
norm_path() {
  local parts=() out=() part n
  IFS=/ read -r -a parts <<<"$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ""|.) ;;
      ..) n=${#out[@]}; [ "$n" = 0 ] || unset "out[$((n - 1))]"; out=(${out[@]+"${out[@]}"}) ;;
      *) out+=("$part") ;;
    esac
  done
  [ ${#out[@]} -gt 0 ] && printf '/%s' "${out[@]}" || printf /
  echo
}
# Readable under $HOME: the toolchain list and lean.allowed_read. An entry is checked as
# written (normalised) and resolved; when either is refused, neither form is opened.
allow_home=()
while IFS= read -r a; do
  [ -n "$a" ] || continue
  case "$a" in "~") a="$HOME" ;; "~/"*) a="$HOME/${a#\~/}" ;; /*) ;; *) a="$HOME/$a" ;; esac
  a=$(norm_path "$a")
  [ -e "$a" ] || continue
  r=$(real_path "$a")
  if refused_allow "$a" || { [ -n "$r" ] && refused_allow "$r"; }; then
    [ "$r" = "$a" ] && r=""
    echo "lean/sandbox.sh: $a${r:+ (-> $r)} stays unreadable (protected, or holds the project)" >&2
    continue
  fi
  for c in "$a" "$r"; do
    [ -n "$c" ] || continue
    case " ${allow_home[*]-} " in *" $c "*) continue ;; esac
    allow_home+=("$c")
  done
done < <(printf '%s\n' $LEAN_HOME_READ; jq -r '.lean.allowed_read // [] | .[]' "$project/.harness.json" 2>/dev/null || true)
for a in ${allow_home[@]+"${allow_home[@]}"}; do carve "$a"; done
# What a broad entry holds that stays private (~/.cargo/credentials.toml, ~/.config/gh inside
# an allowed ~/.config): denied again, and the entry holding it stays out of allowRead.
redeny=()
for p in ${hard[@]+"${hard[@]}"}; do
  for a in ${allow_home[@]+"${allow_home[@]}"}; do
    if under "$p" "$a" && [ "$p" != "$a" ]; then private+=("$p"); redeny+=("$p"); break; fi
  done
done
# holds_redeny <path> — some re-denied path is inside <path>.
holds_redeny() {
  local p
  for p in ${redeny[@]+"${redeny[@]}"}; do under "$p" "$1" && return 0; done
  return 1
}

# git_dirs — the git directories of the project, resolved: the git dir and the common dir.
git_dirs() {
  local flag g
  for flag in --git-dir --git-common-dir; do
    g=$(cd "$project" && git rev-parse "$flag" 2>/dev/null) || continue
    (cd "$project" && real_path "$g")
  done
}
git_dir_list=$(git_dirs | sort -u)
top=$(cd "$project" && git rev-parse --show-toplevel 2>/dev/null || true)

# link_known <name> — git knows the top-level link <name>: committed as a symlink at HEAD and
# unchanged since, or ignored/excluded. An untracked, non-ignored link (one a session could
# have planted by mistake, or a stray one) is not read through.
link_known() {
  local mode
  mode=$(cd "$project" && git ls-tree HEAD -- "$1" 2>/dev/null | awk -F'\t' -v n="$1" '$2 == n { split($1, a, " "); print a[1] }')
  if [ "$mode" = 120000 ]; then
    (cd "$project" && git --literal-pathspecs diff --no-relative --quiet HEAD -- "$1" 2>/dev/null) && return 0
  fi
  (cd "$project" && git check-ignore -q -- "$1" 2>/dev/null)
}
# Read-through targets: the top-level symlinks git knows, and the git directories.
candidates=()
while IFS= read -r l; do
  t=$(real_path "$l"); [ -n "$t" ] || continue
  under "$t" "$project" || under "$t" "$project_real" && continue   # inside: readable anyway
  if ! link_known "$(basename "$l")"; then
    echo "lean/sandbox.sh: $l -> $t stays unreadable (a symlink git neither tracks nor ignores)" >&2
    continue
  fi
  candidates+=("$l	$t")
done < <(find "$project" -mindepth 1 -maxdepth 1 -type l 2>/dev/null | sort)
# The worktree's .git (a file naming the git dir, or the git dir itself) is what git reads
# first to find the repository; in a subfolder project it sits outside the project.
if [ -n "$top" ] && [ -e "$top/.git" ]; then
  candidates+=("$top/.git	$(real_path "$top/.git")")
fi
while IFS= read -r g; do [ -z "$g" ] || candidates+=("git dir	$g"); done <<<"$git_dir_list"
targets=()
for c in ${candidates[@]+"${candidates[@]}"}; do
  src="${c%%	*}" t="${c#*	}"
  under "$t" "$project" || under "$t" "$project_real" && continue
  if refused_target "$t"; then
    echo "lean/sandbox.sh: $src -> $t stays unreadable (private, frozen or too wide)" >&2
    continue
  fi
  case " ${targets[*]-} " in *" $t "*) ;; *) targets+=("$t") ;; esac
done
for t in ${targets[@]+"${targets[@]}"}; do carve "$t"; done
edit_deny=()
for t in ${targets[@]+"${targets[@]}"}; do
  if [ -d "$t" ]; then edit_deny+=("Edit(/$t/**)"); else edit_deny+=("Edit(/$t)"); fi
done
# Write-denied by name: the harness-owned paths and the git state, wherever it is (inside the
# project for a root-level repository).
deny_write=()
for root in "$project" "$project_real"; do
  [ -n "$root" ] || continue
  deny_write+=("$root/.git")
  for p in "${LEAN_DENY_WRITE[@]}"; do deny_write+=("$root/$p"); done
done
[ -z "$top" ] || deny_write+=("$top/.git")
while IFS= read -r g; do [ -z "$g" ] || deny_write+=("$g"); done <<<"$git_dir_list"
for p in "${LEAN_DENY_WRITE[@]}"; do   # a link's target too (read-only anyway, but Edit-denied)
  [ -L "$project/$p" ] || continue
  r=$(real_path "$project/$p"); [ -z "$r" ] || deny_write+=("$r")
done
write_deny=()
for t in "${deny_write[@]}"; do
  case " ${write_deny[*]-} " in *" $t "*) continue ;; esac
  write_deny+=("$t")
  edit_deny+=("Edit(/$t)" "Edit(/$t/**)")
done
# CLAUDE.md and CLAUDE.local.md anywhere in the project (Claude Code loads nested ones too) and
# nested .claude/ folders (skills, commands, agents).
for root in "$project" "$project_real"; do
  [ -n "$root" ] || continue
  case " ${edit_deny[*]} " in *" Edit(/$root/**/CLAUDE.md) "*) continue ;; esac
  edit_deny+=("Edit(/$root/**/CLAUDE.md)" "Edit(/$root/**/CLAUDE.local.md)" "Edit(/$root/**/.claude/**)")
done
# allowRead: the project, the read-through targets and the allowed $HOME entries that hold no
# re-denied path (Claude Code's runtime lets allowRead win inside denyRead; those entries are
# carved out of denyRead anyway, so they stay readable).
allow_read=("$project" ${targets[@]+"${targets[@]}"})
for a in ${allow_home[@]+"${allow_home[@]}"}; do holds_redeny "$a" || allow_read+=("$a"); done
private+=(${claude_tmps[@]+"${claude_tmps[@]}"}); allow_read+=(${claude_open[@]+"${claude_open[@]}"})
# A denied path whose resolved form holds the project (a /Volumes entry linking to /) would
# deny the project: dropped.
kept=()
for p in ${private[@]+"${private[@]}"}; do
  r=$(real_path "$p")
  [ -n "$r" ] && [ "$r" != "$p" ] && holds_project "$r" && continue
  kept+=("$p")
done
private=(${kept[@]+"${kept[@]}"})
# Unix sockets: the project, and the local database sockets directly in /private/tmp
# (PostgreSQL, MySQL, Redis, memcached by their usual names; other apps' sockets there, such
# as a file-sync client's IPC, stay unreachable).
db_sockets='\.s\.PGSQL\.[0-9]+|mysqlx?\.sock|redis[^/]*\.sock|memcached[^/]*\.sock'
socks=("$project")
[ -z "$project_real" ] || [ "$project_real" = "$project" ] || socks+=("$project_real")
# LEAN_DB_SOCK_DIR replaces /private/tmp there (tests: a temp folder of their own).
db_dir=$(real_path "${LEAN_DB_SOCK_DIR:-/tmp}"); db_dir="${db_dir:-/private/tmp}"
while IFS= read -r s; do
  if printf '%s\n' "$(basename "$s")" | grep -qxE "$db_sockets"; then socks+=("$s"); fi
done < <(find "$db_dir" -mindepth 1 -maxdepth 1 -type s 2>/dev/null | LC_ALL=C sort)

to_json() { if [ $# -gt 0 ]; then printf '%s\n' "$@" | jq -R . | jq -sc .; else echo '[]'; fi; }
settings=$(to_json ${private[@]+"${private[@]}"} | jq -c \
  --arg project "$project" --argjson domains "$domains" \
  --argjson allow_read "$(to_json "${allow_read[@]}")" \
  --argjson edit_deny "$(to_json ${edit_deny[@]+"${edit_deny[@]}"})" \
  --argjson deny_write "$(to_json "${write_deny[@]}")" \
  --argjson socks "$(to_json "${socks[@]}")" --argjson claude_tmps "$(to_json ${claude_tmps[@]+"${claude_tmps[@]}"})" \
  --arg tmp "$tmp" '
  unique as $private
  | {
      sandbox: {
        enabled: true,
        failIfUnavailable: true,
        allowUnsandboxedCommands: false,
        autoAllowBashIfSandboxed: true,
        filesystem: { denyRead: $private, allowRead: $allow_read,
                      allowWrite: [$tmp], denyWrite: $deny_write },
        network: { allowLocalBinding: true, allowedDomains: $domains, strictAllowlist: true,
                   allowAllUnixSockets: false, allowUnixSockets: $socks }
      },
      env: { RUSTC_WRAPPER: "", CARGO_BUILD_RUSTC_WRAPPER: "", GIT_OPTIONAL_LOCKS: "0",
             GIT_CONFIG_GLOBAL: "/dev/null", SSH_AUTH_SOCK: "" },
      permissions: { deny: ([ $private[] | select(. as $p | ($claude_tmps | any(.[]; . == $p)) | not) | "Read(/\(.)/**)", "Edit(/\(.)/**)" ] + $edit_deny) }
    }')
if [ "$seatbelt" = 0 ]; then printf '%s\n' "$settings"; exit 0; fi

# The seatbelt profile (a later rule wins): reads as above, then the hard re-denies (after the
# allows, so an allowed toolchain folder doesn't reopen its credentials) and Claude Code's temp
# folder as a whole; writes only in the project, /dev and /private/tmp, then the write denies
# (by name, and CLAUDE.md / CLAUDE.local.md / .claude/ anywhere by regex) and the terminals;
# the network and the unix sockets; mach services, launchctl and signals. Seatbelt matches resolved paths,
# so every path is given as written and resolved (a missing one through its parent: /var ->
# /private/var).
resolved() { # <path...>: each path, then its resolved form when that differs
  local p r
  for p in "$@"; do
    printf '%s\n' "$p"
    r=$(real_path "$p"); [ -n "$r" ] || { r=$(real_path "$(dirname "$p")"); [ -z "$r" ] || r="$r/$(basename "$p")"; }
    [ -z "$r" ] || [ "$r" = "$p" ] || printf '%s\n' "$r"
  done
}
# list [--deny] — the paths on stdin, as written and resolved, as a JSON array; --deny drops
# a resolved form that holds the project (see above).
list() {
  local deny="${1:-}" p r
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    while IFS= read -r r; do
      [ "$r" != "$p" ] && [ "$deny" = --deny ] && holds_project "$r" && continue
      printf '%s\n' "$r"
    done < <(resolved "$p")
  done | jq -R . | jq -sc 'unique'
}
paths() { jq -r ".sandbox.filesystem.$1[]" <<<"$settings" | list ${2:-}; }
# Writable: the project, /dev (but the terminals) and /private/tmp. Not the user temp dir
# (DARWIN_USER_TEMP_DIR, other apps' files): lean/lib.sh lean_sandboxed gives each run a fresh
# TMPDIR of its own there and allows writing in that one only.
writable=$(resolved "$project" /dev /private/tmp | jq -R . | jq -sc 'unique')
# rx <path> — the path as a seatbelt regex literal.
rx() { printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|]/\\&/g'; }
# Names write-denied anywhere in the project, any case: CLAUDE.md / CLAUDE.local.md and .claude/
# folders (and all they hold).
claude_md=()
while IFS= read -r root; do
  claude_md+=("^$(rx "$root")/(.*/)?[Cc][Ll][Aa][Uu][Dd][Ee](\\.[Ll][Oo][Cc][Aa][Ll])?\\.[Mm][Dd]\$"
              "^$(rx "$root")/(.*/)?\\.[Cc][Ll][Aa][Uu][Dd][Ee](/|\$)")
done < <(resolved "$project" ${project_real:+"$project_real"} | sed '/^$/d' | sort -u)
agent=()
[ -z "${SSH_AUTH_SOCK:-}" ] || while IFS= read -r p; do agent+=("$p"); done < <(resolved "$SSH_AUTH_SOCK")
# Mach services: denied but for what the toolchains need (the list Apple's system.sb grants
# every process, minus LaunchServices' map and cfprefsd's per-user agent, plus the network
# configuration that name resolution reads) and .harness.json::lean.allowed_mach. A list of
# specific denies is not enough: with LaunchServices' own services denied, `open` still started
# an app outside the sandbox through another one. Never allowed (LEAN_MACH_NEVER, named on
# stderr when lean.allowed_mach lists one): LaunchServices (`open`), Apple Events (`osascript`),
# the pasteboard, cfprefsd's agent (any app's preferences), securityd, the window server, the
# Dock, TCC, launchd's XPC services, login items, nsurlsessiond, Spotlight, distributed
# notifications.
LEAN_MACH_ALLOW="com.apple.analyticsd com.apple.bsd.dirhelper
  com.apple.cfprefsd.daemon com.apple.diagnosticd com.apple.logd com.apple.logd.events
  com.apple.system.DirectoryService.libinfo_v1 com.apple.system.logger
  com.apple.system.notification_center com.apple.system.opendirectoryd.libinfo
  com.apple.system.opendirectoryd.membership com.apple.trustd com.apple.trustd.agent
  com.apple.SystemConfiguration.configd com.apple.SystemConfiguration.DNSConfiguration"
LEAN_MACH_NEVER='^com\.apple\.(coreservices\.(launchservicesd|appleevents|sharedfilelistd)|lsd\.|pasteboard\.|securityd|SecurityServer|windowserver|dock\.|tccd|xpc\.|FSEvents|coreservices\.quarantine|cfprefsd\.agent|backgroundtaskmanagement|nsurlsessiond|metadata\.mds|distributed_notifications)'
mach=()
while IFS= read -r m; do
  [ -n "$m" ] || continue
  if printf '%s\n' "$m" | grep -qE "$LEAN_MACH_NEVER" || ! printf '%s\n' "$m" | grep -qE '^[A-Za-z0-9._-]+$'; then
    echo "lean/sandbox.sh: mach service $m stays denied (it launches or drives processes outside the sandbox, or reads secrets)" >&2
    continue
  fi
  mach+=("$m")
done < <(printf '%s\n' $LEAN_MACH_ALLOW; jq -r '.lean.allowed_mach // [] | .[]' "$project/.harness.json" 2>/dev/null || true)
[ "$domains" = '[]' ] || echo "[WARN] lean/sandbox.sh --seatbelt: lean.allowed_domains is set and seatbelt can't filter by host name: outbound network stays open in this profile" >&2
jq -nr --argjson deny_read "$(paths denyRead --deny)" --argjson allow_read "$(paths allowRead)" \
  --argjson redeny "$(printf '%s\n' ${redeny[@]+"${redeny[@]}"} | list --deny)" \
  --argjson allow_home "$(printf '%s\n' ${allow_home[@]+"${allow_home[@]}"} | list)" \
  --argjson writable "$writable" --argjson deny_write "$(paths denyWrite)" \
  --argjson claude_md "$(to_json "${claude_md[@]}")" \
  --argjson socks "$(resolved "$project" ${project_real:+"$project_real"} | sed '/^$/d' | jq -R . | jq -sc unique)" \
  --argjson agent "$(to_json ${agent[@]+"${agent[@]}"})" --arg db "$db_sockets" --arg db_dir "$(rx "$db_dir")" \
  --argjson claude_tmp "$(printf '%s\n' ${claude_tmps[@]+"${claude_tmps[@]}"} | list)" \
  --argjson claude_open "$(printf '%s\n' ${claude_open[@]+"${claude_open[@]}"} | list)" \
  --argjson mach "$(to_json "${mach[@]}")" \
  --argjson open_net "$([ "$domains" = '[]' ] && echo false || echo true)" '
  "(version 1)", "(allow default)",
  ($deny_read[] | "(deny file-read* (subpath \(tojson)))"),
  (($allow_read + $allow_home) - $claude_open | unique[] | "(allow file-read* (subpath \(tojson)))"),
  ($redeny[] | "(deny file-read* (subpath \(tojson)))"),
  ($claude_tmp[] | "(deny file-read* (subpath \(tojson)))"),
  "(deny file-write*)",
  ($writable[] | "(allow file-write* (subpath \(tojson)))"),
  ($claude_tmp[] | "(deny file-write* (subpath \(tojson)))"),
  ($deny_write[] | "(deny file-write* (subpath \(tojson)))"),
  ($claude_md[] | "(deny file-write* (regex #\"\(.)\"))"),
  "(deny file-write* (regex #\"^/dev/tty\"))", "(deny file-ioctl (regex #\"^/dev/tty\"))",
  (if $open_net then empty else
    "(deny network-outbound (remote ip \"*:*\"))", "(allow network-outbound (remote ip \"localhost:*\"))" end),
  "(deny network-outbound (remote unix-socket))",
  ($socks[] | "(allow network-outbound (remote unix-socket (subpath \(tojson))))"),
  "(allow network-outbound (remote unix-socket (regex #\"^\($db_dir)/(\($db))$\")))",
  (if $open_net then "(allow network-outbound (remote unix-socket (literal \"/private/var/run/mDNSResponder\")))" else empty end),
  ($agent[] | "(deny network-outbound (remote unix-socket (literal \(tojson))))"),
  "(deny mach-lookup)",
  "(allow mach-lookup \([$mach[] | "(global-name \(tojson))"] | join(" ")))",
  "(deny process-exec (literal \"/bin/launchctl\") (signing-identifier \"com.apple.xpc.launchctl\"))",
  "(deny signal)", "(allow signal (target same-sandbox))"'
