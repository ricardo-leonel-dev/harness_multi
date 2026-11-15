#!/usr/bin/env bash
# lean_leader_actions_parse_test.sh — lean/lib.sh lean_leader_actions, the reading of a plan's (or
# review report's) **Leader actions** section, on markdown written in the styles sessions use:
# an item is never dropped silently (a line that can't be read as one counts as open, named so).
#
#   bold-starting bullets are items (and don't end the section); a section under a `#` heading
#   ends only at a heading of the same or a higher level (sub-headings and bold-only lines are
#   notes); a bullet-style section (`- **Leader actions**`) ends at a bold line naming exactly
#   another plan section; fenced code is skipped (a `# comment` in it ends nothing, an example
#   section in it is no section; a fence closes only at a run of its own character at least as
#   long as the opening one); numbered items count; CRLF line ends;
#   sub-bullets and indented lines belong to their item; none / n/a; other boxes are open;
#   several sections and files (the file is in each line); a last line without a newline.
#
# Usage: bash tests/lean_leader_actions_parse_test.sh   (LEAN_LIB=<lib.sh> to test another copy)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=../lean/lib.sh
. "${LEAN_LIB:-$TOOLKIT_DIR/lean/lib.sh}"

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

# check <label> <markdown (printf format)> <expected lines, "<state> <text>", one per line>
check() {
  local got want
  printf -- "$2" > "$WORK/doc.md"
  got=$(cd "$WORK" && lean_leader_actions doc.md | awk -F'\t' '{ print $1 " " $3 }')
  want=$(printf '%s' "$3")
  [ "$got" = "$want" ] || die "$1
--- want
$want
--- got
$got"
  pass "$1"
}

check "plain checkboxes" \
  '# f\n\n## Leader actions\n- [ ] one\n- [x] two (done: x)\n- [X] three\n' \
  'open one
done two (done: x)
done three'

check "a bold-starting bullet is an item and doesn't end the section" \
  '## Leader actions\n- **verify_command**: add tests/x.sh\n- [ ] second\n- **Files** needed: src/o.ts\n- [ ] third\n' \
  'open **verify_command**: add tests/x.sh
open second
open **Files** needed: src/o.ts
open third'

check "under a # heading, a bold bullet naming a plan section is an item, not the end" \
  '## Leader actions\n- **Acceptance command**: set lean.acceptance_command to x\n- [ ] second\n- **Steps**: run npm install\n- **Files**: src/extra.ts is needed too\n- [ ] last\n' \
  'open **Acceptance command**: set lean.acceptance_command to x
open second
open **Steps**: run npm install
open **Files**: src/extra.ts is needed too
open last'

check "under a # heading, sub-headings and bold-only lines are notes" \
  '## Leader actions\n### From the implementer\n- [ ] a\n### From the reviewer\n- [ ] b\n**Risks**\n- [x] c\n#### deeper\n- [ ] d\n## Steps\n- [ ] step\n' \
  'open a
open b
done c
open d'

check "a # section ends at a heading of the same or a higher level" \
  '### Leader actions\n- [ ] a\n#### detail\n- [ ] b\n### Decisions\n- [ ] not mine\n## Leader actions\n- [ ] c\n# Top\n- [ ] not mine either\n' \
  'open a
open b
open c'

check "a bullet-style section ends at a bold line naming exactly another plan section" \
  '**Leader actions**\n- [ ] a\n- **Acceptance command**: x\n- **Risks**: n/a\n- [ ] risk answer\n- **Leader actions**\n- [ ] b\n**Steps**\n- [ ] step\n' \
  'open a
open **Acceptance command**: x
open b'

check "a fence of 4+ backticks closes only at as many backticks of the same kind" \
  '## Leader actions\n- [ ] before\n````md\n```\n# not a heading\n~~~~\n- [ ] in the fence\n```\n````\n- [ ] after\n~~~~\n````\n~~~\n- [ ] still fenced\n~~~~~\n- [ ] last\n' \
  'open before
open after
open last'

check "fenced code: its lines are no headings or items, the section goes on after it" \
  '## Leader actions\n- [ ] before\n```sh\n# a shell comment\n- [ ] in the fence\n```\n- [ ] after fence\n~~~\n## x\n~~~\n- [ ] after tilde fence\n' \
  'open before
open after fence
open after tilde fence'

check "an example section inside a fence elsewhere is no section" \
  '# f\n\n```md\n## Leader actions\n- [ ] phantom\n```\n\n## Steps\n- [ ] step\n' \
  ''

check "numbered items" \
  '## Leader actions\n1. [ ] first\n2) [x] second\n10. third\n' \
  'open first
done second
open third'

check "CRLF line ends" \
  '## Leader actions\r\n- none\r\n- [ ]\r\n- [ ] crlf item\r\n- [x] done item\r\n' \
  'open crlf item
done done item'

check "sub-bullets and indented lines belong to their item" \
  '## Leader actions\n- [x] parent (done: yes)\n  - sub detail\n    a wrapped line\n  1. [ ] numbered detail\n- [ ] next\n\tdetail with a tab\n' \
  'done parent (done: yes)
open next'

check "a section written as indented sub-bullets of - **Leader actions**" \
  '- **Files**: src/a.ts\n- **Leader actions**\n  - [ ] set verify_command\n  - [x] installed libfoo\n    - how: brew\n- **Risks**: n/a\n' \
  'open set verify_command
done installed libfoo'

check "none / n/a are skipped, other boxes are open" \
  '## Leader actions\n- none\n- N/A.\n- [ ] none\n- [~] half done\n- [-] dropped?\n' \
  'open [~] half done
open [-] dropped?'

check "a line that looks like an item but can't be read counts as open, named so" \
  '## Leader actions\n-[ ] no space\n[ ] no bullet\n• unicode bullet\nPlain prose is not an item.\n' \
  'open (not read as an item: fix its format) -[ ] no space
open (not read as an item: fix its format) [ ] no bullet
open (not read as an item: fix its format) • unicode bullet'

check "bold notes inside the section don't end it" \
  '## Leader actions\n**Note**\n- [ ] after the note\n' \
  'open after the note'

check "several sections; the next heading ends one" \
  '## Leader actions\n- [ ] a\n## Decisions while implementing\n- not an item\n### Leader actions (more)\n- [ ] b\n' \
  'open a
open b'

check "a last line without a newline" \
  '## Leader actions\n- [ ] eof item' \
  'open eof item'

# The file is in each line; files without the section, or missing, print nothing.
printf '## Leader actions\n- [ ] in plan\n' > "$WORK/a.md"
printf '# report\n## Leader actions\n- [ ] in report\nVERDICT: approve\n' > "$WORK/a.review.md"
printf '# no section\n- [ ] x\n' > "$WORK/b.md"
got=$(cd "$WORK" && lean_leader_actions a.md b.md missing.md a.review.md)
[ "$got" = "$(printf 'open\ta.md\tin plan\nopen\ta.review.md\tin report')" ] || die "file column: $got"
pass "each line names its file; no section or no file: nothing"

echo "PASS: $PASS checks"
