#!/usr/bin/env bash
# claude-mini.sh — the claude.sh adapter on MiniMax, through the user's claude-mini fish function.
exec env LEAN_RUNNER=mini "$(dirname "$0")/claude.sh" "$@"
