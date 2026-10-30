#!/usr/bin/env bash
# sandbox.sh — Claude Code --settings JSON for one lean session in a project.
#
#   lean/sandbox.sh <project_dir>
#
# Bash writes stay in the project and the system temp dir; no outbound network except
# localhost and .harness.json::lean.allowed_domains; Bash reads of the user's private
# folders, of other projects and of the frozen manifests are denied. The same paths get
# Read/Edit deny rules, which the sandbox alone does not cover. failIfUnavailable: a
# session never runs unsandboxed by accident.
#
# Projects usually live under a private folder (~/Documents/...), so that folder can't be
# denied whole: every sibling of the project and of each of its ancestors up to $HOME is
# denied instead.
#
# Read-through: the resolved target of each symlink at the project's top level that git
# tracks (committed at HEAD, unchanged) or ignores/excludes (a git worktree's harness.db,
# scripts/, migrations/... pointing into the main worktree; link-worktree excludes them) and the
# project's git directories (`git rev-parse --git-dir` / `--git-common-dir`: a worktree's
# .git file points outside it; a project in a repository's subfolder has .git next to it)
# are readable: they are carved out of the denied siblings and added to allowRead, and get
# an Edit deny rule (writes stay in the project and the temp dir). A target in a private
# folder, in the frozen manifests (~/.cache/harness), in another project's transcripts, or
# one that contains the project or a private folder, stays denied. An untracked, non-ignored
# link (one a session could have planted) gets no read rule; stderr names it.
#
# The session environment: RUSTC_WRAPPER and CARGO_BUILD_RUSTC_WRAPPER empty (sccache can't
# reach its server from the sandbox; cargo then runs rustc directly) and GIT_OPTIONAL_LOCKS=0
# (git status/diff don't write the index, which in a worktree lives outside the project).
set -euo pipefail

