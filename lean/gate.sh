#!/usr/bin/env bash
# gate.sh — the lean flow's closing checks, run by a script instead of an agent (no tokens).
#
#   lean/gate.sh <project_dir> <feature_name> [--base <rev>] [--frozen <manifest>]
#
# Checks the uncommitted work against <rev> (default HEAD):
#   0. HEAD is still <rev>: sessions never commit, so a moved HEAD means one did (or the work
#      was committed before closing), and committed work would escape the checks below;
#   1. .harness.json::verify_command passes;
#   2. no assertion line was removed from a test file that existed at <rev>, unless the
#      file is listed under **Changed tests** in docs/features/<name>.md;
#   3. every changed file is listed under **Files** (the plan files, frozen acceptance files
#      — this feature's and other features' — and the harness's progress/ and state/ excepted);
#   4. with --frozen (risk mode): the acceptance files match the manifest, nothing else
#      changed in the acceptance directory, and the acceptance tests pass.
#   5. nothing changed outside <project_dir> when it is a subfolder of its repository (a
#      changed or untracked, non-ignored file there fails, named by its repository-root path);
#   6. one pass over every path in the project, git-ignored ones included: no nested CLAUDE.md /
#      CLAUDE.local.md (any case) and no file in a nested .claude/ folder is there unless git
#      tracks it unchanged at <rev>; no path holds a newline; and every folder can be listed
#      (read and search permission, find without error).
# File names stay NUL-separated from git and find to these checks (-z), so a name with a
# newline or a non-ASCII one (core.quotePath) is never split or quoted.
# Paths in the document and the manifests are relative to <project_dir>, which may be a
# subfolder of its repository. One rule reads them: a path names <project_dir>/<path>; only
# when nothing is at that path (no file on disk, no change in git) and it starts with the
# project's prefix (`git rev-parse --show-prefix`, e.g. services/api/) is it read from the
# repository root instead, which keeps it inside <project_dir>. So with prefix p/, `p/x`
# means the project's p/x when that exists or changed, else the project's x.
# Git output is pinned to repository-root paths (--no-relative), whatever diff.relative says.
# The suite and the acceptance tests are code the sessions wrote: they run under the
# sessions' sandbox rules (lean/lib.sh lean_sandboxed: sandbox-exec on macOS). Where that is not available (no sandbox-exec, or
# LEAN_GATE_UNSANDBOXED=1) they run unsandboxed and the report says so with a [WARN] line;
# when sandbox-exec is there but can't apply the profile (already inside a sandbox) the gate
# fails instead. sandbox.sh's [WARN] lines (lean.allowed_domains opening the network) are
# part of the report, so run.sh gate and log-out --lean show them. The commands run in a new
# session without a terminal, stdin or inherited descriptors, their process group killed when
# they end (with a [WARN] in the report when something was still running), without
# secret-looking environment variables (lean/lib.sh lean_sandboxed).
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
project="$(pwd)"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
base_sha=$(git rev-parse --verify --quiet "$base^{commit}" 2>/dev/null) \
  || { echo "not a commit in this repository: --base $base" >&2; exit 2; }
head_sha=$(git rev-parse --verify --quiet HEAD 2>/dev/null || true)
prefix=$(git rev-parse --show-prefix 2>/dev/null || true)
top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# z_lines — NUL-separated names on stdin, one per line; a name holding a newline is printed
# quoted (printf %q), so it stays one line, matches no listed path and fails the check it is in
# (check 6 fails on it anyway).
z_lines() {
  local n
  while IFS= read -r -d '' n; do
    case "$n" in *$'\n'*) printf '%q\n' "$n" ;; *) printf '%s\n' "$n" ;; esac
  done
}
# collect_changes — every changed or untracked, non-ignored file of the repository, from its
# root (git diff --no-relative); split into the ones inside the project (changed_rel,
# relative to it) and the ones outside it (changed_outside, from the root).
collect_changes() {
  local root
  root=$( { git diff -z --no-relative --name-only "$base"; git -C "$top" ls-files -z --others --exclude-standard; } | z_lines | sed '/^$/d' | sort -u)
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
# Other features' frozen acceptance files (their manifests sit in the project's lean state,
# keyed by its path): left uncommitted, they are not this feature's changes; their own gate
# checks them.
other_frozen=$(find "$(lean_state_dir "$project")/frozen" -name '*.sha' ! -name "$name.sha" -exec cat {} + 2>/dev/null | manifest_paths | sort -u)
[ -n "$verify" ] || { echo "no verify_command in .harness.json" >&2; exit 2; }
# The gate's own temp files live in the lean state folder, which the suite's sandbox can neither
# read nor write (the user temp dir and /private/tmp are writable from it).
gate_tmp="$(lean_state_dir "$project")/tmp"
mkdir -p "$gate_tmp" || { echo "can't create $gate_tmp" >&2; exit 2; }
frozen_rel="" scan_list="" scan_err=""
trap 'rm -f ${frozen_rel:+"$frozen_rel"} ${scan_list:+"$scan_list"} ${scan_err:+"$scan_err"}' EXIT
fail=0

if [ "$head_sha" != "$base_sha" ]; then
  fail=1
  echo "HEAD MOVED: HEAD is ${head_sha:-unborn}, the feature's base commit is $base_sha."
  echo "Sessions never commit; committed work escapes these checks. Undo the commit(s) and keep the"
  echo "work uncommitted (git reset --soft $base_sha), then run the gate again."
fi

lean_sandbox_prepare "$project"; sandbox="$LEAN_SANDBOX"
[ -z "$LEAN_SANDBOX_WARN" ] || printf '%s\n' "$LEAN_SANDBOX_WARN"   # e.g. allowed_domains opens the network
case "$sandbox" in
  unsandboxed:*) echo "[WARN] the suite and the acceptance tests run UNSANDBOXED (${sandbox#unsandboxed: }): code the sessions wrote runs with your full permissions" ;;
  broken:*) fail=1; echo "SANDBOX UNAVAILABLE: ${sandbox#broken: } — the suite did not run (run the gate outside any sandbox, or set LEAN_GATE_UNSANDBOXED=1 to run it unsandboxed)" ;;
