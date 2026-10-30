#!/usr/bin/env bash
# gate.sh — the lean flow's closing checks, run by a script instead of an agent (no tokens).
#
#   lean/gate.sh <project_dir> <feature_name> [--base <rev>] [--frozen <manifest>]
#
# Checks the uncommitted work against <rev> (default HEAD):
#   1. .harness.json::verify_command passes;
#   2. no assertion line was removed from a test file that existed at <rev>, unless the
#      file is listed under **Changed tests** in docs/features/<name>.md;
#   3. every changed file is listed under **Files** (the plan files, frozen acceptance files
#      — this feature's and other features' — and the harness's progress/ and state/ excepted);
#   4. with --frozen (risk mode): the acceptance files match the manifest, nothing else
#      changed in the acceptance directory, and the acceptance tests pass.
# Prints a short report; exits 1 when any check fails, 2 on a usage error.
set -uo pipefail

project="${1:-}"; name="${2:-}"
[ -n "$project" ] && [ -n "$name" ] || { echo "usage: lean/gate.sh <project_dir> <feature_name> [--base <rev>] [--frozen <manifest>]" >&2; exit 2; }
shift 2
base=HEAD; frozen=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --frozen) frozen="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$project" || exit 2
doc="docs/features/$name.md"
verify=$(jq -r '.verify_command // empty' .harness.json 2>/dev/null)
acc_dir=$(jq -r '.lean.acceptance_dir // "acceptance"' .harness.json 2>/dev/null)
acc_dir="${acc_dir%/}"
slug=$(jq -r '.project_slug // empty' .harness.json 2>/dev/null); slug="${slug:-$(basename "$PWD")}"
# Other features' frozen acceptance files (their manifests sit next to this one's): left
# uncommitted, they are not this feature's changes; their own gate checks them.
other_frozen=$(find "$HOME/.cache/harness/$slug/frozen" -name '*.sha' ! -name "$name.sha" -exec awk '{print $2}' {} + 2>/dev/null | sort -u)
[ -n "$verify" ] || { echo "no verify_command in .harness.json" >&2; exit 2; }
fail=0

if ! suite_out=$(bash -c "$verify" 2>&1); then
  fail=1
  echo "SUITE FAILS:"
  { grep -E '^\(fail\)|FAIL|✗' <<<"$suite_out" || tail -15 <<<"$suite_out"; } | head -20
fi

if [ -n "$frozen" ]; then
  if [ ! -f "$frozen" ]; then
    fail=1
    echo "FROZEN MANIFEST MISSING: $frozen"
  else
    bad=$(shasum -c "$frozen" 2>&1 | grep -v ': OK$' || true)
    # Anything else that changed in the acceptance directory (a file added next to this
    # feature's), other features' frozen files aside.
    acc_changed=$( { git diff --name-only "$base" -- "$acc_dir"; git ls-files --others --exclude-standard -- "$acc_dir"; } | sort -u)
    extra=$(comm -23 <(printf '%s\n' "$acc_changed" | sed '/^$/d') <( { awk '{print $2}' "$frozen"; printf '%s\n' "$other_frozen"; } | sed '/^$/d' | sort -u))
    if [ -n "$bad$extra" ]; then
      fail=1
      echo "FROZEN ACCEPTANCE TESTS CHANGED (restore them exactly; object in the document instead):"
      printf '%s\n' "$bad" "$extra" | sed '/^$/d'
    fi
    if ! acc_out=$(bash -c "$verify $(awk '{print $2}' "$frozen" | tr '\n' ' ')" 2>&1); then
      fail=1
      echo "ACCEPTANCE TESTS FAIL:"
      { grep -E '^\(fail\)|FAIL|✗' <<<"$acc_out" || tail -15 <<<"$acc_out"; } | head -20
    fi
  fi
fi

# section_paths <title> — paths named under that section of the doc (bullets and backticks stripped).
section_paths() {
  [ -f "$doc" ] || return 0
  awk -v t="$1" '/^#+ |^- \*\*|^\*\*/ { in_sec = (index($0, t) > 0) } in_sec' "$doc" \
    | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' | sort -u
}
changed_tests=$(section_paths "Changed tests")

# Test files that existed at the base revision (any common test naming).
existing_tests=$(git ls-tree -r --name-only "$base" | grep -E '(\.test|\.spec|_test)\.[A-Za-z]+$|(^|/)test_[^/]+\.py$' || true)
while IFS= read -r t; do
  [ -n "$t" ] || continue
  removed=$(git diff "$base" -- "$t" | grep -E '^-' | grep -vE '^---' | grep -E 'expect\(|assert|test\(|it\(' || true)
  [ -n "$removed" ] || continue
  if grep -qxF "$t" <<<"$changed_tests"; then
    echo "note: $t changes existing assertions (listed under **Changed tests**)"
  else
    fail=1
    echo "ASSERTION LINES REMOVED FROM $t, which is not listed under **Changed tests** in $doc"
    echo "(restore them, or, if the feature changes what they pin, list the file there with the reason):"
    head -10 <<<"$removed"
  fi
done <<<"$existing_tests"

if [ ! -f "$doc" ]; then
  fail=1
  echo "MISSING: $doc"
else
  listed=$(section_paths "Files")
  # Frozen acceptance files are the plan's, not the implementer's (this feature's and others').
  frozen_files=$( { [ -n "$frozen" ] && [ -f "$frozen" ] && awk '{print $2}' "$frozen"; printf '%s\n' "$other_frozen"; } || true)
  changed=$( { git diff --name-only "$base"; git ls-files --others --exclude-standard; } \
    | grep -vE "^docs/features/|^progress/|^state/" | { grep -vxF -f <(printf '%s\n' "$frozen_files" | sed '/^$/d') || true; } | sort -u)
  outside=$(comm -23 <(printf '%s\n' "$changed" | sed '/^$/d') <(printf '%s\n' "$listed" | sed '/^$/d'))
  if [ -n "$outside" ]; then
    fail=1
    echo "CHANGED BUT NOT LISTED UNDER **Files** IN $doc (undo the change, or list the file with a reason):"
    echo "$outside"
  fi
fi

[ "$fail" = 0 ] && echo "ALL CHECKS PASS"
exit "$fail"