# real_path <path> — the resolved path, or nothing when it does not exist.
real_path() {
  if command -v realpath >/dev/null 2>&1; then realpath "$1" 2>/dev/null || true
  else python3 -c 'import os, sys; p = os.path.realpath(sys.argv[1]); print(p) if os.path.exists(p) else None' "$1"; fi
}
# under <path> <dir> — <path> is <dir> or inside it.
under() { case "$1/" in "$2"/*) return 0 ;; *) return 1 ;; esac; }

project="$(cd "${1:?usage: lean/sandbox.sh <project_dir>}" && pwd)"
domains=$(jq -c '.lean.allowed_domains // []' "$project/.harness.json" 2>/dev/null || echo '[]')
lean_cache="$HOME/.cache/harness"

private=()
for p in "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" "$HOME/.ssh" "$HOME/.config/fish" \
         "$HOME/.aws" "$lean_cache"; do
  case "$project/" in "$p"/*) ;; *) private+=("$p") ;; esac
done
# Siblings along the path from $HOME down to the project.
case "$project" in
  "$HOME"/*)
    dir="$project"
    while [ "$dir" != "$HOME" ]; do
      parent="$(dirname "$dir")"
      # $HOME's own entries are covered by the fixed list above (the rest of $HOME holds
      # tool config the session needs).
      if [ "$parent" != "$HOME" ]; then
        while IFS= read -r s; do [ "$s" = "$dir" ] || private+=("$s"); done \
          < <(find "$parent" -mindepth 1 -maxdepth 1 2>/dev/null)
      fi
      dir="$parent"
    done ;;
esac
# Other projects' Claude Code transcripts (this project's own folder stays readable: it
# holds the large outputs Claude Code persists for the session).
projects_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
own_slug=$(printf '%s' "$project" | sed 's/[^a-zA-Z0-9]/-/g')
protected=()   # never readable through a symlink: private folders, the frozen manifests
while IFS= read -r d; do
  [ "$(basename "$d")" = "$own_slug" ] || { private+=("$d"); protected+=("$d"); }
done < <(find "$projects_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
for p in "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" "$HOME/.ssh" "$HOME/.config/fish" \
         "$HOME/.aws" "$lean_cache"; do
  under "$project" "$p" && continue
  protected+=("$p")
  r=$(real_path "$p"); [ -z "$r" ] || [ "$r" = "$p" ] || protected+=("$r")
done

# link_known <name> — git knows the top-level link <name>: committed as a symlink at HEAD and
# unchanged since, or ignored/excluded. A session can write in the project, so it could
# plant a link for the next sandboxed step; such an untracked, non-ignored link is not
# read through.
link_known() {
  local mode
  mode=$(cd "$project" && git ls-tree HEAD -- "$1" 2>/dev/null | awk -F'\t' -v n="$1" '$2 == n { split($1, a, " "); print a[1] }')
  if [ "$mode" = 120000 ]; then
    (cd "$project" && git --literal-pathspecs diff --quiet HEAD -- "$1" 2>/dev/null) && return 0
  fi
  (cd "$project" && git check-ignore -q -- "$1" 2>/dev/null)
}

# Read-through targets: top-level symlinks git knows, and the git directories.
project_real=$(real_path "$project")
candidates=()
while IFS= read -r l; do
  t=$(real_path "$l"); [ -n "$t" ] || continue
  if ! link_known "$(basename "$l")"; then
    echo "lean/sandbox.sh: $l -> $t stays unreadable (a symlink git neither tracks nor ignores)" >&2
    continue
  fi
  candidates+=("$l	$t")
done < <(find "$project" -mindepth 1 -maxdepth 1 -type l 2>/dev/null | sort)
# The worktree's .git (a file naming the git dir, or the git dir itself) is what git reads
# first to find the repository; in a subfolder project it sits outside the project.
if top=$(cd "$project" && git rev-parse --show-toplevel 2>/dev/null) && [ -e "$top/.git" ]; then
  candidates+=("$top/.git	$(real_path "$top/.git")")
fi
for flag in --git-dir --git-common-dir; do
  g=$(cd "$project" && git rev-parse "$flag" 2>/dev/null) || continue
  t=$(cd "$project" && real_path "$g"); [ -n "$t" ] && candidates+=("git $flag	$t")
done
targets=()
for c in ${candidates[@]+"${candidates[@]}"}; do
  src="${c%%	*}" t="${c#*	}"
  under "$t" "$project" || under "$t" "$project_real" && continue
  refuse=""
  case "$t" in /|"$HOME") refuse=1 ;; esac
  under "$project" "$t" || under "$project_real" "$t" && refuse=1
  for p in ${protected[@]+"${protected[@]}"}; do
    under "$t" "$p" || under "$p" "$t" && refuse=1
  done
  if [ -n "$refuse" ]; then
    echo "lean/sandbox.sh: $src -> $t stays unreadable (private, frozen or too wide)" >&2
    continue
  fi
  case " ${targets[*]-} " in *" $t "*) ;; *) targets+=("$t") ;; esac
done

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
for t in ${targets[@]+"${targets[@]}"}; do carve "$t"; done
edit_deny=()
for t in ${targets[@]+"${targets[@]}"}; do
  if [ -d "$t" ]; then edit_deny+=("Edit(/$t/**)"); else edit_deny+=("Edit(/$t)"); fi
done

to_json() { if [ $# -gt 0 ]; then printf '%s\n' "$@" | jq -R . | jq -sc .; else echo '[]'; fi; }
to_json ${private[@]+"${private[@]}"} | jq -c \
  --arg project "$project" --argjson domains "$domains" \
  --argjson targets "$(to_json ${targets[@]+"${targets[@]}"})" \
  --argjson edit_deny "$(to_json ${edit_deny[@]+"${edit_deny[@]}"})" \
  --arg tmp "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)" '
  . as $private
  | {
      sandbox: {
        enabled: true,
        failIfUnavailable: true,
        allowUnsandboxedCommands: false,
        autoAllowBashIfSandboxed: true,
        filesystem: { denyRead: $private, allowRead: ([$project] + $targets), allowWrite: [$tmp] },
        network: { allowLocalBinding: true, allowedDomains: $domains, strictAllowlist: true }
      },
      env: { RUSTC_WRAPPER: "", CARGO_BUILD_RUSTC_WRAPPER: "", GIT_OPTIONAL_LOCKS: "0" },
      permissions: { deny: ([ $private[] | "Read(/\(.)/**)", "Edit(/\(.)/**)" ] + $edit_deny) }
    }'
