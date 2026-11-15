#!/usr/bin/env bash
# lean_usage_test.sh — the lean flow's usage report (<lean state>/lean/<name>/usage.tsv), against
# a throwaway project with stub adapters in place of claude / claude-mini / codex (no model is
# ever called) and the suite run unsandboxed (LEAN_GATE_UNSANDBOXED=1).
#
#   1. claude -p JSON: model from modelUsage, turns, tokens summed over modelUsage, cost as
#      reported; without modelUsage the tokens come from usage and the model is the configured one.
#   2. claude-mini: the cost is left out (Claude Code's estimate at Anthropic prices); codex-shaped
#      JSON: cached tokens subtracted from input, no cost.
#   3. a missing or unreadable result JSON: "?" fields, the step's exit code unchanged.
#   4. interactive steps: a row with the duration and "interactive (not measured)"; an
#      interactive session's non-zero exit is still the step's exit code.
#   5. `run.sh usage <name>`: every row as a table with a sum; none recorded: a message, exit 0.
#   6. chain: the table of the sessions this chain opened, before the `next:` line (PASS) and
#      before CHAIN: FAIL, pointing at earlier rows.
#
# Usage: bash tests/lean_usage_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }
g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

mkdir -p "$WORK/home"
export HOME="$WORK/home" LEAN_CACHE_BASE="$WORK/cache-base" LEAN_GATE_UNSANDBOXED=1 GIT_CONFIG_GLOBAL=/dev/null
export LEAN_CLAUDE_TMP="$WORK/no-claude-tmp"
# The toolkit's lean/ with one stub for every adapter. Headless: runs $SCN/<step> in the project
# when present, then writes $STUB_JSON (a file) as the result, or nothing when it is "none".
# Interactive: exits $STUB_RC (default 0).
L="$WORK/lean"; cp -R "$TOOLKIT_DIR/lean" "$L"
export SCN="$WORK/scn" STUB_JSON="$WORK/result.json" STUB_RC=0
cat > "$L/adapters/claude.sh" <<'SH'
#!/usr/bin/env bash
project="$1" mode="$2" result="${6:-}"
[ "$mode" = headless ] || exit "$STUB_RC"
st=$(basename "$result"); st="${st#*.}"; st="${st%%.*}"
cd "$project" || exit 1
[ -f "$SCN/$st" ] && . "$SCN/$st"
[ "$STUB_JSON" = none ] || cat "$STUB_JSON" > "$result"
SH
chmod +x "$L/adapters/claude.sh"
cp "$L/adapters/claude.sh" "$L/adapters/claude-mini.sh"; cp "$L/adapters/claude.sh" "$L/adapters/codex.sh"

# The result JSONs: claude -p's shape (usage, modelUsage, cost) and codex.sh's.
cat > "$WORK/claude.json" <<'J'
{"type":"result","is_error":false,"num_turns":12,"duration_ms":250000,"total_cost_usd":0.4123,
 "usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"output_tokens":40},
 "modelUsage":{"claude-sonnet-5-5":{"inputTokens":1200,"outputTokens":8000,"cacheReadInputTokens":340000,"cacheCreationInputTokens":25000,"costUSD":0.4},
               "claude-haiku-5-5":{"inputTokens":300,"outputTokens":100,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"costUSD":0.0123}}}
J
cat > "$WORK/claude-nomu.json" <<'J'
{"type":"result","is_error":false,"num_turns":4,"total_cost_usd":0.05,
 "usage":{"input_tokens":11,"cache_read_input_tokens":22,"cache_creation_input_tokens":33,"output_tokens":44}}
J
cat > "$WORK/codex.json" <<'J'
{"type":"result","tool":"codex","is_error":false,"duration_ms":1000,"num_turns":3,"total_cost_usd":null,
 "usage":{"input_tokens":1200,"cache_read_input_tokens":500,"cache_creation_input_tokens":3,"output_tokens":70,"reasoning_output_tokens":7}}
J
printf 'not json\n' > "$WORK/garbage.json"

