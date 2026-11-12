#!/usr/bin/env bash
# sync_postgres_payload_test.sh — the payloads scripts/sync_postgres.sh sends to
# the mirror's RPCs, checked against a stubbed curl (no Postgres, no network):
#
#   1. upsert_feature carries mode / plan approval (null and false for a
#      feature without a mode), upsert_session carries the review fields, so a
#      dashboard can tell a lean close from a reviewer one.
#   2. A mirror whose RPCs predate those fields (migration 0005 not applied)
#      still gets every row, without them, and sync warns once — the retry
#      fires only on PostgREST's "function not found" (PGRST202).
#   3. Any other failure (a 500) is reported per row, with no retry and no
#      lean-mode warning.
#   4. upsert_feature carries out_of_scope ([] when none), upsert_session
#      surfaces (null when not declared) and surfaces_required (migration 0006);
#      a current mirror gets them on the first call with no 0006 warning.
#   5. A mirror with 0005 but without 0006 gets every row with the lean fields
#      and without the scope ones, and one 0006 warning (no lean-mode one).
#
# Usage: bash tests/sync_postgres_payload_test.sh   (exits non-zero on the first failure)

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
echo '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state","supabase_url_env":"T_URL","supabase_key_env":"T_KEY","supabase_rest_path":""}' > "$P/.harness.json"
sqlite3 "$P/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql"
sqlite3 "$P/harness.db" "INSERT INTO projects (id, slug) VALUES ('p1','t');"

# curl stub: logs "<rpc name> <payload>" per POST and answers 200, or 404 with
# PGRST202 when STUB_OLD_MIRROR=1 (no 0005/0006) or STUB_MIRROR_0005=1 (no
# 0006) and the payload has a field those RPCs don't know, or 500 on every
# row upsert when STUB_FAIL=1.
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
url="" data="" w=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) data="$2"; shift 2 ;;
    -w) w="$2"; shift 2 ;;
    -X|-H|-m|-o) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$data" ] || exit 0
printf '%s %s\n' "${url##*/}" "$(jq -c . <<<"$data")" >> "$STUB_LOG"
code=200 body='{}'
if [ "${STUB_OLD_MIRROR:-0}" = 1 ] && grep -qE '"p_(mode|plan_approval|plan_approved_by|plan_approved_at|review_status|reviewed_by|reviewed_at|out_of_scope|surfaces|surfaces_required)"' <<<"$data"; then
  code=404 body='{"code":"PGRST202","details":null,"hint":null,"message":"Could not find the function"}'
fi
if [ "${STUB_MIRROR_0005:-0}" = 1 ] && grep -qE '"p_(out_of_scope|surfaces|surfaces_required)"' <<<"$data"; then
  code=404 body='{"code":"PGRST202","details":null,"hint":null,"message":"Could not find the function"}'
fi
if [ "${STUB_FAIL:-0}" = 1 ] && [[ "$url" == */upsert_feature || "$url" == */upsert_session ]]; then
  code=500 body='{"code":"XX000","message":"boom"}'
