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
settings=$(jq -c --arg c "printf 'export TMPDIR=%s/\\n' '$session_tmp' >> \"\$CLAUDE_ENV_FILE\"" \
  '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{hooks: [{type: "command", command: $c}]}])' <<<"$settings")
# shellcheck source=../lib.sh
. "$LEAN_DIR/lib.sh"
lean_env_args "$project" '^(ANTHROPIC_|CLAUDE_)' || exit 1
cmd=(env "${LEAN_ENV_ARGS[@]}" "${cmd[@]}")

cd "$project"
case "$mode" in
  interactive)
    exec "${cmd[@]}" ${model_args[@]+"${model_args[@]}"} --settings "$settings" --permission-mode acceptEdits \
      --append-system-prompt-file "$system_file" "$prompt" ;;
  headless)
    [ -n "$result" ] || { echo "headless needs a result file" >&2; exit 2; }
    "${cmd[@]}" -p "$prompt" ${model_args[@]+"${model_args[@]}"} --settings "$settings" --permission-mode bypassPermissions \
      --append-system-prompt-file "$system_file" --output-format json < /dev/null > "$result" ;;
  *) echo "mode must be interactive or headless" >&2; exit 2 ;;
esac
