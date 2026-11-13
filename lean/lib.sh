#!/usr/bin/env bash
# lib.sh — helpers shared by lean/run.sh, lean/gate.sh, scripts/harness.sh and init.sh.
# Sourced, not executed; every name starts with lean_.
#
# State: the lean flow keeps each project's pinned state outside the project, in
# lean_state_dir: frozen/<name>.sha (risk mode's acceptance manifest), lean/<name>/trusted.sha
# (the hashes of the harness-owned files the flow runs or trusts; lean/<name>/pinned/ keeps a copy
# of the small config and instruction files among them, lean_pin_copies), lean/<name>/nested.sha (the
# nested instruction files there before the feature's first run), lean/<name>/dirty.sha (the
# files already changed before it, lean_dirty_manifest), lean/<name>/plan.lists (the plan's
# **Files** / **Changed tests**, lean_plan_pin) and run results. The folder is keyed by the project's resolved path,
# never by .harness.json (a session could edit that and point the next step at fresh state).

LEAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The harness-owned paths the flow runs or trusts, relative to the project. Sessions can't
# write them (sandbox.sh denyWrite); lean_trusted_manifest hashes them for lean_check_trusted.
# Their own settings.local.json is left out of the hashes (Claude Code writes it when the
# user allows a command in their own session) but stays write-denied.
LEAN_TRUSTED_PATHS="lean scripts .harness.json init.sh harness .claude .codex AGENTS.md CLAUDE.md CLAUDE.local.md .mcp.json"

# lean_state_dir <project> — ~/.cache/harness/projects/<folder>-<12 hex of the sha256 of its
# resolved path>.
lean_state_dir() {
  local real
  real=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  printf '%s/.cache/harness/projects/%s-%s\n' "$HOME" "$(basename "$real")" \
    "$(printf '%s' "$real" | shasum -a 256 | cut -c1-12)"
}

# lean_adopt_legacy <project> — once, when the path-keyed folder doesn't exist yet, copies
# the frozen manifests and run state an older version kept under the slug
# (~/.cache/harness/<project_slug>), so a feature frozen before the change keeps its risk mode.
lean_adopt_legacy() {
  local state slug old d
  state=$(lean_state_dir "$1") || return 0
  [ ! -d "$state" ] || return 0
  slug=$(jq -r '.project_slug // empty' "$1/.harness.json" 2>/dev/null)
  slug="${slug:-$(basename "$(cd "$1" && pwd)")}"
  case "$slug" in ""|projects|*/*|.|..) return 0 ;; esac
  old="$HOME/.cache/harness/$slug"
  [ -d "$old/frozen" ] || [ -d "$old/lean" ] || return 0
  mkdir -p "$state" || return 0
  for d in frozen lean; do [ ! -d "$old/$d" ] || cp -R "$old/$d" "$state/$d"; done
  echo "[lean] copied the lean state kept under $old to $state" >&2
}

# lean_trusted_manifest <project> — "<sha256>  <path>" for every file under the trusted
# paths (links followed), sorted.
lean_trusted_manifest() {
  (
    cd "$1" || exit 1
    for p in $LEAN_TRUSTED_PATHS; do
      [ -e "$p" ] || continue
      find -L "$p" -type f ! -name settings.local.json ! -name .DS_Store ! -name '*.pyc' 2>/dev/null
    done | LC_ALL=C sort -u | while IFS= read -r f; do shasum -a 256 "$f"; done
  )
}

# lean_nested_line <path> — "<sha256>  <path>", the line lean_nested_manifest records for a
# file and lean/gate.sh compares against.
lean_nested_line() { shasum -a 256 -- "$1"; }

# lean_nested_manifest <project> — lean_nested_line for each nested instruction file already in
# the project, sorted: the files lean/gate.sh's scan looks for (CLAUDE.md / CLAUDE.local.md below
# the top level, any case, and files in a .claude/ folder below the top level; git-ignored ones
# included, .git not entered), regular files only (a link always fails the gate), no name with
# a newline.
lean_nested_manifest() {
  (
    cd "$1" || exit 1
    find . -name .git -prune -o \( -iname claude.md -o -iname claude.local.md -o -ipath './?*/.claude/*' \) \
      -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
      f="${f#./}"
      case "$f" in *$'\n'*|.claude/*) continue ;; */*) ;; *) continue ;; esac
      lean_nested_line "$f"
    done | LC_ALL=C sort
  )
}

# lean_pin <project> <name> [--again] — pins the hashes of the trusted files under
# <state>/lean/<name>/trusted.sha when they aren't pinned yet (--again: afresh), with a copy of
# LEAN_PIN_COPIES (.harness.json ...) in <state>/lean/<name>/pinned/ (lean_pin_copies). With them, and
# only when it isn't there yet (--again: afresh), it records the nested instruction files
# already in the project in <state>/lean/<name>/nested.sha (lean_nested_manifest): the gate
# accepts those as they are (an npm package that ships a .claude/ folder), not new or changed
# ones. Accepting a harness-file change (lean/run.sh accept-config, which rewrites trusted.sha
# alone) keeps nested.sha. Once per
# feature, at its first pin (lean_first_pin: nothing pinned or run for it yet), it also records
# the files already changed in <state>/lean/<name>/dirty.sha (lean_dirty_manifest), which the
# gate leaves out while they keep that content. Never again: not with --again (a later claim),
# not by accept-config or a deleted trusted.sha re-pinned, so no session's work can be recorded as already
# there; it goes when the feature's lean lifecycle ends (scripts/harness.sh
# lean_forget_baseline). A feature pinned before dirty.sha existed never gets one.
# Every call ends with lean_plan_pin (the plan's **Files** / **Changed tests**, plan.lists).
lean_pin() {
  local project="$1" name="$2" again="${3:-}" dir n first=0
  dir="$(lean_state_dir "$project")/lean/$name" || return 1
  mkdir -p "$dir" || return 1
  [ "$again" = --again ] || [ ! -f "$dir/trusted.sha" ] || { lean_plan_pin "$project" "$name"; return; }
  ! lean_first_pin "$project" "$name" || first=1
  lean_trusted_manifest "$project" > "$dir/trusted.tmp" && mv "$dir/trusted.tmp" "$dir/trusted.sha" || return 1
  lean_pin_copies "$project" "$name" || true
  echo "[lean] pinned the hashes of $(wc -l < "$dir/trusted.sha" | tr -d ' ') harness-owned file(s) in $dir/trusted.sha" >&2
  if [ "$again" = --again ] || [ ! -f "$dir/nested.sha" ]; then
    lean_nested_manifest "$project" > "$dir/nested.tmp" && mv "$dir/nested.tmp" "$dir/nested.sha" || return 1
    n=$(wc -l < "$dir/nested.sha" | tr -d ' ')
    [ "$n" = 0 ] || echo "[lean] recorded $n nested CLAUDE.md / .claude/ file(s) already in the project in $dir/nested.sha (the gate accepts them unchanged)" >&2
  fi
  if [ "$first" = 1 ]; then
    lean_dirty_manifest "$project" "$name" > "$dir/dirty.tmp" && mv "$dir/dirty.tmp" "$dir/dirty.sha" || return 1
    n=$(wc -l < "$dir/dirty.sha" | tr -d ' ')
    [ "$n" = 0 ] || echo "[lean] recorded $n file(s) already changed before the feature in $dir/dirty.sha (the gate ignores them while their content stays the same)" >&2
  fi
  lean_plan_pin "$project" "$name"
}

# lean_first_pin <project> <name> — true when nothing was pinned or run for the feature yet: its
# <state>/lean/<name>/ holds nothing (no trusted.sha, nested.sha, dirty.sha, usage.tsv; a
# leftover *.tmp aside) and no session of it left a result (<state>/lean/<name>.system.md,
# <name>.<step>.*.json, <name>.review.json). A chain's log folder doesn't count: the chain makes
# it before its first step pins.
lean_first_pin() {
  local runs="$(lean_state_dir "$1")/lean" f
  [ -z "$(find "$runs/$2" -mindepth 1 -maxdepth 1 ! -name '*.tmp' ! -name plan.lists -print 2>/dev/null | head -1)" ] || return 1
  for f in "$runs/$2.system.md" "$runs/$2.review.json" "$runs/$2".implement.*.json "$runs/$2".review.*.json "$runs/$2".fix.*.json; do
    [ ! -e "$f" ] || return 1
  done
  return 0
}

