#!/usr/bin/env bash
# Evidence index only: names are not proof of execution or semantic coverage.
# Usage: scripts/build_traceability.sh FEATURE --test tests/acceptance.sql
# Bash 3.2 compatible; no auto-discovery (R ids recur across unrelated features).
set -eu
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [ "$#" -ne 3 ] || { [ "$2" != --test ] && [ "$2" != --test-file ]; }; then
  echo "Usage: $0 FEATURE --test PATH" >&2; exit 2
fi
FEATURE="$1"
case "$FEATURE" in ''|*[!a-zA-Z0-9_-]*) echo 'Invalid feature slug' >&2; exit 2 ;; esac
REQ="specs/$FEATURE/requirements.md"
TEST="$3"
[ -f "$REQ" ] || { echo "Missing requirements: $REQ" >&2; exit 1; }
[ -f "$TEST" ] || { echo "Missing test: $TEST" >&2; exit 1; }
awk -v test="$TEST" '
FILENAME != test {
  if ($0 ~ /^##[[:space:]]+R[0-9]+([[:space:]]|$)/) {
    match($0, /R[0-9]+/); id=substr($0,RSTART,RLENGTH)
    if (id in seen) { print "Duplicate requirement " id > "/dev/stderr"; invalid=1 }
    seen[id]=1; ids[++n]=id
  }
  next
}
{
  # Join SQL lines to support multiline SELECT aliases. Skip full-line comments.
  if ($0 ~ /^[[:space:]]*--/) next
  statement=statement " " $0
  if ($0 !~ /;/) next
  if (statement ~ /\047PASS\047[[:space:]]+AS[[:space:]]+result/ &&
      match(statement, /\047t[0-9]+_[a-z0-9_]+\047[[:space:]]+AS[[:space:]]+test_case/)) {
    name=substr(statement,RSTART,RLENGTH); sub(/^\047/,"",name); sub(/\047.*$/,"",name)
    count=split(name,tokens,"_")
    for (i=1;i<=count;i++) if (tokens[i] ~ /^r[0-9]+$/) {
      id=toupper(tokens[i]); key=id SUBSEP name
      if (!(key in indexed)) {
        rows[id]=rows[id] (rows[id] == "" ? "" : "<br>") "`" name "` (" test ":" FNR ")"
        indexed[key]=1
      }
    }
  }
  statement=""
}
END {
  if (invalid || n == 0) { print "Invalid or empty requirement headings" > "/dev/stderr"; exit 1 }
  print "| Requirement | Named assertion location (evidence index) |"
  print "| --- | --- |"
  for (i=1;i<=n;i++) {
    id=ids[i]
    print "| " id " | " (rows[id] == "" ? "**MISSING named reference**" : rows[id]) " |"
    if (rows[id] == "") missing++
  }
  print "\n<!-- Evidence index only; tests must be run and coverage independently reviewed. -->"
  if (missing) { print missing " requirement(s) lack named references" > "/dev/stderr"; exit 1 }
}
' "$REQ" "$TEST"