esac
# run_suite <command> — the command under the sessions' sandbox rules (or as the line above says).
run_suite() { lean_sandboxed "$project" "$1"; }
# run_warnings <output> — its [WARN] lines (processes left running), in the report pass or fail.
run_warnings() { grep '^\[WARN\] lean:' <<<"$1" || true; }

if [ "${sandbox%%:*}" = broken ]; then :
elif ! suite_out=$(run_suite "$verify" 2>&1); then
  fail=1
  echo "SUITE FAILS:"
  { grep -E '^\(fail\)|FAIL|✗' <<<"$suite_out" || tail -15 <<<"$suite_out"; } | head -20
  run_warnings "$suite_out"
else
  run_warnings "$suite_out"
fi

if [ -n "$frozen" ]; then
  if [ ! -f "$frozen" ]; then
    fail=1
    echo "FROZEN MANIFEST MISSING: $frozen"
  else
    # The same manifest with project-relative paths, so shasum -c and the comparisons
    # below read it from here.
    frozen_rel=$(mktemp "$gate_tmp/frozen.XXXXXX") || { echo "can't create a temp file in $gate_tmp" >&2; exit 2; }
    paste -d ' ' <(awk 'NF { print $1 " " }' "$frozen") <(manifest_paths "$frozen") > "$frozen_rel"
    frozen_paths=$(manifest_raw "$frozen_rel")
    bad=$(shasum -c "$frozen_rel" 2>&1 | grep -v ': OK$' || true)
    # Anything else that changed in the acceptance directory (a file added next to this
    # feature's), other features' frozen files aside.
    acc_changed=$( { git diff -z --name-only --relative "$base" -- "$acc_dir"; git ls-files -z --others --exclude-standard -- "$acc_dir"; } | z_lines | sort -u)
    extra=$(comm -23 <(printf '%s\n' "$acc_changed" | sed '/^$/d') <( printf '%s\n' "$frozen_paths" "$other_frozen" | sed '/^$/d' | sort -u))
    if [ -n "$bad$extra" ]; then
      fail=1
      echo "FROZEN ACCEPTANCE TESTS CHANGED (restore them exactly; object in the document instead):"
      printf '%s\n' "$bad" "$extra" | sed '/^$/d'
    fi
    if [ "${sandbox%%:*}" = broken ]; then :
    elif ! acc_out=$(run_suite "$verify $(tr '\n' ' ' <<<"$frozen_paths")" 2>&1); then
      fail=1
      echo "ACCEPTANCE TESTS FAIL:"
      { grep -E '^\(fail\)|FAIL|✗' <<<"$acc_out" || tail -15 <<<"$acc_out"; } | head -20
      run_warnings "$acc_out"
    else
      run_warnings "$acc_out"
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
existing_tests=$(git ls-tree -z -r --name-only "$base" | z_lines | grep -E '(\.test|\.spec|_test)\.[A-Za-z]+$|(^|/)test_[^/]+\.py$' || true)
while IFS= read -r t; do
  [ -n "$t" ] || continue
  removed=$(git diff --no-relative --no-ext-diff --no-textconv "$base" -- ":(literal)$t" | grep -E '^-' | grep -vE '^---' | grep -E 'expect\(|assert|test\(|it\(' || true)
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