# The plan's lists, pinned: <state>/lean/<name>/plan.lists holds the paths named under **Files**
# and **Changed tests** in docs/features/<name>.md ("<section><TAB><path>" lines, as
# lean_plan_section reads them; a first line "# approved by <name> at <time>" when they were
# approved). Once a session of the feature ran (lean_sessions_ran), lean/gate.sh checks against
# these lists, not the live document, and fails naming any path added or removed there since
# (lean_plan_drift): a session can append to the document (Decisions while implementing) but
# not widen its scope. Written by lean_plan_pin: by every pin while no session ran yet (the
# leader may still edit the plan) unless approved; afresh by approve-plan / run.sh freeze
# (approved) and by `lean/run.sh replan` (the leader accepting a change, outside any session).
# Removed with dirty.sha (scripts/harness.sh lean_forget_baseline). Once a session ran, no pin
# writes it, so a feature whose sessions ran without one (pinned by an older version, its lean
# lifecycle ended and began again with set-mode, a reused name, a lost file) fails the gate
# until the leader runs lean/run.sh replan: the live document is never trusted then.
lean_plan_file() { local s; s=$(lean_state_dir "$1") || return 1; printf '%s/lean/%s/plan.lists\n' "$s" "$2"; }

# lean_plan_section <doc> <title> — the path-like words under that section of the doc (a
# heading, or a "**Title**" / "- **Title**" line, holding <title>; bullets and backticks
# stripped), sorted. lean/gate.sh's reading of the plan.
lean_plan_section() {
  [ -f "$1" ] || return 0
  awk -v t="$2" '/^#+ |^- \*\*|^\*\*/ { in_sec = (index($0, t) > 0) } in_sec' "$1" \
    | { grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' || true; } | LC_ALL=C sort -u
}

# lean_plan_lists <doc> — "Files<TAB><path>" and "Changed tests<TAB><path>" lines.
lean_plan_lists() {
  lean_plan_section "$1" Files | awk '{ print "Files\t" $0 }'
  lean_plan_section "$1" "Changed tests" | awk '{ print "Changed tests\t" $0 }'
}

# lean_plan_pinned <file> <title> — the paths pinned for that section.
lean_plan_pinned() { awk -F'\t' -v t="$2" '!/^#/ && $1 == t { print $2 }' "$1"; }

# lean_sessions_ran <project> <name> — true when a session of the feature was opened (run.sh
# writes <name>.system.md before each one) or left a result or usage row; also when the state
# can't be found (fail closed: nothing is re-pinned then).
lean_sessions_ran() {
  local runs f
  runs="$(lean_state_dir "$1")/lean" || return 0
  for f in "$runs/$2.system.md" "$runs/$2.review.json" "$runs/$2".implement.*.json "$runs/$2".review.*.json "$runs/$2".fix.*.json "$runs/$2/usage.tsv"; do
    [ ! -e "$f" ] || return 0
  done
  return 1
}

# lean_plan_pin <project> <name> [--again | --approved <by>] — writes plan.lists from the
# document (nothing without it). Plain: only while no session ran and the lists aren't approved
# ones. --again: afresh, keeping an approval line; --approved: afresh, as approved by <by>.
lean_plan_pin() {
  local project="$1" name="$2" how="${3:-}" by="${4:-}" file doc head="" n
  doc="$1/docs/features/$2.md"
  file=$(lean_plan_file "$project" "$name") || return 1
  [ -f "$doc" ] || return 0
  if [ -z "$how" ]; then
    ! lean_sessions_ran "$project" "$name" || return 0
    ! grep -q '^# approved' "$file" 2>/dev/null || return 0
  fi
  [ "$how" != --again ] || head=$(grep -m1 '^# approved' "$file" 2>/dev/null || true)
  [ "$how" != --approved ] || head="# approved by $(printf '%s' "$by" | tr -d '\n\t') at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$file")" || return 1
  { [ -z "$head" ] || printf '%s\n' "$head"; lean_plan_lists "$doc"; } > "$file.tmp" || return 1
  if [ -f "$file" ] && cmp -s "$file.tmp" "$file"; then rm -f "$file.tmp"; return 0; fi
  mv "$file.tmp" "$file" || return 1
  n=$(grep -vc '^#' "$file" || true)
  echo "[lean] pinned the plan's **Files** / **Changed tests** ($n path(s)) in $file: sessions can't widen them (lean/run.sh replan $name accepts a change)" >&2
}

# lean_plan_mark_approved <project> <name> <by> — records that the plan's lists were approved
# by <by> (scripts/harness.sh at claim, from approve-plan's record in the database; lean/run.sh
# freeze). An approved plan.lists stays as it is. Before any session: pinned afresh from the
# document, as approved. After one: never from the document (a session may have widened it):
# the lists pinned so far are marked approved, and with none the file holds the approval line
# alone, so the gate names every listed path as a change until the leader runs
# lean/run.sh replan <name> --by <name>.
lean_plan_mark_approved() {
  local project="$1" name="$2" by="$3" file
  file=$(lean_plan_file "$project" "$name") || return 1
  ! grep -q '^# approved' "$file" 2>/dev/null || return 0
  if ! lean_sessions_ran "$project" "$name"; then
    lean_plan_pin "$project" "$name" --approved "$by"; return
  fi
  mkdir -p "$(dirname "$file")" || return 1
  { printf '# approved by %s at %s\n' "$(printf '%s' "$by" | tr -d '\n\t')" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ ! -f "$file" ] || grep -v '^#' "$file" || true; } > "$file.tmp" && mv "$file.tmp" "$file" || return 1
  echo "[lean] marked the plan's pinned **Files** / **Changed tests** in $file as approved by $by (sessions ran: not re-read from the document)" >&2
}

# lean_plan_drift <project> <name> — "  + <section>: <path>" / "  - <section>: <path>" for each
# path the document's lists gained or lost since plan.lists; nothing without plan.lists or the
# document.
lean_plan_drift() {
  local file doc="$1/docs/features/$2.md"
  file=$(lean_plan_file "$1" "$2") || return 0
  [ -f "$file" ] && [ -f "$doc" ] || return 0
  { diff <(grep -v '^#' "$file") <(lean_plan_lists "$doc") || true; } \
    | awk -F'\t' '/^[<>] / { printf "  %s %s: %s\n", (substr($1, 1, 1) == ">" ? "+" : "-"), substr($1, 3), $2 }'
}

