#!/usr/bin/env bash
# gen_agents.sh — regenerate .claude/agents/*.md and .codex/agents/*.toml from the
# canonical sources in .agents/*.md. Run this after editing any .agents/<name>.md.
#
# This is a toolkit-maintenance tool, not part of the installed harness: install.sh
# does not copy it into target projects (it copies whatever .claude/agents/*.md and
# .codex/agents/*.toml already contain here, regardless of how they were produced),
# and it deliberately doesn't live under scripts/ (which install.sh does copy wholesale).
#
# Frontmatter format (single-line key: value only — this script's parser is intentionally
# simple, not a full YAML parser):
#   name: <agent name>
#   description: <one-line description>
#   tools: <comma-separated, Claude Code only>
#   sandbox_mode: <Codex CLI only>
#
# Body tags (each on its own line, prefix stripped in the target it belongs to, line
# dropped entirely from the other target):
#   <!--claude-only--> ...   -> Claude Code output only
#   <!--codex-only--> ...    -> Codex CLI output only
#   (untagged lines go to both)

set -euo pipefail
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$TOOLKIT_DIR/.agents"
CLAUDE_DIR="$TOOLKIT_DIR/.claude/agents"
CODEX_DIR="$TOOLKIT_DIR/.codex/agents"

mkdir -p "$CLAUDE_DIR" "$CODEX_DIR"

shopt -s nullglob
for src in "$SRC_DIR"/*.md; do
  name="$(basename "$src" .md)"

  frontmatter="$(awk '/^---$/{c++; next} c==1{print}' "$src")"
  body="$(awk '/^---$/{c++; next} c>=2{print}' "$src")"

  description="$(printf '%s\n' "$frontmatter" | sed -n 's/^description: //p')"
  tools="$(printf '%s\n' "$frontmatter" | sed -n 's/^tools: //p')"
  sandbox_mode="$(printf '%s\n' "$frontmatter" | sed -n 's/^sandbox_mode: //p')"

  claude_body="$(printf '%s\n' "$body" | awk '
    /^<!--codex-only-->/  { next }
    /^<!--claude-only-->/ { sub(/^<!--claude-only-->/, ""); print; next }
    { print }
  ')"

  {
    echo "---"
    echo "name: $name"
    echo "description: $description"
    echo "tools: $tools"
    echo "---"
    echo ""
    echo "<!-- GENERATED FILE — do not edit directly. Source: .agents/$name.md, regenerate with ./gen_agents.sh -->"
    echo ""
    printf '%s\n' "$claude_body"
  } > "$CLAUDE_DIR/$name.md"

  codex_body="$(printf '%s\n' "$body" | awk '
    /^<!--claude-only-->/ { next }
    /^<!--codex-only-->/  { sub(/^<!--codex-only-->/, ""); print; next }
    { print }
  ')"

  {
    echo "# GENERATED FILE — do not edit directly. Source: .agents/$name.md, regenerate with ./gen_agents.sh"
    echo "#"
    echo "# NOTE ON sandbox_mode: Codex has no per-tool allowlist like Claude Code's tools: frontmatter"
    echo "# (e.g. Claude Code's reviewer has no Edit/Write tool at all — a runtime guarantee Codex can't"
    echo "# give). Rules like \"never edit src/tests\" or \"never edit the implementer's code\" are enforced"
    echo "# by developer_instructions text only here, not the runtime sandbox."
    echo ""
    echo "name = \"$name\""
    echo "description = \"$description\""
    echo "sandbox_mode = \"$sandbox_mode\""
    echo ""
    echo "developer_instructions = '''"
    printf '%s\n' "$codex_body"
    echo "'''"
  } > "$CODEX_DIR/$name.toml"

  printf 'generated .claude/agents/%s.md + .codex/agents/%s.toml from .agents/%s.md\n' "$name" "$name" "$name"
done
