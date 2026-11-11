#!/usr/bin/env bash
# codex-m3.sh — the codex.sh adapter on MiniMax: the resolved codex binary with
# `--profile ${LEAN_CODEX_M3_PROFILE:-minimax}` (what the user's codex-m3 fish function adds), the
# model argument ignored (the profile picks it). Not through fish: codex.sh "codex-m3".
exec env LEAN_RUNNER=m3 "$(dirname "$0")/codex.sh" "$@"