fi
printf '%s' "$body"
[ -n "$w" ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$WORK/bin/curl"

H() { (cd "$P" && HOME="$WORK/home" HARNESS_AGENT=implementer ANTHROPIC_MODEL= bash scripts/harness.sh "$@") 2>&1; }
q() { sqlite3 "$P/harness.db" "$1"; }
sync_run() { : > "$WORK/log"; (cd "$P" && HOME="$WORK/home" PATH="$WORK/bin:$PATH" STUB_LOG="$WORK/log" T_URL=http://mirror.test T_KEY=k env "$@" bash scripts/sync_postgres.sh) 2>&1; }
# payload <rpc> <jq select on the payload> — the first matching payload, compact.
payload() { grep "^$1 " "$WORK/log" | cut -d' ' -f2- | jq -c "select($2)" | head -1; }

H add-feature --name plain --title Plain >/dev/null || die "add plain"
H add-feature --name leanf --title Lean --mode normal --approval --out-of-scope "no new endpoints" --out-of-scope "no UI" >/dev/null || die "add leanf"
q "UPDATE features SET plan_approved_by='Tester', plan_approved_at='2026-10-30T10:00:00.000Z' WHERE name='leanf';"
fid=$(q "SELECT id FROM features WHERE name='leanf';")
q "INSERT INTO session_log (project_id, feature_id, agent, review_status, reviewed_by, reviewed_at, closed_at, surfaces)
   VALUES ('p1', $fid, 'implementer', 'lean', 'harness (lean gate)', '2026-10-30T11:00:00.000Z', '2026-10-30T11:01:00.000Z', '[\"src/api/**\",\"tests/api_*.sh\"]');"
q "INSERT INTO session_log (project_id, feature_id, agent, closed_at, surfaces_required) VALUES ('p1', NULL, 'bootstrap', '2026-10-30T09:00:00.000Z', 0);"

echo "1. payloads carry the lean fields"
out=$(sync_run) || die "sync: $out"
grep -q 'mirror sync complete' <<<"$out" || die "sync should complete: $out"
grep -q 'predate lean mode' <<<"$out" && die "a current mirror must not get the compat warning: $out"
f=$(payload upsert_feature '.p_name == "leanf"')
jq -e '.p_mode == "normal" and .p_plan_approval == true and .p_plan_approved_by == "Tester"
  and .p_plan_approved_at == "2026-10-30T10:00:00.000Z" and .p_sdd == false and .p_status == "pending"' <<<"$f" >/dev/null \
  || die "lean feature payload: $f"
f=$(payload upsert_feature '.p_name == "plain"')
jq -e '.p_mode == null and .p_plan_approval == false and .p_plan_approved_by == null and has("p_title")' <<<"$f" >/dev/null \
  || die "a feature without a mode sends mode null and no approval: $f"
s=$(payload upsert_session '.p_feature_name == "leanf"')
jq -e '.p_review_status == "lean" and .p_reviewed_by == "harness (lean gate)" and .p_reviewed_at == "2026-10-30T11:00:00.000Z"' <<<"$s" >/dev/null \
  || die "lean session payload: $s"
s=$(payload upsert_session '.p_agent == "bootstrap"')
jq -e '.p_review_status == null and .p_reviewed_by == null and .p_feature_name == null' <<<"$s" >/dev/null \
  || die "unreviewed session payload: $s"
pass "upsert_feature sends mode and plan approval, upsert_session the review fields"

echo "2. a mirror without migration 0005"
out=$(sync_run STUB_OLD_MIRROR=1) || die "sync: $out"
[ "$(grep -c 'predate lean mode' <<<"$out")" = 1 ] || die "sync should warn exactly once: $out"
grep -q 'predate scope surfaces' <<<"$out" && die "an old mirror gets only the lean-mode warning: $out"
grep -q 'upsert_feature failed\|upsert_session failed' <<<"$out" && die "no row may fail on an old mirror: $out"
for name in plain leanf; do
  f=$(grep '^upsert_feature ' "$WORK/log" | cut -d' ' -f2- | jq -c "select(.p_name == \"$name\" and (has(\"p_mode\") | not))" | head -1)
  [ -n "$f" ] || die "feature $name must be retried without the lean fields: $(cat "$WORK/log")"
done
[ "$(grep '^upsert_session ' "$WORK/log" | cut -d' ' -f2- | jq -c 'select(has("p_review_status") | not)' | wc -l | tr -d ' ')" = 2 ] \
  || die "both sessions must be retried without the review fields: $(cat "$WORK/log")"
pass "an old mirror still gets every row, without the new fields, and one warning"

echo "3. any other failure is not retried"
out=$(sync_run STUB_FAIL=1) || die "sync: $out"
grep -q 'predate lean mode' <<<"$out" && die "a 500 must not get the lean-mode warning: $out"
[ "$(grep -c 'upsert_feature failed' <<<"$out")" = 2 ] || die "each feature must report its failure: $out"
[ "$(grep -c 'upsert_session failed' <<<"$out")" = 2 ] || die "each session must report its failure: $out"
grep -q 'HTTP 500' <<<"$out" || die "the failure warning should carry the HTTP status: $out"
[ "$(grep -c '^upsert_feature ' "$WORK/log")" = 2 ] || die "a 500 must not be retried: $(cat "$WORK/log")"
[ "$(grep -c '^upsert_session ' "$WORK/log")" = 2 ] || die "a 500 must not be retried: $(cat "$WORK/log")"
pass "a 500 is reported per row, without a retry or the lean-mode warning"

echo "4. payloads carry the scope fields (migration 0006)"
out=$(sync_run) || die "sync: $out"
grep -q 'predate scope surfaces\|predate lean mode' <<<"$out" && die "a current mirror (with 0006) must not get a compat warning: $out"
[ "$(grep -c '^upsert_feature ' "$WORK/log")" = 2 ] && [ "$(grep -c '^upsert_session ' "$WORK/log")" = 2 ] \
  || die "a current mirror takes every row on the first call, no 0006 retry: $(cat "$WORK/log")"
f=$(payload upsert_feature '.p_name == "leanf"')
jq -e '.p_out_of_scope == ["no new endpoints", "no UI"]' <<<"$f" >/dev/null || die "out_of_scope payload: $f"
f=$(payload upsert_feature '.p_name == "plain"')
jq -e '.p_out_of_scope == []' <<<"$f" >/dev/null || die "a feature without out-of-scope lines sends []: $f"
s=$(payload upsert_session '.p_feature_name == "leanf"')
jq -e '.p_surfaces == ["src/api/**", "tests/api_*.sh"] and .p_surfaces_required == true' <<<"$s" >/dev/null \
  || die "session surfaces payload: $s"
s=$(payload upsert_session '.p_agent == "bootstrap"')
jq -e '.p_surfaces == null and .p_surfaces_required == false' <<<"$s" >/dev/null \
  || die "a session without surfaces sends null and its surfaces_required: $s"
pass "upsert_feature sends out_of_scope, upsert_session surfaces and surfaces_required; a current mirror gets no 0006 fallback warning or retry"

echo "5. a mirror with 0005 but without 0006"
out=$(sync_run STUB_MIRROR_0005=1) || die "sync: $out"
[ "$(grep -c 'predate scope surfaces' <<<"$out")" = 1 ] || die "sync should warn exactly once about 0006: $out"
grep -q 'predate lean mode' <<<"$out" && die "a 0005 mirror must not get the lean-mode warning: $out"
grep -q 'upsert_feature failed\|upsert_session failed' <<<"$out" && die "no row may fail on a 0005 mirror: $out"
f=$(grep '^upsert_feature ' "$WORK/log" | cut -d' ' -f2- | jq -c 'select(.p_name == "leanf" and (has("p_out_of_scope") | not))' | head -1)
jq -e '.p_mode == "normal" and .p_plan_approval == true' <<<"$f" >/dev/null \
  || die "the retry must keep the lean fields and drop out_of_scope: $(cat "$WORK/log")"
[ "$(grep '^upsert_session ' "$WORK/log" | cut -d' ' -f2- \
  | jq -c 'select((has("p_surfaces") or has("p_surfaces_required") | not) and has("p_review_status"))' | wc -l | tr -d ' ')" = 2 ] \
  || die "both sessions must be retried with the review fields and without the surfaces: $(cat "$WORK/log")"
pass "a 0005 mirror gets every row with the lean fields, without the scope ones, and one 0006 warning"

echo "all $PASS checks passed"
