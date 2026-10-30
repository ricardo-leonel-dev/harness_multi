#!/usr/bin/env bash
# notion_lean_test.sh — the lean flow's Notion properties, offline (curl is
# stubbed with canned Notion responses):
#
#   1. notion-check maps the optional "Mode" select (Normal/Risk, any case;
#      anything else or missing -> null) and "Plan approval" checkbox.
#   2. notion-import gives them add-feature --mode/--approval's validation, for
#      every row before inserting any; a row with SDD and a mode is imported as
#      sdd without the mode, and a Risk row with Plan approval ticked as risk,
#      each with a warning.
#   3. notion-create-feature --mode/--approval set those properties when the
#      database has them, skip them when it doesn't, and refuse what add-feature
#      refuses; --mode risk --approval warns and leaves the checkbox unticked.
#
# Usage: bash tests/notion_lean_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

P="$WORK/p"
mkdir -p "$P/scripts" "$WORK/bin" "$WORK/home"
cp "$TOOLKIT_DIR"/scripts/*.sh "$TOOLKIT_DIR/scripts/agent_usage.py" "$P/scripts/"
echo '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state","notion_database_id":"db1","notion_token_env":"T_NOTION"}' > "$P/.harness.json"
sqlite3 "$P/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql"
sqlite3 "$P/harness.db" "INSERT INTO projects (id, slug) VALUES ('p1','t');"

# curl stub: GET .../databases/<id> -> $STUB_SCHEMA, POST .../query -> $STUB_QUERY,
# POST .../pages -> logs the payload to $STUB_LOG and answers a created page.
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) data="$2"; shift 2 ;;
    -X|-H|-m|-o|-w) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */query) cat "$STUB_QUERY" ;;
  */pages) jq -c . <<<"$data" > "$STUB_LOG"; printf '{"id":"page1","url":"https://notion.test/page1"}' ;;
  */databases/*) cat "$STUB_SCHEMA" ;;
esac
printf '\n200'
SH
chmod +x "$WORK/bin/curl"

H() { (cd "$P" && HOME="$WORK/home" PATH="$WORK/bin:$PATH" T_NOTION=tok STUB_SCHEMA="$WORK/schema.json" \
  STUB_QUERY="$WORK/query.json" STUB_LOG="$WORK/page.json" HARNESS_AGENT=implementer ANTHROPIC_MODEL= bash scripts/harness.sh "$@") 2>&1; }
q() { sqlite3 "$P/harness.db" "$1"; }

schema() { # schema <with lean properties: 1|0>
  jq -n --argjson lean "$1" '{properties: ({
      "Name": {id: "title", type: "title"}, "Project": {id: "prj", type: "select"},
      "Status": {id: "st", type: "status"}, "SDD": {id: "sdd", type: "checkbox"}}
    + (if $lean == 1 then {"Mode ": {id: "md", type: "select"}, "Plan approval": {id: "pa", type: "checkbox"}} else {} end))}' \
    > "$WORK/schema.json"
}
page() { # page <id> <title> <mode select name or ""> <plan approval true|false|none> [sdd]
  jq -n --arg id "$1" --arg t "$2" --arg m "$3" --arg a "$4" --arg sdd "${5:-false}" '{id: $id, properties: ({
      "Name": {title: [{plain_text: $t}]}, "Status": {status: {name: "Ready"}},
      "SDD": {checkbox: ($sdd == "true")}}
    + (if $m != "" then {"Mode ": {select: {name: $m}}} else {} end)
    + (if $a != "none" then {"Plan approval": {checkbox: ($a == "true")}} else {} end))}'
}

echo "1. notion-check"
schema 1
{ page n1 "Risky thing" "Risk" false; page n2 "Normal one" " normal " true; page n3 "Odd mode" "Fast" none
  page n4 "No mode" "" none; } | jq -s '{results: .}' > "$WORK/query.json"
out=$(H notion-check 2>/dev/null) || die "notion-check: $out"
jq -e 'map({key: .source_id, value: {mode, plan_approval}}) | from_entries == {
    n1: {mode: "risk", plan_approval: false}, n2: {mode: "normal", plan_approval: true},
    n3: {mode: null, plan_approval: false}, n4: {mode: null, plan_approval: false}}' <<<"$out" >/dev/null \
  || die "Mode/Plan approval mapping: $out"
jq -e '.[0] | has("sdd") and .name == "risky_thing"' <<<"$out" >/dev/null || die "the other fields stay as before: $out"
pass "notion-check maps Mode (any case, unknown -> null) and Plan approval"

echo "2. notion-import"
cat > "$WORK/bad.json" <<'JSON'
[{"name":"good_one","title":"Good","source_id":"g1","mode":"normal"},
 {"name":"bad_one","title":"Bad","source_id":"b1","mode":"fast"}]
JSON
out=$(H notion-import "$WORK/bad.json") && die "an invalid mode must fail the import: $out"
grep -q "bad_one: mode must be 'normal' or 'risk'" <<<"$out" || die "should name the row and the rule: $out"
[ "$(q "SELECT COUNT(*) FROM features;")" = 0 ] || die "nothing may be imported when a row is invalid"
echo '[{"name":"risky_ok","title":"R","mode":"risk","plan_approval":true},{"name":"bad_two","title":"B","plan_approval":true}]' > "$WORK/bad2.json"
out=$(H notion-import "$WORK/bad2.json") && die "a later invalid row still fails the import, risk + approval or not: $out"
grep -q "bad_two: --approval only applies with mode normal" <<<"$out" || die "should name the invalid row: $out"
echo '[{"name":"lonely","title":"L","plan_approval":true}]' > "$WORK/bad3.json"
H notion-import "$WORK/bad3.json" >/dev/null && die "plan approval without a mode must fail"
[ "$(q "SELECT COUNT(*) FROM features;")" = 0 ] || die "nothing may be imported after the refusals"

out=$(H notion-check 2>/dev/null) && printf '%s\n' "$out" | jq '[.[] | select(.source_id != "n3")]
  + [{source_id: "n5", name: "spec_and_mode", title: "Both", description: "", acceptance: [], sdd: true, mode: "risk", plan_approval: false},
     {source_id: "n6", name: "risk_ticked", title: "RT", description: "", acceptance: [], sdd: false, mode: "risk", plan_approval: true}]' > "$WORK/good.json"
out=$(H notion-import "$WORK/good.json") || die "import: $out"
grep -q "spec_and_mode has both SDD and a lean mode" <<<"$out" || die "sdd + mode should warn: $out"
[ "$(grep -c 'risk always requires approval; checkbox ignored' <<<"$out")" = 1 ] || die "risk + approval should warn once: $out"
grep -q '^\[WARN\].*risk_ticked' <<<"$out" || die "the risk + approval warning should name the card: $out"
got=$(q "SELECT name || ':' || sdd || ':' || COALESCE(mode, '-') || ':' || plan_approval FROM features ORDER BY feature_number;")
[ "$got" = "$(printf 'risky_thing:0:risk:1\nnormal_one:0:normal:1\nno_mode:0:-:0\nspec_and_mode:1:-:0\nrisk_ticked:0:risk:1')" ] \
  || die "imported modes: $got"
for f in risky_thing risk_ticked; do
  out=$(H claim "$f") && die "an imported risk feature still needs approve-plan: $out"
  grep -q 'approve-plan' <<<"$out" || die "claim should name approve-plan: $out"
done
pass "notion-import validates every row first, carries mode/plan approval, drops the mode next to SDD, and imports risk + approval as risk"

echo "3. notion-create-feature"
NC() { H notion-create-feature --project t --title "Card" --description "d" --status Ready "$@"; }
rm -f "$WORK/page.json"
out=$(NC --mode risk) || die "create risk: $out"
jq -e '.properties.md == {select: {name: "Risk"}} and (.properties | has("pa") | not) and (.properties | has("sdd") | not)' "$WORK/page.json" >/dev/null \
  || die "risk card: $(cat "$WORK/page.json")"
out=$(NC --mode normal --approval) || die "create normal: $out"
jq -e '.properties.md == {select: {name: "Normal"}} and .properties.pa == {checkbox: true}' "$WORK/page.json" >/dev/null \
  || die "normal card with approval: $(cat "$WORK/page.json")"
out=$(NC) || die "create plain: $out"
jq -e '(.properties | has("md") or has("pa")) | not' "$WORK/page.json" >/dev/null || die "plain card: $(cat "$WORK/page.json")"
schema 0
out=$(NC --mode normal --approval) || die "a database without the properties must still create the card: $out"
jq -e '(.properties | keys) == ["prj", "st", "title"]' "$WORK/page.json" >/dev/null || die "skipped properties: $(cat "$WORK/page.json")"
rm -f "$WORK/page.json"
NC --mode fast >/dev/null && die "an invalid --mode must fail"
NC --approval >/dev/null && die "--approval without --mode normal must fail"
NC --mode normal --sdd >/dev/null && die "--sdd with --mode must fail"
[ ! -e "$WORK/page.json" ] || die "a refused call must not create a card"
schema 1
out=$(NC --mode risk --approval) || die "--mode risk --approval should be accepted with a warning: $out"
grep -q '^\[WARN\].*risk always requires approval; checkbox ignored' <<<"$out" || die "risk + approval should warn: $out"
jq -e '.properties.md == {select: {name: "Risk"}} and (.properties | has("pa") | not)' "$WORK/page.json" >/dev/null \
  || die "a risk card with --approval reads like any risk card: $(cat "$WORK/page.json")"
pass "notion-create-feature sets Mode/Plan approval when present, skips them otherwise, refuses bad combinations, warns on risk + approval"

echo "all $PASS checks passed"
