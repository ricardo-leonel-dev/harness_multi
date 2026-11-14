#!/usr/bin/env bash
# claude.sh — open one sandboxed Claude Code session for a lean step.
#
#   lean/adapters/claude.sh <project> <interactive|headless> <model|-> <system_prompt_file> <prompt> [<result_json>]
#
# interactive: the user's terminal, the step prompt as the first message, edits accepted
#   and Bash auto-allowed inside the sandbox (anything the sandbox can't confine still asks).
# headless: claude -p, its JSON result written to <result_json> (usage, cost, duration).
# LEAN_RUNNER=mini runs the same session on MiniMax through the user's claude-mini fish
# function (it holds the credentials; the model argument is ignored).
# The session starts without the secret-looking environment variables (lean/lib.sh
# lean_env_drop: tokens, passwords, keys, connection URLs, SSH_AUTH_SOCK, git config and npm
# auth keys passed through the environment), except
# .harness.json::lean.env_passthrough and Claude Code's own ANTHROPIC_* / CLAUDE_* (it needs
# them to run; its commands can read them).
set -euo pipefail

LEAN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
project="$1" mode="$2" model="$3" system_file="$4" prompt="$5" result="${6:-}"

cmd=(claude) model_args=()
[ "$model" != - ] && model_args=(--model "$model")
if [ "${LEAN_RUNNER:-}" = mini ]; then
  cmd=(fish -c "${LEAN_MINI_FUNCTION:-claude-mini}"' $argv' --)
  model_args=()
fi
settings="$("$LEAN_DIR/sandbox.sh" "$project")"
# Claude Code writes each Bash command's stdout to a file in its temp folder's entry for this
# project; with the folder denied and that entry not re-opened, every command that checks its
# stdout fails (cat, node). Refused here instead of a session that burns its calls on it.
if jq -e --arg root "$(cd "${LEAN_CLAUDE_TMP:-/tmp/claude-$(id -u)}" 2>/dev/null && pwd -P)" \
     '$root != "" and (.sandbox.filesystem.denyRead | index($root))
      and ([.sandbox.filesystem.allowRead[] | select(startswith($root + "/"))] | length == 0)' \
     <<<"$settings" >/dev/null; then
  echo "lean: Claude Code's temp folder has no entry for $project the session could use (its Bash output would be unreadable); start any Claude Code session in the project once, or check the folder's permissions" >&2
  exit 1
fi
# Claude Code points the sandboxed Bash's TMPDIR at its own temp folder, which the sandbox
# denies (other sessions' scratchpads), so linkers and test runners fail there. A SessionStart
# hook re-exports TMPDIR to a fresh folder of this session's in the user temp dir (writable),
# added after any SessionStart hooks the settings already hold.
tmp_root="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)"; tmp_root="${tmp_root%/}"
session_tmp=$(mktemp -d "$tmp_root/lean-session.XXXXXX") && session_tmp=$(cd "$session_tmp" && pwd -P) \
  || { echo "lean: can't create the session temp folder in $tmp_root" >&2; exit 1; }
# Removed when this script ends (headless, or a refusal before the session); an interactive
# session replaces it (exec), so its folder stays for the OS to clear with the user temp dir.
trap 'chmod -R u+w "$session_tmp" 2>/dev/null; rm -rf "$session_tmp"' EXIT
env_lines="'export TMPDIR=$session_tmp/'"
# chrome-headless-shell (CHROME_BIN, else Puppeteer's copy in ~/.cache) can't register
# Chromium's rendezvous service under Claude Code's sandbox; --single-process skips it. The
# session gets CHROME_BIN pointing at a wrapper that adds the flag (the gate's own profile
# allows the service, so the gate runs the browser as the project configures it). A path
# holding a single quote is skipped (the wrapper quotes it in single quotes).
chrome="${CHROME_BIN:-}"
if [ -z "$chrome" ]; then
  for f in "$HOME"/.cache/chrome-headless-shell/chrome-headless-shell/*/chrome-headless-shell-*/chrome-headless-shell; do
    if [ -x "$f" ]; then chrome="$f"; fi
  done