# lean_leader_actions <file>... — the items of each existing file's **Leader actions** section:
# what a session needs and only the leader or the user can do (harness config, a dependency, a
# file outside **Files**). One "<open|done><TAB><file><TAB><text>" line per item.
# The section starts at a `#...` heading, a `**Leader actions**` line or a `- **Leader actions**`
# bullet (any case). Where it ends depends on how it opened:
# - at a `#...` heading: only at a heading of the same or a higher level (`##` ends a `##`
#   section, `###` doesn't). Sub-headings and bold-only lines (`**Risks**`, `**Note**`) inside it
#   are notes, and every bullet is read as an item, bold-starting ones included
#   (`- **Acceptance command**: ...`, `- **Steps**: ...`): an item never ends the section;
# - at a bold line (the bullet-style plan, `- **Leader actions**` with indented items): at any
#   `#...` heading, or at a `**<title>**` / `- **<title>**` line whose title is exactly another
#   plan section's (Decisions, Decisions while implementing, Out of scope, Files, Changed tests,
#   Steps, Risks, Request, Assumptions, Acceptance, Acceptance tests, Acceptance objections),
#   followed by nothing or a colon. Any other bold-starting bullet is an item
#   (`- **verify_command**: ...`, `- **Files** needed: x`, `- **Acceptance command**: x`).
# Inside the section:
# - items are the top-level bullets (`-`, `*`, `+`, or numbered `1.` / `1)`), at the indent of its
#   first one; deeper bullets and indented lines belong to the item above them (a detail, a
#   wrapped line), never items of their own;
# - `[x]` is done, `[ ]` or no box is open, any other box (`[-]`, `[~]`) is open; "none" / "n/a"
#   bullets are skipped;
# - a line that looks like an item but isn't one of those (`-[ ] x`, `[ ] x` without a bullet, a
#   `•` bullet) is an open item, its text starting "(not read as an item: fix its format)":
#   fail closed, never dropped;
# - fenced code (``` / ~~~, three or more) is skipped, here and everywhere else (an example
#   section in a fence is no section; a `# comment` in a fence ends nothing); a fence closes only
#   at a line of the same character, at least as long as the one that opened it, and nothing
#   else (a ```` fence holding a ``` line stays open); CRLF line ends are read as LF.
# A file without the section prints nothing. Its heading names no other section, so the section
# never reads as part of **Files** / **Changed tests** (lean_plan_section): checking an item off
# doesn't move the pinned lists.
lean_leader_actions() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    awk -v file="$f" -v bullet='•' '
      function indent(s,   n, i, c) {
        n = 0
        for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == " ") n++; else if (c == "\t") n += 4; else break }
        return n
      }
      function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
      # run(s, c) — how many times the character c repeats at the start of s.
      function run(s, c,   n) { n = 0; while (substr(s, n + 1, 1) == c) n++; return n }
      # bold_title(line) — the lowercased text of a leading **...** (after an optional "- "), else "".
      function bold_title(l,   t) {
        t = l; sub(/^- /, "", t)
        if (t !~ /^\*\*[^*]+\*\*/) return ""
        t = substr(t, 3); t = substr(t, 1, index(t, "**") - 1)
        t = tolower(trim(t)); sub(/:$/, "", t)
        return trim(t)
      }
      # other_section(line, title) — the line heads another plan section: exactly a known title,
      # followed by nothing or a colon (`- **Files**: x` ends a bullet-style section,
      # `- **Files** needed: x` and `- **Acceptance command**: x` are items).
      function other_section(l, t,   r) {
        if (t !~ /^(decisions|decisions while implementing|out of scope|files|changed tests|steps|risks|request|assumptions|acceptance|acceptance tests|acceptance objections)$/) return 0
        r = l; sub(/^- /, "", r); r = substr(r, 3); r = substr(r, index(r, "**") + 2)
        return r ~ /^[ \t]*(:|$)/
      }
      function emit(st, t) {
        t = trim(t)
        if (t == "" || tolower(t) ~ /^(none|n\/a)\.?$/) return
        print st "\t" file "\t" t
      }
      { sub(/\r$/, "") }
      fence_len {
        t = $0; sub(/^[ \t]*/, "", t)
        n = run(t, fence_ch)
        if (n >= fence_len && substr(t, n + 1) ~ /^[ \t]*$/) fence_len = 0
        next
      }
      /^[ \t]*(```|~~~)/ { t = $0; sub(/^[ \t]*/, "", t); fence_ch = substr(t, 1, 1); fence_len = run(t, fence_ch); next }
      /^#+[ \t]/ {
        lvl = run($0, "#")
        if (in_sec && kind == "heading" && lvl > level) next   # a sub-heading: a note inside the section
        in_sec = (tolower($0) ~ /^#+[ \t]+leader actions/)
        if (in_sec) { kind = "heading"; level = lvl; base = -1 }
        next
      }
      /^(- )?\*\*[^*]+\*\*/ {
        t = bold_title($0)
        if (in_sec && kind == "heading") {
          if ($0 !~ /^- /) next   # a bold-only line: a note
          # a bold-starting bullet: an item, read below
        } else {
          if (t ~ /^leader actions/) { in_sec = 1; kind = "bold"; base = -1; next }
          if (in_sec && other_section($0, t)) { in_sec = 0; next }
          if (!in_sec) next
          if ($0 !~ /^- /) next   # a bold sub-heading or note inside the section
        }
      }
      !in_sec { next }
      /^[ \t]*$/ { next }
      /^[ \t]*([-*+]|[0-9]+[.)])([ \t]|$)/ {
        n = indent($0)
        if (base >= 0 && n > base) next   # a sub-bullet: part of the item above
        base = n
        t = $0; sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]*/, "", t)
        if (t ~ /^\[[xX]\]/) { sub(/^\[[xX]\][ \t]*/, "", t); emit("done", t) }
        else if (t ~ /^\[ \]/) { sub(/^\[ \][ \t]*/, "", t); emit("open", t) }
        else emit("open", t)   # no box, or another one ([-], [~]): open
        next
      }
      {
        n = indent($0); t = trim($0)
        if (base >= 0 && n > base) next   # an indented line: part of the item above
        if (t ~ /^([-*+]|[0-9]+[.)])?[ \t]*\[[^]]?\]/ || index(t, bullet) == 1)
          emit("open", "(not read as an item: fix its format) " t)
      }' "$f"
  done
}

# lean_dirty_hash <path> — what lean_dirty_manifest records for a repository-root path (run from
# the root): "deleted" when nothing is there, "link:<sha256 of the target text>" for a link,
# "dir:<HEAD>" for a folder (a submodule), else "<mode>:<sha256>" of the file, the mode as git
# tracks it (100755 executable, else 100644): a chmod counts as a change.
lean_dirty_hash() {
  if [ -L "$1" ]; then printf 'link:%s\n' "$(readlink -- "$1" | shasum -a 256 | cut -d' ' -f1)"
  elif [ -d "$1" ]; then printf 'dir:%s\n' "$(git -C "$1" rev-parse --verify --quiet HEAD 2>/dev/null || echo none)"
  elif [ -e "$1" ]; then printf '%s:%s\n' "$([ -x "$1" ] && echo 100755 || echo 100644)" "$(shasum -a 256 -- "$1" | cut -d' ' -f1)"
  else echo deleted
  fi
}

# lean_manifest_paths <manifest> — the paths of a shasum manifest ("<sha>  <path>" or
# "<sha> *<path>"), one per line, spaces kept.
lean_manifest_paths() { awk 'NF { sub(/^[^ ]+ [ *]/, ""); print }' "$@"; }

# lean_dirty_manifest <project> <name> — "<lean_dirty_hash>  <path>" for every file of the
# project's repository already changed against HEAD (modified, staged, deleted, untracked and
# not ignored: lean_repo_changes, a rename under both its paths) at the feature's first pin,
# paths from the repository root, sorted. Left out: the harness's progress/ and state/ (the
# gate excepts them anyway), names holding a newline (the gate fails on those), and the
# feature's own files, which are its work whenever they were written: its plan
# (docs/features/<name>.md), its review report (docs/features/<name>.review.md), its acceptance
# tests (<lean.acceptance_dir>/<name>.*) and the files of its frozen manifest
# (<state>/frozen/<name>.sha). Git-ignored files, the hidden harness's included, are not listed
# by git, so they are not here either.
lean_dirty_manifest() {
  local frozen
  frozen="$(lean_state_dir "$1")/frozen/$2.sha" || return 1
  (
    cd "$1" || exit 1
    local top prefix f acc own
    git rev-parse --git-dir >/dev/null 2>&1 || exit 0
    top=$(git rev-parse --show-toplevel) || exit 1
    prefix=$(git rev-parse --show-prefix 2>/dev/null || true)
    git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || exit 0   # unborn: nothing to compare with
    acc=$(jq -r '.lean.acceptance_dir // "acceptance"' .harness.json 2>/dev/null || echo acceptance)
    acc="${acc%/}"
    # The frozen manifest's paths ("<sha>  <path>", from the project), as written and from the root.
    own=$( { [ ! -f "$frozen" ] || lean_manifest_paths "$frozen"; } \
      | while IFS= read -r f; do [ -z "$f" ] || printf '%s\n%s%s\n' "$f" "$prefix" "$f"; done)
    lean_repo_changes HEAD | while IFS= read -r f; do
      case "$f" in
        "\$'"*) continue ;;
        "${prefix}progress/"*|"${prefix}state/"*) continue ;;
        "${prefix}docs/features/$2.md"|"${prefix}docs/features/$2.review.md"|"${prefix}$acc/$2."*|"${prefix}$acc/"*"/$2."*) continue ;;  # find recurses: any depth
      esac
      ! grep -qxF -- "$f" <<<"$own" || continue
      printf '%s  %s\n' "$(cd "$top" && lean_dirty_hash "$f")" "$f"
    done | LC_ALL=C sort -k2
  )
}

# lean_baseline_split <project> <name> — compares the files recorded in the feature's dirty.sha
# (lean_pin) with what is there now, from the repository root: "= <path>" when the content is
# still the recorded one (not this feature's change), "! <path>" when it differs (a change of
# this feature, even one back to HEAD that git no longer lists). Nothing without dirty.sha (a
# feature pinned before it existed: every change counts, as before).
lean_baseline_split() {
  local file top line h p
  file="$(lean_state_dir "$1")/lean/$2/dirty.sha" || return 0
  [ -f "$file" ] || return 0
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    h="${line%%  *}"; p="${line#*  }"
    if [ "$(cd "$top" && lean_dirty_hash "$p")" = "$h" ]; then printf '= %s\n' "$p"; else printf '! %s\n' "$p"; fi
  done < "$file"
}

# lean_feature_changes <project> <name> <base> — lean_repo_changes <base> (run in <project>) as
# the gate counts them: the dirty.sha files still as they were dropped, the ones changed since
# added (lean_baseline_split). Sorted, from the repository root.
lean_feature_changes() {
  local split
  split=$(lean_baseline_split "$1" "$2")
  { (cd "$1" && lean_repo_changes "$3"); sed -n 's/^! //p' <<<"$split"; } | sed '/^$/d' | sort -u \
    | { grep -vxF -f <(sed -n 's/^= //p' <<<"$split" | sed '/^$/d'; echo $'\x01') || true; }
}

# LEAN_COMPOUND_WARN — the [WARN] for appending acceptance test paths to a compound
# verify_command (lean_acceptance_command).
LEAN_COMPOUND_WARN="[WARN] lean: verify_command is a compound command (&&, ||, ;, |, & or a newline at its top level): the acceptance test paths are appended to its last command only; set .harness.json::lean.acceptance_command (e.g. \"npm test -- {paths}\")"

# lean_is_compound <command> — true when it holds &&, ||, ;, |, a lone & (not a redirection:
# 2>&1, &>) or a newline outside quotes, backticks, backslash escapes and parentheses ($(...),
# subshells): the paths appended to it reach its last part only.
lean_is_compound() {
  local s="$1" i c n=${#1} q="" depth=0 nx pv
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    if [ "$q" = "'" ]; then [ "$c" != "'" ] || q=""; continue; fi
    if [ "$c" = '\' ]; then i=$((i + 1)); continue; fi
    if [ "$q" = '"' ]; then [ "$c" != '"' ] || q=""; continue; fi
    if [ "$q" = '`' ]; then [ "$c" != '`' ] || q=""; continue; fi
    case "$c" in
      "'"|'"'|'`') q="$c" ;;
      '(') depth=$((depth + 1)) ;;
      ')') [ "$depth" = 0 ] || depth=$((depth - 1)) ;;
      ';'|'|'|$'\n') [ "$depth" != 0 ] || return 0 ;;
      '&')
        [ "$depth" = 0 ] || continue
        nx="${s:i+1:1}" pv=""
        [ "$i" = 0 ] || pv="${s:i-1:1}"
        [ "$nx" != '&' ] || return 0
        [ "$nx" = '>' ] || [ "$pv" = '>' ] || [ "$pv" = '<' ] || return 0 ;;
    esac
  done
  return 1
}