# new_project <dir> [harness] — a git repository whose suite passes once src/app.txt says done.
new_project() {
  local p="$1"
  mkdir -p "$p/src" "$p/tests" "$p/docs/features"
  echo '{"verify_command":"bash run_tests.sh","lean":{"implementer":"claude:claude-sonnet-5-5"}}' > "$p/.harness.json"
  cat > "$p/run_tests.sh" <<'T'
[ $# -gt 0 ] || set -- tests/*_test.sh
rc=0
for f in "$@"; do if bash "$f"; then echo " 1 pass"; else echo " 1 fail"; rc=1; fi; done
exit "$rc"
T
  printf 'grep -q done src/app.txt || { echo "FAIL: app_test expects done"; exit 1; }\n' > "$p/tests/app_test.sh"
  printf 'todo\n' > "$p/src/app.txt"
  printf '# f\n\n**Files**\n- `src/app.txt`\n' > "$p/docs/features/f.md"
  if [ "${2:-}" = harness ]; then
    mkdir -p "$p/scripts"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$p/scripts/harness.sh"
  fi
  printf '.harness.json\nscripts/\n' > "$p/.gitignore"
  g -C "$p" init -q && g -C "$p" add -A && g -C "$p" commit -qm base || die "project setup: $p"
}
lean_conf() { jq "$2" "$1/.harness.json" > "$WORK/h" && mv "$WORK/h" "$1/.harness.json"; }
state_of() { bash -c '. "$1/lean/lib.sh"; lean_state_dir "$2"' _ "$TOOLKIT_DIR" "$1"; }
repin() { rm -f "$(state_of "$1")/lean/f/trusted.sha"; }
tsv() { cat "$(state_of "$P")/lean/f/usage.tsv"; }
# row <n> — data row n (1-based) without its timestamp.
row() { awk -v n="$1" 'NR == n + 1' "$(state_of "$P")/lean/f/usage.tsv" | cut -f2-; }
run() { (cd "$P" && bash "$L/run.sh" "$@") > "$WORK/out" 2>&1; }
out() { cat "$WORK/out"; }
T=$'\t'

echo "1. claude JSON"
P="$WORK/p1"; new_project "$P"
cp "$WORK/claude.json" "$STUB_JSON"
run implement f --headless || die "implement: $(out)"
[ "$(tsv | head -1)" = "at${T}feature${T}step${T}mode${T}tool${T}model${T}turns${T}input${T}cache_read${T}cache_write${T}output${T}seconds${T}cost_usd${T}note" ] \
  || die "header: $(tsv | head -1)"
r=$(row 1)
case "$r" in "f${T}implement${T}normal${T}claude${T}claude-sonnet-5-5+claude-haiku-5-5${T}12${T}1500${T}340000${T}25000${T}8100${T}"[0-9]*"${T}0.4123${T}") ;;
  *) die "claude row: $r" ;; esac
cp "$WORK/claude-nomu.json" "$STUB_JSON"
run review f --headless || die "review: $(out)"
case "$(row 2)" in "f${T}review${T}normal${T}claude${T}claude-sonnet-5-5${T}4${T}11${T}22${T}33${T}44${T}"*"${T}0.05${T}") ;;
  *) die "claude row without modelUsage: $(row 2)" ;; esac
pass "claude: model from modelUsage, tokens summed over it, reported cost; no modelUsage: usage and the configured model"

echo "2. claude-mini and codex"
P="$WORK/p2"; new_project "$P"
lean_conf "$P" '.lean.implementer = "claude-mini" | .lean.reviewer = "codex:gpt-x"'
cp "$WORK/claude.json" "$STUB_JSON"
run implement f --headless || die "mini implement: $(out)"
case "$(row 1)" in *"${T}claude-mini${T}claude-sonnet-5-5+claude-haiku-5-5${T}12${T}1500${T}340000${T}25000${T}8100${T}"*"${T}-${T}") ;;
  *) die "claude-mini row (cost left out): $(row 1)" ;; esac
cp "$WORK/codex.json" "$STUB_JSON"
run review f --headless || die "codex review: $(out)"
case "$(row 2)" in "f${T}review${T}normal${T}codex${T}gpt-x${T}3${T}700${T}500${T}3${T}70${T}"*"${T}-${T}") ;;
  *) die "codex row (input without cached tokens, no cost): $(row 2)" ;; esac
pass "claude-mini: no cost; codex: cached tokens out of input, configured model, no cost"

echo "3. missing or unreadable result"
P="$WORK/p3"; new_project "$P"
STUB_JSON=none run implement f --headless || die "a missing result must not fail the step: $(out)"
case "$(row 1)" in *"${T}?${T}?${T}?${T}?${T}?${T}"*"${T}?${T}no readable result JSON") ;; *) die "missing result row: $(row 1)" ;; esac
cp "$WORK/garbage.json" "$STUB_JSON"
run implement f --headless || die "an unreadable result must not fail the step: $(out)"
case "$(row 2)" in *"${T}claude-sonnet-5-5${T}?${T}?${T}"*"no readable result JSON") ;; *) die "garbage result row: $(row 2)" ;; esac
pass "a missing or unreadable result JSON: '?' fields, exit 0 as before"