# One pass over the project, git-ignored files included (node_modules/pkg), names kept
# NUL-separated (find -print0); git directories (.git) are not entered:
# - CLAUDE.md / CLAUDE.local.md files below the top level, any case, and every file in a
#   .claude/ folder below the top level (skills, commands, agents): Claude Code loads nested
#   ones into the next session, and the profile's write-deny matches only the name a file is
#   written under (a folder renamed into place, or a session's Bash, gets past it). Refused
#   unless git tracks it, unchanged (no filters applied), at the base revision, as a regular
#   file. The top-level ones are hash-pinned (lean_check_trusted) and write-denied.
# - a path with a newline in it: names are compared line by line elsewhere (the plan, git's
#   name lists), where such a name could pose as another.
# - folders the gate can't list (no read or search permission, or any find error): what they
#   hold would go unchecked, while a program that opens a file by its path still reads it.
memory_out="" newline_out="" unlisted_out=""
nl=$'\n'
# tracked_unchanged <path> — a regular file (not a link) git tracks at the base revision with
# the same content.
tracked_unchanged() {
  local blob
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  blob=$(git rev-parse --verify --quiet "$base_sha:$prefix$1" 2>/dev/null) || return 1
  [ "$(git cat-file -t "$blob" 2>/dev/null)" = blob ] && [ "$(git hash-object --no-filters -- "$1" 2>/dev/null)" = "$blob" ]
}
scan_list=$(mktemp "$gate_tmp/scan.XXXXXX") && scan_err=$(mktemp "$gate_tmp/scan-err.XXXXXX") \
  || { echo "can't create a temp file in $gate_tmp" >&2; exit 2; }
find_rc=0
find . -name .git -prune -o \
  \( -iname claude.md -o -iname claude.local.md -o -iname .claude -o -ipath './?*/.claude/*' \
     -o -name "*$nl*" -o \( -type d ! -perm -0500 \) \) -print0 > "$scan_list" 2> "$scan_err" || find_rc=$?
while IFS= read -r -d '' l; do
  l="${l#./}"
  case "$l" in *"$nl"*) newline_out="$newline_out$(printf '%q' "$l")$nl"; continue ;; esac
  if [ -d "$l" ] && [ ! -L "$l" ] && { [ ! -r "$l" ] || [ ! -x "$l" ]; }; then
    unlisted_out="$unlisted_out$l$nl"; continue
  fi
  nested=0; case "$l" in */*) nested=1 ;; esac
  case "/$l/" in
    /.claude/*) ;;   # the top-level one: hash-pinned and write-denied
    */.[Cc][Ll][Aa][Uu][Dd][Ee]/*)
      if [ -L "$l" ] || { [ ! -d "$l" ] && ! tracked_unchanged "$l"; }; then memory_out="$memory_out$l$nl"; fi ;;
  esac
  case "${l##*/}" in
    [Cc][Ll][Aa][Uu][Dd][Ee].[Mm][Dd]|[Cc][Ll][Aa][Uu][Dd][Ee].[Ll][Oo][Cc][Aa][Ll].[Mm][Dd])
      if [ ! -d "$l" ] && ! { [ "$nested" = 0 ] && { [ "$l" -ef CLAUDE.md ] || [ "$l" -ef CLAUDE.local.md ]; }; } \
         && ! tracked_unchanged "$l"; then
        memory_out="$memory_out$l$nl"
      fi ;;
  esac
done < "$scan_list"
if [ -n "$newline_out" ]; then
  fail=1
  echo "PATHS WITH A NEWLINE IN THEIR NAME (shown quoted; the checks compare names line by line, where one could pose as another: rename or remove them):"
  printf '%s' "$newline_out"
fi
if [ -n "$unlisted_out" ] || [ "$find_rc" != 0 ] || [ -s "$scan_err" ]; then
  fail=1
  echo "FOLDERS THE GATE CAN'T LIST (no read or search permission, or find failed: what they hold goes unchecked; restore the permissions, chmod u+rx, or remove them):"
  printf '%s' "$unlisted_out"
  sed 's/^/  /' "$scan_err" | head -20
  [ "$find_rc" = 0 ] || [ -s "$scan_err" ] || echo "  find exited with $find_rc"
fi
if [ -n "$memory_out" ]; then
  fail=1
  echo "CLAUDE.md / CLAUDE.local.md OR NESTED .claude/ FILES NOT TRACKED AT THE BASE, OR CHANGED (Claude Code would load them; remove them, git-ignored or not):"
  printf '%s' "$memory_out" | awk '!seen[$0]++'
fi

if [ -n "$changed_outside" ]; then
  fail=1
  echo "CHANGED OUTSIDE THE PROJECT DIRECTORY $prefix (paths from the repository root; undo the change):"
  echo "$changed_outside"
fi

[ "$fail" = 0 ] && echo "ALL CHECKS PASS"
exit "$fail"
