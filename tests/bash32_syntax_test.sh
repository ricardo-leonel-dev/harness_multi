#!/usr/bin/env bash
# bash32_syntax_test.sh — every shell script of the toolkit parses under /bin/bash, which on macOS
# is bash 3.2 (the oldest bash the harness supports: init.sh, lean/chain.sh). A suite run with a
# newer bash first on PATH would not notice a construct 3.2 can't parse (a `case` pattern with an
# unbalanced `)` inside `$(...)`, say), and the script would then abort at parse time. Parsing
# only (`bash -n`): nothing runs. Skipped when there is no /bin/bash.
#
# Usage: bash tests/bash32_syntax_test.sh

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -x /bin/bash ] || { echo "SKIP: no /bin/bash"; exit 0; }
echo "/bin/bash: $(/bin/bash -c 'echo "$BASH_VERSION"')"

n=0 bad=""
for f in "$TOOLKIT_DIR"/install.sh "$TOOLKIT_DIR"/init.sh "$TOOLKIT_DIR"/lean/*.sh "$TOOLKIT_DIR"/lean/*/*.sh \
  "$TOOLKIT_DIR"/scripts/*.sh "$TOOLKIT_DIR"/tests/*.sh; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  err=$(/bin/bash -n "$f" 2>&1) || bad="$bad
  ${f#"$TOOLKIT_DIR"/}: $err"
done
[ -z "$bad" ] || { echo "FAIL: these don't parse under /bin/bash:$bad" >&2; exit 1; }
echo "PASS: $n scripts parse under /bin/bash"