echo "4. interactive"
run implement f || die "interactive implement: $(out)"
case "$(row 3)" in "f${T}implement${T}normal${T}claude${T}claude-sonnet-5-5${T}-${T}-${T}-${T}-${T}-${T}"[0-9]*"${T}-${T}interactive (not measured)") ;;
  *) die "interactive row: $(row 3)" ;; esac
STUB_RC=7 run implement f; rc=$?
[ "$rc" = 7 ] || die "an interactive session's exit code is the step's: $rc / $(out)"
[ "$(awk 'NR > 1' "$(state_of "$P")/lean/f/usage.tsv" | wc -l | tr -d ' ')" = 4 ] || die "row recorded on a failed interactive session: $(tsv)"
pass "interactive: duration only, 'interactive (not measured)'; a non-zero exit kept"

echo "5. run.sh usage"
P="$WORK/p1"
run usage f || die "usage: $(out)"
grep -q '^usage (f: 2 sessions):$' "$WORK/out" || die "usage title: $(out)"
grep -Eq '^  step +mode +tool +model +turns +in +c\.read +c\.write +out +time +cost$' "$WORK/out" || die "usage header: $(out)"
grep -Eq '^  implement normal claude +claude-sonnet-5-5\+claude +12 +1\.5k +340\.0k +25\.0k +8\.1k +[0-9]+m[0-9]{2}s +\$0\.41$' "$WORK/out" || die "usage implement line: $(out)"
grep -Eq '^  sum +16 +1\.5k +340\.0k +25\.0k +8\.1k +[0-9]+m[0-9]{2}s +\$0\.46$' "$WORK/out" || die "usage sum: $(out)"
grep -q '^rows: .*/lean/f/usage\.tsv$' "$WORK/out" || die "usage path: $(out)"
[ "$(wc -l < "$WORK/out" | tr -d " ")" = 6 ] || die "usage output lines: $(out)"
P="$WORK/p3"
run usage f || die "usage p3: $(out)"
grep -Eq '^  sum +\? +\? +\? +\? +\? +[0-9]+m[0-9]{2}s +-$' "$WORK/out" || die "sum without numbers is '?', no cost: $(out)"
grep -q 'interactive (not measured)$' "$WORK/out" || die "interactive note in the table: $(out)"
P="$WORK/p4"; new_project "$P"
run usage f || die "usage with no rows must exit 0: $(out)"
grep -q '^no usage recorded for f (' "$WORK/out" || die "no rows message: $(out)"
run usage 'f/x' && die "a bad name must exit 2"
pass "usage: every row, a sum ('?' when no number), the TSV path; none recorded: a message, exit 0"

echo "6. chain"
P="$WORK/p5"; new_project "$P" harness
cp "$WORK/claude.json" "$STUB_JSON"
run implement f --headless || die "manual implement before the chain: $(out)"
mkdir -p "$SCN"; printf 'printf "done\\n" > src/app.txt\n' > "$SCN/implement"
run chain f || die "chain should pass: $(out)"
[ "$(tail -1 "$WORK/out")" = "CHAIN: PASS" ] || die "chain last line: $(out)"
tail -7 "$WORK/out" | head -1 | grep -q '^usage (f: 2 sessions; 1 earlier: lean/run.sh usage f):$' || die "table title before the rows: $(out)"
tail -3 "$WORK/out" | head -1 | grep -Eq '^  sum +24 ' || die "the sum covers this chain's sessions: $(out)"
tail -2 "$WORK/out" | head -1 | grep -q '^next: ' || die "the table comes right before next:: $(out)"
grep -c '^  implement normal' "$WORK/out" | grep -qx 1 || die "only this chain's implement row: $(out)"
rm -rf "$SCN"; g -C "$P" checkout -q -- src/app.txt
run chain f && die "chain should fail without a fix: $(out)"
grep -q '^CHAIN: FAIL at gate' "$WORK/out" || die "fail line: $(out)"
grep -q '^usage (f: 3 sessions; 3 earlier: lean/run.sh usage f):$' "$WORK/out" || die "table on FAIL: $(out)"
tail -2 "$WORK/out" | head -1 | grep -Eq '^  sum ' || die "the table comes right before CHAIN: FAIL: $(out)"
pass "chain: this chain's sessions as a table before next: (PASS) or CHAIN: FAIL, earlier rows pointed at"

echo "lean_usage_test: $PASS passed"
