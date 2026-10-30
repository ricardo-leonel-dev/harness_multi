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
set -euo pipefail

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
while IFS= read -r d; do
  [ "$(basename "$d")" = "$own_slug" ] || private+=("$d")
done < <(find "$projects_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

printf '%s\n' "${private[@]}" | jq -R . | jq -sc \
  --arg project "$project" --argjson domains "$domains" \
  --arg tmp "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)" '
  . as $private
  | {
      sandbox: {
        enabled: true,
        failIfUnavailable: true,
        allowUnsandboxedCommands: false,
        autoAllowBashIfSandboxed: true,
        filesystem: { denyRead: $private, allowRead: [$project], allowWrite: [$tmp] },
        network: { allowLocalBinding: true, allowedDomains: $domains, strictAllowlist: true }
      },
      permissions: { deny: [ $private[] | "Read(/\(.)/**)", "Edit(/\(.)/**)" ] }
    }'