fi
case "$chrome" in *"'"*) chrome= ;; esac
if [ -n "$chrome" ] && [ "$(basename "$chrome")" = chrome-headless-shell ] && [ -x "$chrome" ]; then
  mkdir -p "$session_tmp/bin"
  printf '#!/bin/sh\nexec %s --single-process "$@"\n' "'$chrome'" > "$session_tmp/bin/chrome-headless-shell"
  chmod +x "$session_tmp/bin/chrome-headless-shell"
  env_lines="$env_lines 'export CHROME_BIN=$session_tmp/bin/chrome-headless-shell'"
fi
# shellcheck source=../lib.sh
. "$LEAN_DIR/lib.sh"
# The toolchain caches (lean/lib.sh lean_toolchain_setup: GOCACHE, UV_CACHE_DIR, ... in the
# project's session cache folder outside $HOME, TMPPREFIX and the JVM's temp dir in the session
# TMPDIR): exported by the same hook, for the session's commands only (not Claude Code's own
# process), and the folder re-opened in allowRead and allowWrite (sandbox.sh denies the cache
# root: other projects' folders and the gate's stay closed).
lean_toolchain_setup "$project" "$session_tmp" session || exit 1
for kv in ${LEAN_TOOLCHAIN_ENV[@]+"${LEAN_TOOLCHAIN_ENV[@]}"}; do
  line="export ${kv%%=*}=$(printf '%q' "${kv#*=}")"
  env_lines="$env_lines '$(printf '%s' "$line" | sed "s/'/'\\\\''/g")'"
done
settings=$(jq -c --arg c "printf '%s\\n' $env_lines >> \"\$CLAUDE_ENV_FILE\"" --arg cache "$LEAN_CACHE_PATH" \
  '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{hooks: [{type: "command", command: $c}]}])
   | .sandbox.filesystem.allowRead += [$cache] | .sandbox.filesystem.allowWrite += [$cache]' <<<"$settings")
lean_env_args "$project" '^(ANTHROPIC_|CLAUDE_)' || exit 1
# LEAN_SESSION=1 marks the session (lean/lib.sh lean_in_session): ./init.sh, harness.sh test and
# the gate refuse to run the suite inside it, and ignore LEAN_GATE_UNSANDBOXED there (lean_env_args
# already drops that variable from the session).
cmd=(env "${LEAN_ENV_ARGS[@]}" LEAN_SESSION=1 "${cmd[@]}")

cd "$project"
case "$mode" in
  interactive)
    exec "${cmd[@]}" ${model_args[@]+"${model_args[@]}"} --settings "$settings" --permission-mode acceptEdits \
      --append-system-prompt-file "$system_file" "$prompt" ;;
  headless)
    [ -n "$result" ] || { echo "headless needs a result file" >&2; exit 2; }
    # LEAN_MAX_TURNS (run.sh, from lean.max_turns): claude -p's turn cap (--max-turns, a hidden
    # flag of Claude Code that only works with --print). When reached, the result JSON says
    # subtype "error_max_turns" and is_error.
    turn_args=()
    case "${LEAN_MAX_TURNS:-}" in
      '') ;;
      *[!0-9]*|0*) echo "LEAN_MAX_TURNS must be a positive integer: $LEAN_MAX_TURNS" >&2; exit 2 ;;
      *) turn_args=(--max-turns "$LEAN_MAX_TURNS") ;;
    esac
    "${cmd[@]}" -p "$prompt" ${model_args[@]+"${model_args[@]}"} ${turn_args[@]+"${turn_args[@]}"} --settings "$settings" --permission-mode bypassPermissions \
      --append-system-prompt-file "$system_file" --output-format json < /dev/null > "$result" ;;
  *) echo "mode must be interactive or headless" >&2; exit 2 ;;
esac