# lean_acceptance_valid <project> — .harness.json::lean.acceptance_command is unset or a string.
lean_acceptance_valid() {
  jq -e '(.lean.acceptance_command // null) as $a | $a == null or ($a | type) == "string"' "$1/.harness.json" >/dev/null 2>&1
}
LEAN_ACCEPTANCE_INVALID="invalid .harness.json::lean.acceptance_command: use a string, with {paths} where the acceptance test paths go (else they are appended)"

# lean_acceptance_command <project> <path...> — the command that runs the acceptance tests:
# .harness.json::lean.acceptance_command (non-empty) with each {paths} replaced by the
# shell-quoted paths, or the paths appended when it has none; unset, verify_command with the
# shell-quoted paths appended, and LEAN_ACCEPTANCE_WARN set to LEAN_COMPOUND_WARN when it is a
# compound command (lean_is_compound). Run it in the current shell (not $(...)) for the warning.
lean_acceptance_command() {
  local project="$1" acc q="" f out="" rest; shift
  LEAN_ACCEPTANCE_WARN="" LEAN_ACCEPTANCE_CMD=""
  acc=$(jq -r '.lean.acceptance_command // empty | strings' "$project/.harness.json" 2>/dev/null || true)
  if [ -z "$acc" ]; then
    acc=$(jq -r '.verify_command // empty' "$project/.harness.json" 2>/dev/null || true)
    ! lean_is_compound "$acc" || LEAN_ACCEPTANCE_WARN="$LEAN_COMPOUND_WARN"
    for f in "$@"; do q="$q $(printf '%q' "$f")"; done
    LEAN_ACCEPTANCE_CMD="$acc$q"
    return 0
  fi
  for f in "$@"; do q="$q $(printf '%q' "$f")"; done
  q="${q# }"
  rest="$acc"
  if [[ "$rest" == *"{paths}"* ]]; then
    while [[ "$rest" == *"{paths}"* ]]; do out="$out${rest%%"{paths}"*}$q"; rest="${rest#*"{paths}"}"; done
    LEAN_ACCEPTANCE_CMD="$out$rest"
  else
    LEAN_ACCEPTANCE_CMD="$acc $q"
  fi
}

# lean_check_trusted <project> <name> — fails, naming the files and showing what changed in the
# copies kept at the pin (lean_config_diff), when a trusted file changed since lean_pin or the
# last lean/run.sh accept-config (no pin: passes).
lean_check_trusted() {
  local file now cdiff
  file="$(lean_state_dir "$1")/lean/$2/trusted.sha" || return 1
  [ -f "$file" ] || return 0
  now=$(lean_trusted_manifest "$1")
  [ "$now" = "$(cat "$file")" ] && return 0
  echo "harness-owned files changed since feature $2 was pinned ($file):" >&2
  lean_trusted_diff "$file" "$now" >&2
  cdiff=$(lean_config_diff "$1" "$2")
  [ -z "$cdiff" ] || printf '  what changed (secret-looking values masked):\n%s\n' "$cdiff" >&2
  echo "Sessions can't write them. If you or the user changed them on purpose (a .harness.json edit a Leader action asked for), accept them, outside any session, with lean/run.sh accept-config $2." >&2
  return 1
}

# Harness-owned text files whose content lean_pin_copies keeps beside trusted.sha, so a change to
# them can be shown, not only named (lean_config_diff): the config the gate runs
# (verify_command, lean.acceptance_command ...), init.sh and the instructions every agent reads.
LEAN_PIN_COPIES=".harness.json init.sh AGENTS.md CLAUDE.md"

# lean_pin_copies <project> <name> [<file>...] — copies LEAN_PIN_COPIES (or only the files named)
# as they are now into <state>/lean/<name>/pinned/ (a file that isn't there: its copy goes).
# Called wherever trusted.sha is written. Files over 256 KB are not kept.
lean_pin_copies() {
  local project="$1" dir f
  dir="$(lean_state_dir "$project")/lean/$2/pinned" || return 1
  shift 2
  [ $# -gt 0 ] || set -- $LEAN_PIN_COPIES
  mkdir -p "$dir" || return 1
  for f in "$@"; do
    case " $LEAN_PIN_COPIES " in *" $f "*) ;; *) continue ;; esac
    rm -f "$dir/$f"
    [ -f "$project/$f" ] || continue
    [ "$(wc -c < "$project/$f" | tr -d ' ')" -le 262144 ] || continue
    cp -L "$project/$f" "$dir/$f" 2>/dev/null || true
  done
}

