#!/usr/bin/env bash
# feature_delete_test.sh — end-to-end check of delete-feature in scripts/harness.sh,
# run against a throwaway project in a temp dir.
#
#   1. a target that matches no active feature fails and changes nothing.
#   2. a feature with an open in_progress session is refused; feature and
#      session are left untouched.
#   3. a blocked feature (paused session) is refused too.
#   4. after cancel-session --force, the same delete succeeds.
#   5. deleting an sdd feature whose spec reached spec_ready soft-deletes the
#      feature and its spec with the same deleted_at; another feature's spec
#      is untouched.
#   6. a new feature reusing the deleted name can be added and gets its own
#      active spec without colliding with the deleted one.
#
# Usage: bash tests/feature_delete_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

# new_project <dir> — minimal installed project: scripts, config, db, 3 features.
new_project() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cp "$TOOLKIT_DIR"/scripts/*.sh "$dir/scripts/"
  echo '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state"}' > "$dir/.harness.json"
  sqlite3 "$dir/harness.db" < "$TOOLKIT_DIR/db/schema.sqlite.sql"
  sqlite3 "$dir/harness.db" "INSERT INTO projects (id, slug) VALUES ('p1','t');
INSERT INTO features (project_id, feature_number, name, title) VALUES
  ('p1',1,'alpha','Alpha'), ('p1',2,'beta','Beta'), ('p1',3,'gamma','Gamma');"
}

H() { (cd "$P" && HARNESS_AGENT=implementer ANTHROPIC_MODEL= bash scripts/harness.sh "$@") 2>&1; }
q() { sqlite3 "$P/harness.db" "$1"; }
fdeleted() { q "SELECT IFNULL(deleted_at,'') FROM features WHERE name='$1' ORDER BY id LIMIT 1;"; }
# write_spec <name> — the three files mark-spec-ready requires.
write_spec() {
  mkdir -p "$P/specs/$1"
  printf '# Requirements\n\n- R1: WHEN x THE SYSTEM SHALL y\n' > "$P/specs/$1/requirements.md"
  printf '# Design\n' > "$P/specs/$1/design.md"
  printf '# Tasks\n\n- T1: do it (R1)\n' > "$P/specs/$1/tasks.md"
}
# spec_to_ready <name> — add an sdd feature and drive its spec to spec_ready.
spec_to_ready() {
  H add-feature --name "$1" --title "Feature $1" --sdd >/dev/null || die "add-feature --sdd $1"
  H claim-spec "$1" >/dev/null || die "claim-spec $1: $(H claim-spec "$1")"
  write_spec "$1"
  H mark-spec-ready >/dev/null || die "mark-spec-ready $1: $(H mark-spec-ready)"
}

echo "1. nonexistent target fails and changes nothing"
P="$WORK/p1"; new_project "$P"
before=$(q "SELECT group_concat(name || ':' || IFNULL(deleted_at,'-')) FROM features;")
out=$(H delete-feature nosuch) && die "delete of an unknown name should fail: $out"
grep -q "no active feature matches" <<<"$out" || die "unexpected message: $out"
out=$(H delete-feature 99) && die "delete of an unknown number should fail: $out"
[ "$(q "SELECT group_concat(name || ':' || IFNULL(deleted_at,'-')) FROM features;")" = "$before" ] \
  || die "features changed after a failed delete"
pass "unknown name/number fails with 'no active feature matches' and touches nothing"
H delete-feature gamma >/dev/null || die "delete gamma"
out=$(H delete-feature gamma) && die "deleting an already-deleted feature should fail: $out"
pass "an already-deleted feature no longer matches"

echo "2. open in_progress session refuses the delete"
P="$WORK/p2"; new_project "$P"
H claim alpha >/dev/null || die "claim alpha"
sid=$(q "SELECT id FROM session_log WHERE feature_id=1;")
out=$(H delete-feature alpha) && die "delete of a feature with an open session should fail: $out"
grep -q "still has open session $sid" <<<"$out" || die "message should name the session: $out"
grep -q "cancel-session --force $sid" <<<"$out" || die "message should point at cancel-session --force: $out"
[ -z "$(fdeleted alpha)" ] || die "alpha was deleted despite the refusal"
[ "$(q "SELECT status FROM features WHERE name='alpha';")" = in_progress ] || die "alpha status changed"
[ "$(q "SELECT IFNULL(closed_at,'') || IFNULL(deleted_at,'') FROM session_log WHERE id=$sid;")" = "" ] \
  || die "session $sid was closed/deleted"
pass "refused with the session id; feature and session untouched"
out=$(H delete-feature 1) && die "delete by number should be refused too: $out"
pass "refused by number as well"

echo "3. blocked feature (paused session) refuses the delete"
H block alpha "waiting" >/dev/null || die "block alpha"
[ -n "$(q "SELECT paused_at FROM session_log WHERE id=$sid;")" ] || die "session not paused"
out=$(H delete-feature alpha) && die "delete of a blocked feature should fail: $out"
grep -q "still has open session $sid" <<<"$out" || die "message should name the paused session: $out"
[ -z "$(fdeleted alpha)" ] || die "blocked alpha was deleted"
[ "$(q "SELECT status FROM features WHERE name='alpha';")" = blocked ] || die "alpha should still be blocked"
pass "paused session also blocks the delete"

echo "4. cancel-session --force, then delete succeeds"
H cancel-session --force "$sid" "dropping alpha" >/dev/null || die "cancel-session"
H delete-feature alpha >/dev/null || die "delete after cancel: $(H delete-feature alpha)"
[ -n "$(fdeleted alpha)" ] || die "alpha not soft-deleted"
[ -z "$(fdeleted beta)" ] || die "beta must not be touched"
pass "delete succeeds once the session is cancelled"

echo "5. delete soft-deletes the feature's spec with the same timestamp"
P="$WORK/p5"; new_project "$P"
spec_to_ready delta
spec_to_ready eps
did=$(q "SELECT id FROM features WHERE name='delta';")
eid=$(q "SELECT id FROM features WHERE name='eps';")
[ "$(q "SELECT status FROM features WHERE id=$did;")" = spec_ready ] || die "delta should be spec_ready"
[ "$(q "SELECT count(*) FROM specs WHERE feature_id=$did AND deleted_at IS NULL;")" = 1 ] || die "delta has no active spec"
H delete-feature delta >/dev/null || die "delete delta: $(H delete-feature delta)"
f_del=$(q "SELECT deleted_at FROM features WHERE id=$did;")
s_del=$(q "SELECT deleted_at FROM specs WHERE feature_id=$did;")
[ -n "$f_del" ] || die "delta not soft-deleted"
[ "$f_del" = "$s_del" ] || die "spec deleted_at ($s_del) != feature deleted_at ($f_del)"
pass "feature and spec share deleted_at"
[ "$(q "SELECT IFNULL(deleted_at,'') || status FROM specs WHERE feature_id=$eid;")" = ready ] \
  || die "eps's spec was touched: $(q "SELECT * FROM specs WHERE feature_id=$eid;")"
[ -z "$(q "SELECT deleted_at FROM features WHERE id=$eid;")" ] || die "eps feature was touched"
pass "another feature's spec is untouched"

echo "6. reusing the deleted name"
H add-feature --name delta --title "Delta again" --sdd >/dev/null || die "add-feature reusing 'delta': $(H add-feature --name delta --title x --sdd)"
nid=$(q "SELECT id FROM features WHERE name='delta' AND deleted_at IS NULL;")
[ -n "$nid" ] && [ "$nid" != "$did" ] || die "no new active delta feature"
pass "add-feature accepts the deleted feature's name"
H claim-spec delta >/dev/null || die "claim-spec new delta: $(H claim-spec delta)"
H mark-spec-ready >/dev/null || die "mark-spec-ready new delta: $(H mark-spec-ready)"
[ "$(q "SELECT count(*) FROM specs WHERE feature_id=$nid AND deleted_at IS NULL AND status='ready';")" = 1 ] \
  || die "new delta has no active ready spec"
[ "$(q "SELECT deleted_at FROM specs WHERE feature_id=$did;")" = "$s_del" ] || die "old spec row changed"
[ "$(q "SELECT count(*) FROM specs WHERE path='specs/delta' AND deleted_at IS NULL;")" = 1 ] \
  || die "expected exactly one active spec on specs/delta"
pass "new feature gets its own spec; the deleted one stays deleted"

echo "all $PASS checks passed"
