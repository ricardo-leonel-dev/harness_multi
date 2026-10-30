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

cd "$project"
case "$mode" in
  interactive)
    exec "${cmd[@]}" "${model_args[@]}" --settings "$settings" --permission-mode acceptEdits \
      --append-system-prompt-file "$system_file" "$prompt" ;;
  headless)
    [ -n "$result" ] || { echo "headless needs a result file" >&2; exit 2; }
    "${cmd[@]}" -p "$prompt" "${model_args[@]}" --settings "$settings" --permission-mode bypassPermissions \
      --append-system-prompt-file "$system_file" --output-format json < /dev/null > "$result" ;;
  *) echo "mode must be interactive or headless" >&2; exit 2 ;;
esac