# lean_mask <file> — the file with the values of keys that look secret (token, secret, password,
# key; any case) replaced by "<masked>": JSON through jq (any depth), anything else line by line
# (`<name>: value`, `<name>=value`). In any string value (and any line) it also masks the password of
# a URL (`postgres://u:<masked>@host`, also with an empty user: `redis://:<masked>@host`),
# `NAME=value` where NAME looks secret (`DB_PASSWORD=<masked>`; a quoted value is masked whole,
# spaces included) and a `Bearer <masked>` token (any case): a verify_command may carry test-only
# credentials. .harness.json holds no secrets by design; this keeps a mistake out of the terminal
# and the logs anyway, best effort (a secret under any other shape is shown). No file: nothing.
lean_mask() {
  [ -f "$1" ] || return 0
  jq empty "$1" >/dev/null 2>&1 && jq --indent 2 'walk(
      if type == "object" then with_entries(if (.key | test("token|secret|password|key"; "i")) then .value = "<masked>" else . end)
      elif type == "string" then
        gsub("(?<a>://[^:/@\\s]*:)[^@\\s]+@"; "\(.a)<masked>@")
        | gsub("(?<a>[A-Za-z0-9_]*(token|secret|password|pass|key)[A-Za-z0-9_]*=)(\"[^\"]*\"|\u0027[^\u0027]*\u0027|[^\\s]+)"; "\(.a)<masked>"; "i")
        | gsub("(?<a>bearer\\s+)[^\\s\"\u0027]+"; "\(.a)<masked>"; "i")
      else . end)' "$1" 2>/dev/null && return 0
  perl -pe 's/([\w.-]*(?:token|secret|password|key)[\w.-]*["\x27]?\s*[:=]\s*)\S.*/$1<masked>/i;
    s{(://[^:/@\s]*:)[^@\s]+@}{$1<masked>@}g;
    s/(\w*(?:token|secret|password|pass|key)\w*=)(?:"[^"]*"|\x27[^\x27]*\x27|\S+)/$1<masked>/gi;
    s/(bearer\s+)[^\s"\x27]+/$1<masked>/gi' "$1"
}

# lean_manifest_line <manifest> <path> — the "<sha256>  <path>" line of <path> in a manifest
# (lean_trusted_manifest's format), empty when it has none.
lean_manifest_line() {
  [ -f "$1" ] || return 0
  awk -v p="$2" 'substr($0, index($0, "  ") + 2) == p { print; exit }' "$1"
}

# lean_config_diff <project> <name> — for each file of LEAN_PIN_COPIES whose hash differs from its
# line in the pin (trusted.sha): a unified diff (secret-looking values masked, lean_mask) from the
# copy kept at the pin to the file now, indented four spaces. The copy is used only when its own
# hash is the pinned one (or neither has the file: it was added); otherwise (pinned by an older
# version, before copies were kept, or a copy that no longer matches) one line saying the content
# can't be shown.
lean_config_diff() {
  local state dir f old new d pinned nowl copyl
  state="$(lean_state_dir "$1")" || return 0
  dir="$state/lean/$2/pinned"
  for f in $LEAN_PIN_COPIES; do
    old="$dir/$f"; new="$1/$f"
    pinned=$(lean_manifest_line "$state/lean/$2/trusted.sha" "$f")
    nowl=""; [ ! -f "$new" ] || nowl=$(cd "$1" && shasum -a 256 "$f")
    [ "$nowl" != "$pinned" ] || continue
    copyl=""; [ ! -f "$old" ] || copyl="$(shasum -a 256 < "$old" | cut -d' ' -f1)  $f"
    if [ "$copyl" != "$pinned" ]; then
      printf '    %s: no copy of its pinned content kept (pinned by an older version, or the copy no longer matches the pin): content not shown\n' "$f"
      continue
    fi
    d=$(diff -u --label "pinned/$f" --label "now/$f" <(lean_mask "$old") <(lean_mask "$new") || true)
    if [ -z "$d" ]; then
      printf '    %s: only formatting or secret-looking values changed (masked)\n' "$f"
    else
      printf '%s\n' "$d" | sed 's/^/    /'
    fi
  done
}

# lean_plan_approved <project> <name> — true when the feature's plan was approved: its pinned lists
# say so (approve-plan / run.sh freeze, lean_plan_mark_approved) or a risk-mode manifest is frozen.
lean_plan_approved() {
  local state
  state=$(lean_state_dir "$1") || return 1
  grep -q '^# approved' "$state/lean/$2/plan.lists" 2>/dev/null || [ -f "$state/frozen/$2.sha" ]
}

# lean_note <name> <entry> — a best-effort line in the harness record (from the project directory):
# the log of the feature's open session (scripts/harness.sh session-base finds one), else a note on
# the feature (append-log --feature: no session needed); a [WARN] on stderr when it could not be
# written. No scripts/harness.sh: nothing.
lean_note() {
  [ -f scripts/harness.sh ] || return 0
  if [ -n "$(bash scripts/harness.sh session-base "$1" 2>/dev/null)" ]; then
    bash scripts/harness.sh append-log "$2" >/dev/null 2>&1 && return 0
  fi
  bash scripts/harness.sh append-log "$2" --feature "$1" >/dev/null 2>&1 && return 0
  echo "[WARN] could not record in the harness log: $2" >&2
}

# lean_trusted_diff <pinned file> <manifest> — "  <path>" for each trusted file added, removed
# or changed between the two, sorted.
lean_trusted_diff() {
  { diff <(cat "$1") <(printf '%s\n' "$2") || true; } | sed -n 's/^[<>] [0-9a-f]*  /  /p' | LC_ALL=C sort -u
}

# lean_trusted_path <path> — true when the project-relative path is one lean_trusted_manifest
# hashes: under LEAN_TRUSTED_PATHS, not a settings.local.json / .DS_Store / *.pyc (left out of
# the hashes, so never excused by them).
lean_trusted_path() {
  local p
  case "$1" in */settings.local.json|settings.local.json|*/.DS_Store|.DS_Store|*.pyc) return 1 ;; esac
  for p in $LEAN_TRUSTED_PATHS; do
    case "$1" in "$p"|"$p"/*) return 0 ;; esac
  done
  return 1
}

# Environment variables whose names look like secrets (case-insensitive extended regex):
# lean_env_drop lists them, and sessions and the gate's commands run without them. Besides
# the secret-looking words (generic *_KEY and *_PASSPHRASE included) and connection strings:
# *_PASS, *_PAT (personal access tokens), *_COOKIE, DOCKER_AUTH_CONFIG, NPM_AUTH*, Gradle's
# ORG_GRADLE_PROJECT_<signing key / password> properties,
# MYSQL_PWD, Yarn's npmAuthIdent (*_AUTH_IDENT), Bundler's per-host credentials
# (BUNDLE_<HOST>__<TLD>, a name with a double underscore; BUNDLE_BUILD__<gem> build options
# are kept, LEAN_KEEP_ENV), git config passed through the environment (GIT_CONFIG_COUNT /
# GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n>, GIT_CONFIG_PARAMETERS: an http.extraHeader
# there carries a token past GIT_CONFIG_GLOBAL=/dev/null) and npm's registry auth keys
# (npm_config_*_auth, *_authToken, *_password, including the scoped
# npm_config_//<registry>/:_authToken). .harness.json::lean.env_passthrough keeps a name.
LEAN_SECRET_ENV='TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|_PASS$|_PAT$|API_KEY|APIKEY|PRIVATE_KEY|ACCESS_KEY|_KEY$|^KEY$|CREDENTIAL|_AUTH_IDENT$|^MYSQL_PWD$|_COOKIE$|^DOCKER_AUTH_CONFIG$|^NPM_AUTH|^ORG_GRADLE_PROJECT_.*(SIGNING|PASSWORD|SECRET)|^BUNDLE_.+__|_URL$|_URI$|_DSN$|^SSH_AUTH_SOCK$|^GIT_CONFIG_(COUNT$|KEY_|VALUE_|PARAMETERS$)|^npm_config_.*(_auth|_authtoken|_password)$'
LEAN_KEEP_ENV='^BUNDLE_BUILD__'

# lean_env_names — the names of the exported variables, NUL-terminated, read from the
# environment itself (env -0, or perl's %ENV where env has no -0), so names that aren't shell
# identifiers (MY-API_TOKEN, npm_config_//reg/:_authToken: bash 5 passes them on without
# listing them in compgen -e) and multi-line values are handled. Fails (prints nothing) when
# neither is there: the callers then refuse to run anything (fail closed).
lean_env_names() {
  local kv
  if env -0 >/dev/null 2>&1; then
    env -0 | while IFS= read -r -d '' kv; do
      if [ -n "${kv%%=*}" ]; then printf '%s\0' "${kv%%=*}"; fi
    done
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'length and print "$_\0" for keys %ENV'
  else
    return 1
  fi
}

# Secret files: basenames (any case) the sessions run.sh opens must not read (lean/sandbox.sh
# denies them to sessions only: the gate's profile keeps them readable, suites load .env) and
# lean/run.sh brief leaves out of its search. LEAN_SECRET_KEEP: the .env templates, which hold
# names without values, stay readable. A folder whose name matches is denied whole.
LEAN_SECRET_NAMES='.env .env.* *.pem *.key *.p12 *.pfx *secret* *credential*'
LEAN_SECRET_KEEP='.env.example .env.sample .env.template'
# Folders lean_secret_files doesn't enter: the git state and installed dependencies (third-party
# code: their credential-provider modules and CA bundles must stay readable, and they are large).
LEAN_SECRET_SKIP_DIRS='.git node_modules bower_components .venv venv .tox vendor Pods target .gradle'
# The names also denied by glob anywhere in the project, for files that appear after the session
# starts: only names no template has (a glob can't leave .env.example out: Claude Code's Read
# rules and Codex take no exception to a deny) and none a dependency ships (*.pem: CA bundles).
LEAN_SECRET_GLOBS='.env .env.local .env.*.local *.key *.p12 *.pfx'

# lean_secret_files <dir> [<skip path>] — the files and folders under <dir> (not <dir> itself)
# whose basename matches LEAN_SECRET_NAMES but not LEAN_SECRET_KEEP, any case, NUL-terminated,
# as found (links not followed; a matching folder is listed and not entered). LEAN_SECRET_SKIP_DIRS
# and <skip path> (with what it holds) are not entered; a folder holding <skip path> is entered
# but never listed (a project inside a repository folder named like a secret stays readable).
lean_secret_files() (
  set -f   # the names are patterns for find, not for the shell
  local dir="$1" skip="${2:-}" n match=() keep=() prune=() hold=() d
  for n in $LEAN_SECRET_NAMES; do match+=(-o -iname "$n"); done
  for n in $LEAN_SECRET_KEEP; do keep+=(-o -iname "$n"); done
  for n in $LEAN_SECRET_SKIP_DIRS; do prune+=(-o -name "$n"); done
  if [ -n "$skip" ]; then
    prune+=(-o -path "$skip")
    d=$(dirname "$skip")
    while [ "$d" != "$dir" ] && [ "$d" != / ] && [ "$d" != . ]; do hold+=(-o -path "$d"); d=$(dirname "$d"); done
  fi
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 \( -type d \( "${prune[@]:1}" \) -prune \) \
    -o \( -false ${hold[@]+"${hold[@]}"} \) \
    -o \( \( "${match[@]:1}" \) ! \( "${keep[@]:1}" \) \( -type d -prune -print0 -o -print0 \) \) 2>/dev/null
)

# lean_env_drop <project> [<keep regex>] — the exported variables to drop, NUL-terminated:
# the names matching LEAN_SECRET_ENV (connection strings such as DATABASE_URL too), except
# those listed in .harness.json::lean.env_passthrough and those matching <keep regex>.
lean_env_drop() {
  local pass n
  pass=$(jq -r '.lean.env_passthrough // [] | .[]' "$1/.harness.json" 2>/dev/null || true)
  while IFS= read -r -d '' n; do
    printf '%s\n' "$n" | grep -qiE "$LEAN_SECRET_ENV" || continue
    ! printf '%s\n' "$n" | grep -qE "$LEAN_KEEP_ENV" || continue
    [ -z "${2:-}" ] || ! printf '%s\n' "$n" | grep -qE "$2" || continue
    [ -n "$pass" ] && grep -qxF -- "$n" <<<"$pass" && continue
    printf '%s\0' "$n"
  done < <(lean_env_names)
}

# lean_env_args <project> [<keep regex>] — sets LEAN_ENV_ARGS to `env` arguments: -u for each
# lean_env_drop name, then the sessions' variables (sandbox.sh's settings env). Returns 1
# when the environment's names can't be listed (lean_env_names).
lean_env_args() {
  local n
  LEAN_ENV_ARGS=()
  lean_env_names >/dev/null || { echo "lean: can't list the environment's variables (no env -0, no perl): refusing to run without dropping the secret-looking ones" >&2; return 1; }
  while IFS= read -r -d '' n; do [ -z "$n" ] || LEAN_ENV_ARGS+=(-u "$n"); done < <(lean_env_drop "$@")
  # Proxy variables (any name ending in "proxy", any case: http_proxy, HTTPS_PROXY, ALL_PROXY,
  # npm_config_https_proxy, YARN_HTTPS_PROXY, BUNDLE_HTTP_PROXY, ...) are kept, but without the
  # credentials a URL may carry: everything up to the last @ goes
  # (http://user:pa/ss@proxy:8080 -> http://proxy:8080); a value holding an @ that isn't then
  # [scheme://]host[:port][/] is dropped. Unless .harness.json::lean.env_passthrough lists the name.
  local pass v s set=()
  pass=$(jq -r '.lean.env_passthrough // [] | .[]' "$1/.harness.json" 2>/dev/null || true)
  while IFS= read -r -d '' n; do
    printf '%s\n' "$n" | grep -qiE 'proxy$' || continue
    [ -n "$pass" ] && grep -qxF -- "$n" <<<"$pass" && continue
    v=$(printenv -- "$n") || continue
    case "$v" in *@*) ;; *) continue ;; esac
    s=""
    case "$v" in *$'\n'*) ;; *) s=$(printf '%s\n' "$v" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)?.*@#\1#') ;; esac
    if printf '%s\n' "$s" | grep -qE '^([A-Za-z][A-Za-z0-9+.-]*://)?(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(:[0-9]+)?/?$'; then
      set+=("$n=$s")
    else
      LEAN_ENV_ARGS+=(-u "$n")
    fi
  done < <(lean_env_names)
  # LEAN_GATE_UNSANDBOXED never reaches a session or the commands the gate runs: it is the
  # caller's choice for its own gate run, not something session-written code should see.
  LEAN_ENV_ARGS+=(-u LEAN_GATE_UNSANDBOXED)
  LEAN_ENV_ARGS+=(${set[@]+"${set[@]}"} RUSTC_WRAPPER= CARGO_BUILD_RUSTC_WRAPPER= GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_GLOBAL=/dev/null)
}

# lean_in_group <command...> — runs the command in a new session (setsid: its own process
# group, and no controlling terminal, so it can't push input into the caller's terminal with
# TIOCSTI or stop the caller's job), with stdin from /dev/null and no file descriptor above 2
# (what the caller holds open stays out of reach). When it ends, whatever it left running in
# that group (a server or a background job the suite started) is killed, with a [WARN] on
# stderr; the exit status stays the command's. A process that starts a session or group of
# its own is out of the group and not looked for. Without perl (setsid, closing the
# descriptors), nothing runs: exit 125 (fail closed).
lean_in_group() {
  command -v perl >/dev/null 2>&1 || { echo "lean: perl is needed to run the command in a session of its own, without a terminal or inherited descriptors: refusing to run it" >&2; return 125; }
  local pid rc=0
  perl -e '
    use POSIX ();
    my $sid = POSIX::setsid();
    defined $sid && $sid > 0 or die "lean_in_group: setsid: $!\n";
    opendir(my $d, "/dev/fd") or die "lean_in_group: /dev/fd: $!\n";
    my @fds = grep { /^\d+$/ && $_ > 2 } readdir $d;
    closedir $d;
    POSIX::close($_) for @fds;
    open(STDIN, "<", "/dev/null") or die "lean_in_group: /dev/null: $!\n";
    exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"' "$@" &
  pid=$!
  trap 'kill -TERM -- "-$pid" 2>/dev/null' INT TERM
  wait "$pid" || rc=$?
  trap - INT TERM
  if kill -0 -- "-$pid" 2>/dev/null; then
    echo "[WARN] lean: processes the command started were still running when it ended (killed; a suite should stop what it starts)" >&2
    kill -TERM -- "-$pid" 2>/dev/null; sleep 1; kill -KILL -- "-$pid" 2>/dev/null
  fi
  return "$rc"
}

# lean_run_lock <project> / lean_run_unlock <project> — one sandboxed run of a project at a
# time (two suites of one project at once would trip over each other's files, ports and
# databases). The lock is a folder in the project's lean state, which the profile can neither
# read nor write, holding "<pid> <start time>" of the holder (the shell that took it); a holder
# that is gone loses it, and so does one whose pid now belongs to another process (a different
# start time), and a lock left without a holder for 5 s. Waits up to LEAN_RUN_LOCK_WAIT seconds
# (default 900), then fails.
lean_proc_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }
lean_run_lock() {
  local dir holder hpid waited=0
  dir="$(lean_state_dir "$1")/tmp/run.lock" || return 1
  mkdir -p "$(dirname "$dir")" || return 1
  until mkdir "$dir" 2>/dev/null; do
    holder=$(cat "$dir/pid" 2>/dev/null || true); hpid=${holder%% *}
    if [ -n "$hpid" ] && { ! kill -0 "$hpid" 2>/dev/null || [ "$(lean_proc_start "$hpid")" != "${holder#* }" ]; }; then
      rm -rf "$dir"; continue
    fi
    if [ -z "$hpid" ] && [ "$waited" -ge 5 ]; then rm -rf "$dir"; continue; fi
    if [ "$waited" -ge "${LEAN_RUN_LOCK_WAIT:-900}" ]; then
      echo "lean: another sandboxed run of this project (pid ${hpid:-?}) still holds $dir: failing" >&2
      return 1
    fi
    [ "$waited" != 0 ] || echo "lean: waiting for another sandboxed run of this project (pid ${hpid:-?}) to end" >&2
    sleep 1; waited=$((waited + 1))
  done
  printf '%s %s\n' "$$" "$(lean_proc_start "$$")" > "$dir/pid"
}
lean_run_unlock() { rm -rf "$(lean_state_dir "$1")/tmp/run.lock"; }

# lean_in_session <project> — true inside a session run.sh opened: the adapters set
# LEAN_SESSION=1 in its environment, and, should a command unset that, the project's lean state
# (which the sessions' sandbox denies) refuses to be listed ("Operation not permitted").
lean_in_session() {
  local state err
  [ "${LEAN_SESSION:-}" != 1 ] || return 0
  state=$(lean_state_dir "$1" 2>/dev/null) || return 1
  err=$(LC_ALL=C ls -- "$state" 2>&1 >/dev/null) && return 1
  case "$err" in *"not permitted"*) return 0 ;; esac
  return 1
}

# LEAN_SESSION_REFUSAL — why nothing runs when lean_sandbox_prepare finds itself in a session.
LEAN_SESSION_REFUSAL="inside a lean session: the full suite, ./init.sh and the gate run after the session, outside it (LEAN_GATE_UNSANDBOXED is ignored here); run the feature's own tests directly"

# lean_sandbox_prepare <project> — decides how lean_sandboxed runs commands for the
# project's open lean feature and sets LEAN_SANDBOX: "sandbox" (LEAN_PROFILE holds the seatbelt profile),
# "unsandboxed: <why>" (no sandbox-exec, or LEAN_GATE_UNSANDBOXED=1), "broken: <why>"
# (sandbox-exec is there but can't apply the profile, e.g. when already inside a sandbox) or
# "session: <why>" (inside a lean session, lean_in_session: nothing runs, and
# LEAN_GATE_UNSANDBOXED=1 is ignored; it is for the gate and the tests run from outside).
# LEAN_SANDBOX_WARN holds sandbox.sh's [WARN] lines (allowed_domains opening the network):
# every caller prints them.
lean_sandbox_prepare() {
  local err why
  LEAN_PROFILE="" LEAN_SANDBOX_WARN=""
  if lean_in_session "$1"; then LEAN_SANDBOX="session: $LEAN_SESSION_REFUSAL"; return 0; fi
  if [ "${LEAN_GATE_UNSANDBOXED:-}" = 1 ]; then LEAN_SANDBOX="unsandboxed: LEAN_GATE_UNSANDBOXED=1"; return 0; fi
  if ! command -v sandbox-exec >/dev/null 2>&1; then
    LEAN_SANDBOX="unsandboxed: no sandbox-exec on this platform ($(uname -s))"; return 0
  fi
  err=$(mktemp) || { LEAN_SANDBOX="broken: no temp file for lean/sandbox.sh's messages"; return 0; }
  if ! LEAN_PROFILE=$("$LEAN_LIB_DIR/sandbox.sh" "$1" --seatbelt 2>"$err"); then
    # Name sandbox.sh's own reason (its first non-[WARN] lines) so the gate's message says why.
    why=$(grep -v '^\[WARN\]' "$err" | grep -v '^[[:space:]]*$' | head -3 | tr '\n' ' ' | sed 's/ *$//')
    rm -f "$err"; LEAN_SANDBOX="broken: lean/sandbox.sh could not build the profile${why:+: $why}"; return 0
  fi
  LEAN_SANDBOX_WARN=$(grep '^\[WARN\]' "$err" || true); rm -f "$err"
  if ! sandbox-exec -p "$LEAN_PROFILE" true 2>/dev/null; then
    LEAN_SANDBOX="broken: sandbox-exec can't apply the profile here (already inside a sandbox?)"; return 0
  fi
  LEAN_SANDBOX=sandbox
}

# lean_sandboxed <project> <command> — runs `bash -c <command>` in <project> as
# lean_sandbox_prepare decided: under the rules of the feature's sessions (sandbox.sh
# --seatbelt: the same reads, writes only in the project, /private/tmp and a fresh TMPDIR of
# its own, network only to localhost, unix sockets only in the project, the local database
# sockets and that TMPDIR, plus the specific denies listed there), one run of the project at a
# time (lean_run_lock); unsandboxed when it said so. Either way with the sessions' environment
# (lean_env_args) and in a new session without a terminal, stdin or inherited descriptors, its
# process group killed when the command ends (lean_in_group). Exit 125 when the sandbox is
# broken, the environment can't be scrubbed or the lock can't be taken.
lean_sandboxed() {
  local rc=0 run_tmp
  lean_env_args "$1" || return 125
  case "${LEAN_SANDBOX:-}" in
    sandbox)
      lean_run_lock "$1" || return 125
      if ! run_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lean-run.XXXXXX") || ! run_tmp=$(cd "$run_tmp" && pwd -P); then
        lean_run_unlock "$1"; return 125
      fi
      (cd "$1" && lean_in_group env "${LEAN_ENV_ARGS[@]}" TMPDIR="$run_tmp/" sandbox-exec -p "$LEAN_PROFILE
(allow file-write* (subpath \"$run_tmp\"))
(allow network-outbound (remote unix-socket (subpath \"$run_tmp\")))" bash -c "$2") || rc=$?
      rm -rf "$run_tmp"
      lean_run_unlock "$1"
      return "$rc" ;;
    unsandboxed:*) (cd "$1" && lean_in_group env "${LEAN_ENV_ARGS[@]}" bash -c "$2") ;;
    *) echo "lean: ${LEAN_SANDBOX:-lean_sandbox_prepare did not run}" >&2; return 125 ;;
  esac
}

# lean_z_lines — NUL-separated names on stdin, one per line; a name holding a newline is printed
# quoted (printf %q), so it stays one line and matches no listed path.
lean_z_lines() {
  local n
  while IFS= read -r -d '' n; do
    case "$n" in *$'\n'*) printf '%q\n' "$n" ;; *) printf '%s\n' "$n" ;; esac
  done
}

# lean_repo_changes <base> — every changed (against <base>) or untracked, non-ignored file of
# the current directory's repository, from its root (git diff --no-relative --no-renames: a
# rename is listed under both its paths), sorted, one per line. lean/gate.sh checks this set; lean/chain.sh lists it in its close line.
lean_repo_changes() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  { git diff -z --no-relative --no-renames --name-only "$1"; git -C "$top" ls-files -z --others --exclude-standard; } \
    | lean_z_lines | sed '/^$/d' | sort -u
}

# Usage report: <state>/lean/<name>/usage.tsv, append-only, one row per session run.sh opens
# (implement, review, fix; headless or interactive, chained or by hand). Columns:
#   at feature step mode tool model turns input cache_read cache_write output seconds cost_usd note
# From the result JSON the adapter wrote (claude -p's, or codex.sh's in the same shape):
# model = the keys of claude's modelUsage, most output first (else the model codex.sh's JSON
# reports, else the configured model, "default" when none; codex-m3: "minimax"),
# turns = num_turns (Codex: completed items), tokens summed over modelUsage when present (it
# counts subagents too), else from usage. input is the uncached input for every tool: Codex
# reports the cached tokens inside input_tokens, so they are subtracted. cost_usd only as the
# CLI reports it (total_cost_usd); "-" for Codex (none) and claude-mini (Claude Code's estimate
# at Anthropic prices, not what MiniMax bills). No price table anywhere. A field the JSON lacks
# is "?"; an interactive session has no result JSON: its row holds the duration only. A
# session `run.sh chain` stopped at its step cap returns nothing to run.sh: the chain records
# its row (result "?", the note given: turns and tokens "?", cost "?" or "-" as above).
# seconds: the session's wall time as run.sh measured it (a stopped session: the step's, as
# the chain measured it). Best-effort: a failure here never changes a step's outcome.
LEAN_USAGE_HEADER='at	feature	step	mode	tool	model	turns	input	cache_read	cache_write	output	seconds	cost_usd	note'

lean_usage_file() { printf '%s/lean/%s/usage.tsv\n' "$(lean_state_dir "$1")" "$2"; }

# lean_usage_record <project> <name> <step> <mode> <tool> <model|-> <seconds> <result_json|-|?> [<note>]
# (- : an interactive session; ? : a session stopped before it returned, with <note>).
lean_usage_record() {
  local file tool="$5" model="$6" res="$8" parsed="" jmodel="" turns="" in="" cr="" cw="" out="" cost="" note=""
  file=$(lean_usage_file "$1" "$2") || return 0
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  if [ "$model" = - ]; then model=default; [ "$tool" != codex-m3 ] || model=minimax; fi
  if [ "$res" = - ]; then
    turns=- in=- cr=- cw=- out=- cost=- note="interactive (not measured)"
  elif [ "$res" = '?' ]; then
    turns='?' in='?' cr='?' cw='?' out='?' cost='?' note="${9:-stopped}"
    case "$tool" in claude-mini|codex|codex-m3) cost=- ;; esac
  else
    parsed=$(jq -r 'def num: if type == "number" then (floor | tostring) else "?" end;
      select(type == "object")
      | (.model | if type == "string" then gsub("[\t\n]"; " ") else "" end) as $rm
      | (.modelUsage | if type == "object" and length > 0 then . else null end) as $mu
      | (if $mu then {in: ([$mu[] | .inputTokens // 0] | add), cr: ([$mu[] | .cacheReadInputTokens // 0] | add),
                      cw: ([$mu[] | .cacheCreationInputTokens // 0] | add), out: ([$mu[] | .outputTokens // 0] | add),
                      m: ($mu | to_entries | sort_by(-(.value.outputTokens // 0)) | map(.key) | join("+"))}
         else (.usage | if type == "object" then . else {} end) as $u
           | {in: $u.input_tokens, cr: $u.cache_read_input_tokens, cw: $u.cache_creation_input_tokens,
              out: $u.output_tokens, m: $rm} end) as $t
      | (if (.tool == "codex" or .tool == "codex-m3") and ($t.in | type) == "number" and ($t.cr | type) == "number"
         then ([$t.in - $t.cr, 0] | max) else $t.in end) as $in
      | [($t.m | if . == "" then "-" else gsub("[\t\n]"; " ") end), (.num_turns | num), ($in | num), ($t.cr | num),
         ($t.cw | num), ($t.out | num), (.total_cost_usd | if type == "number" then tostring else "-" end),
         (if .subtype == "error_max_turns" then "max_turns"
          elif .is_error == true then "is_error" else "" end)] | join("\t")' "$res" 2>/dev/null | head -1) || parsed=""
    if [ -n "$parsed" ]; then
      IFS=$'\t' read -r jmodel turns in cr cw out cost note <<<"$parsed" || true
      [ "${jmodel:--}" = - ] || model="$jmodel"
    else
      turns='?' in='?' cr='?' cw='?' out='?' cost='?' note="no readable result JSON"
    fi
    [ "$tool" != claude-mini ] || cost=-
  fi
  [ -s "$file" ] || printf '%s\n' "$LEAN_USAGE_HEADER" >> "$file" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" \
    "$tool" "$model" "${turns:-?}" "${in:-?}" "${cr:-?}" "${cw:-?}" "${out:-?}" "$7" "${cost:-?}" "$note" \
    >> "$file" 2>/dev/null || return 0
}

# lean_usage_count <project> <name> — how many rows the feature has (0: none).
lean_usage_count() {
  local file
  file=$(lean_usage_file "$1" "$2") || { echo 0; return 0; }
  [ -f "$file" ] || { echo 0; return 0; }
  awk 'NR > 1' "$file" | wc -l | tr -d ' '
}

# lean_usage_table <project> <name> [<skip>] — the feature's rows after the first <skip> as a
# compact table: tokens in k/M, a sum row over the rows shown (a column with no number in any
# row: "?"; the cost summed over the reported ones only), and a pointer to the skipped rows.
# Fails, printing nothing, when there is no row to show.
lean_usage_table() {
  local file
  file=$(lean_usage_file "$1" "$2") || return 1
  [ -f "$file" ] || return 1
  awk -F'\t' -v skip="${3:-0}" -v name="$2" '
    function tok(x) { if (x !~ /^[0-9]+$/) return x; if (x >= 1e6) return sprintf("%.1fM", x / 1e6)
                      if (x >= 1e3) return sprintf("%.1fk", x / 1e3); return x }
    function dur(s) { return (s ~ /^[0-9]+$/) ? sprintf("%dm%02ds", int(s / 60), s % 60) : s }
    function money(c) { return (c ~ /^[0-9.]+$/) ? sprintf("$%.2f", c) : c }
    function add(i, v) { if (v ~ /^[0-9]+$/) { sum[i] += v; has[i] = 1 } }
    function total(i) { return has[i] ? sum[i] : "?" }
    function line(a, b, c, d, e, f, g, h, i, j, k, l) {
      printf "  %-9s %-6s %-11s %-24s %5s %6s %7s %7s %6s %7s %6s%s\n", a, b, c, substr(d, 1, 24), e, f, g, h, i, j, k, (l == "" ? "" : "  " l)
    }
    NR == 1 || NR - 1 <= skip { next }
    { n++; row[n] = $0
      for (i = 7; i <= 12; i++) add(i, $i)
      if ($13 ~ /^[0-9.]+$/) { cost += $13; costs++ } }
    END {
      if (n == 0) exit 1
      printf "usage (%s: %d session%s%s):\n", name, n, (n == 1 ? "" : "s"),
             (skip > 0 ? sprintf("; %d earlier: lean/run.sh usage %s", skip, name) : "")
      line("step", "mode", "tool", "model", "turns", "in", "c.read", "c.write", "out", "time", "cost", "")
      for (r = 1; r <= n; r++) { split(row[r], f, "\t")
        line(f[3], f[4], f[5], f[6], f[7], tok(f[8]), tok(f[9]), tok(f[10]), tok(f[11]), dur(f[12]), money(f[13]), f[14]) }
      line("sum", "", "", "", total(7), tok(total(8)), tok(total(9)), tok(total(10)), tok(total(11)),
           dur(total(12)), (costs ? money(cost) : "-"), "")
    }' "$file"
}
