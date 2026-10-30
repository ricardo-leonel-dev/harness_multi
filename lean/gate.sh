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
#   5. nothing changed outside <project_dir> when it is a subfolder of its repository (a
#      changed or untracked, non-ignored file there fails, named by its repository-root path).
# Paths in the document and the manifests are relative to <project_dir>, which may be a
# subfolder of its repository. One rule reads them: a path names <project_dir>/<path>; only
# when nothing is at that path (no file on disk, no change in git) and it starts with the
# project's prefix (`git rev-parse --show-prefix`, e.g. services/api/) is it read from the
# repository root instead, which keeps it inside <project_dir>. So with prefix p/, `p/x`
# means the project's p/x when that exists or changed, else the project's x.
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
prefix=$(git rev-parse --show-prefix 2>/dev/null || true)
top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# collect_changes — every changed or untracked, non-ignored file of the repository, from its
# root (git diff without --relative); split into the ones inside the project (changed_rel,
# relative to it) and the ones outside it (changed_outside, from the root).
collect_changes() {
  local root
  root=$( { git diff --name-only "$base"; git -C "$top" ls-files --others --exclude-standard; } | sed '/^$/d' | sort -u)
  changed_rel=$(awk -v p="$prefix" 'p == "" || index($0, p) == 1 { print substr($0, length(p) + 1) }' <<<"$root")
  changed_outside=$(awk -v p="$prefix" 'p != "" && index($0, p) != 1' <<<"$root")
}
collect_changes
# to_project_relative — a listed path, per the rule in the header: kept when the project has
# something at it, otherwise read from the repository root when it starts with the prefix.
to_project_relative() {
  local l
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ -n "$prefix" ] && [ "${l#"$prefix"}" != "$l" ] && [ ! -e "$l" ] && [ ! -L "$l" ] \
       && ! grep -qxF -- "$l" <<<"$changed_rel"; then
      printf '%s\n' "${l#"$prefix"}"
    else
      printf '%s\n' "$l"
    fi
  done
}
# manifest_paths <manifest> — the paths of a shasum manifest, relative to the project.
manifest_raw() { awk 'NF { sub(/^[^ ]+ [ *]/, ""); print }' "$@"; }
manifest_paths() { manifest_raw "$@" | to_project_relative; }
doc="docs/features/$name.md"
verify=$(jq -r '.verify_command // empty' .harness.json 2>/dev/null)
acc_dir=$(jq -r '.lean.acceptance_dir // "acceptance"' .harness.json 2>/dev/null)
acc_dir="${acc_dir%/}"
slug=$(jq -r '.project_slug // empty' .harness.json 2>/dev/null); slug="${slug:-$(basename "$PWD")}"
# Other features' frozen acceptance files (their manifests sit next to this one's): left
# uncommitted, they are not this feature's changes; their own gate checks them.
other_frozen=$(find "$HOME/.cache/harness/$slug/frozen" -name '*.sha' ! -name "$name.sha" -exec cat {} + 2>/dev/null | manifest_paths | sort -u)
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
    # The same manifest with project-relative paths, so shasum -c and the comparisons
    # below read it from here.
    frozen_rel=$(mktemp); trap 'rm -f "$frozen_rel"' EXIT
    paste -d ' ' <(awk 'NF { print $1 " " }' "$frozen") <(manifest_paths "$frozen") > "$frozen_rel"
    frozen_paths=$(manifest_raw "$frozen_rel")
    bad=$(shasum -c "$frozen_rel" 2>&1 | grep -v ': OK$' || true)
    # Anything else that changed in the acceptance directory (a file added next to this
    # feature's), other features' frozen files aside.
    acc_changed=$( { git diff --name-only --relative "$base" -- "$acc_dir"; git ls-files --others --exclude-standard -- "$acc_dir"; } | sort -u)
    extra=$(comm -23 <(printf '%s\n' "$acc_changed" | sed '/^$/d') <( printf '%s\n' "$frozen_paths" "$other_frozen" | sed '/^$/d' | sort -u))
    if [ -n "$bad$extra" ]; then
      fail=1
      echo "FROZEN ACCEPTANCE TESTS CHANGED (restore them exactly; object in the document instead):"
      printf '%s\n' "$bad" "$extra" | sed '/^$/d'
    fi
    if ! acc_out=$(bash -c "$verify $(tr '\n' ' ' <<<"$frozen_paths")" 2>&1); then
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
    | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' | to_project_relative | sort -u
}
collect_changes   # again: the suite may have left files behind
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
  frozen_files=$(printf '%s\n' "${frozen_paths:-}" "$other_frozen")
  changed=$(printf '%s\n' "$changed_rel" \
    | grep -vE "^docs/features/|^progress/|^state/" | { grep -vxF -f <(printf '%s\n' "$frozen_files" | sed '/^$/d') || true; } | sort -u)
  outside=$(comm -23 <(printf '%s\n' "$changed" | sed '/^$/d') <(printf '%s\n' "$listed" | sed '/^$/d'))
  if [ -n "$outside" ]; then
    fail=1
    echo "CHANGED BUT NOT LISTED UNDER **Files** IN $doc (undo the change, or list the file with a reason):"
    echo "$outside"
  fi
fi

if [ -n "$changed_outside" ]; then
  fail=1
  echo "CHANGED OUTSIDE THE PROJECT DIRECTORY $prefix (paths from the repository root; undo the change):"
  echo "$changed_outside"
fi

[ "$fail" = 0 ] && echo "ALL CHECKS PASS"
exit "$fail"
