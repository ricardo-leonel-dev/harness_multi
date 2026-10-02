#!/usr/bin/env bash
# scripts/lint_test_fingerprints.sh
# Detect anti-pattern: byte-level fingerprints of stored procedure bodies
# in acceptance tests. A fingerprint (e.g., md5(pg_get_functiondef(...)))
# trips on every legitimate modification to the function body, forcing
# unnecessary test churn and creating silent stale-MD5 traps when ignored.
#
# See templates/docs/conventions.md.tmpl "Acceptance test anti-patterns" for
# the rationale this linter enforces.
#
# Usage: bash scripts/lint_test_fingerprints.sh [tests-dir]
#   Defaults to ./tests if no argument given.
# Exit codes:
#   0 = clean (no fingerprints)
#   1 = at least one fingerprint detected
#   2 = tests directory not found (warning, not failure)

set -u

TESTS_DIR="${1:-tests}"

if [ ! -d "$TESTS_DIR" ]; then
    echo "[WARN] tests directory '$TESTS_DIR' not found; skipping fingerprint lint"
    exit 2
fi

LINT_FAILED=0
# Match any hash function called on pg_get_functiondef(...). Tolerate whitespace.
PATTERN='[a-z0-9]{2,}\s*\(\s*pg_get_functiondef\s*\('

while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Format: file:linenum:content (from grep -n)
    file=$(printf '%s' "$line" | cut -d: -f1)
    line_num=$(printf '%s' "$line" | cut -d: -f2)
    content=$(printf '%s' "$line" | cut -d: -f3-)
    echo "[FAIL] $file:$line_num — byte-level fingerprint of stored procedure body"
    echo "       $content"
    echo "       See docs/conventions.md#acceptance-test-anti-patterns-for-db-schema-projects"
    LINT_FAILED=1
done < <(grep -rEn "$PATTERN" "$TESTS_DIR" --include='*.sql' 2>/dev/null)

if [ "$LINT_FAILED" -eq 0 ]; then
    echo "[OK]   No byte-level fingerprints detected in $TESTS_DIR/"
fi

exit $LINT_FAILED
