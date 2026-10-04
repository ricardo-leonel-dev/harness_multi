#!/usr/bin/env bash
# session_resume_test.sh — end-to-end check of the paused-session / resume
# lifecycle in scripts/harness.sh, run against a throwaway project in a temp dir.
#
#   1. block pauses the feature's session and frees the slot for other work;
#      unblock resumes the SAME session (review verdict kept) and log-out works.
#   2. block -> cancel-session --force -> unblock refuses (no session to
#      resume) -> explicit claim opens a new session logging RESUMED with the
#      cancelled id -> record-review -> log-out works.
#   3. an in_progress feature whose session was cancelled is resumable too.
#   4. lib.sh's migration pauses the open session of an already-blocked
#      feature in a harness.db created before paused_at existed.
#
# Usage: bash tests/session_resume_test.sh   (exits non-zero on the first failure)

set -u
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
die() { echo "  FAIL $1" >&2; exit 1; }

# new_project <dir> [schema_file] — minimal installed project: scripts, config, db, 3 features.
new_project() {
  local dir="$1" schema="${2:-$TOOLKIT_DIR/db/schema.sqlite.sql}"
  mkdir -p "$dir/scripts"
  cp "$TOOLKIT_DIR"/scripts/*.sh "$dir/scripts/"
  echo '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state"}' > "$dir/.harness.json"
  sqlite3 "$dir/harness.db" < "$schema"
  sqlite3 "$dir/harness.db" "INSERT INTO projects (id, slug) VALUES ('p1','t');
INSERT INTO features (project_id, feature_number, name, title) VALUES
  ('p1',1,'alpha','Alpha'), ('p1',2,'beta','Beta'), ('p1',3,'gamma','Gamma');"
}

H() { (cd "$P" && HARNESS_AGENT=implementer ANTHROPIC_MODEL= bash scripts/harness.sh "$@") 2>&1; }
q() { sqlite3 "$P/harness.db" "$1"; }
fstatus() { q "SELECT status FROM features WHERE name='$1';"; }
approve_and_log_out() {
  H record-review approved --by human:tester >/dev/null || die "record-review on $1"
  H log-out --changes x --verification v --closure c >/dev/null || die "log-out on $1: $(H status)"
  [ "$(fstatus "$1")" = done ] || die "$1 should be done after log-out"
}

echo "1. block pauses, unblock resumes the same session"
P="$WORK/p1"; new_project "$P"
H claim alpha >/dev/null || die "claim alpha"
s_alpha=$(q "SELECT id FROM session_log WHERE feature_id=1;")
H record-review approved --by human:tester >/dev/null || die "record-review alpha"
H block alpha "waiting on beta" >/dev/null || die "block alpha"
[ -n "$(q "SELECT paused_at FROM session_log WHERE id=$s_alpha;")" ] || die "session not paused"
pass "block pauses the session"
H claim beta >/dev/null || die "claim beta while alpha is blocked: $(H claim beta)"
pass "another feature is claimable while one is blocked"
out=$(H unblock alpha) && die "unblock should refuse while beta's session is active"
pass "unblock refuses while another session is active"
approve_and_log_out beta
H unblock alpha >/dev/null || die "unblock alpha: $(H unblock alpha)"
[ "$(q "SELECT count(*) FROM session_log WHERE feature_id=1;")" = 1 ] || die "unblock opened a new session"
[ "$(q "SELECT review_status FROM session_log WHERE id=$s_alpha;")" = approved ] || die "review verdict lost"
pass "unblock resumes the same session with its review verdict"
H log-out --changes x --verification v --closure c >/dev/null || die "log-out alpha after unblock"
pass "log-out works after unblock"

echo "2. block -> cancel-session --force -> claim resumes"
P="$WORK/p2"; new_project "$P"
H claim alpha >/dev/null || die "claim alpha"
s_old=$(q "SELECT id FROM session_log WHERE feature_id=1;")
H block alpha "stuck" >/dev/null || die "block alpha"
H cancel-session --force "$s_old" "freeing slot" >/dev/null || die "cancel-session"
out=$(H unblock alpha) && die "unblock should refuse a feature with no session"
grep -q "claim alpha" <<<"$out" || die "unblock message should point at claim: $out"
[ "$(fstatus alpha)" = blocked ] || die "failed unblock must leave the feature blocked"
pass "unblock refuses (and points at claim) when there is no session"
H claim alpha >/dev/null || die "explicit claim of blocked alpha: $(H claim alpha)"
s_new=$(q "SELECT id FROM session_log WHERE feature_id=1 AND closed_at IS NULL AND deleted_at IS NULL;")
[ -n "$s_new" ] && [ "$s_new" != "$s_old" ] || die "no new session opened"
[ "$(fstatus alpha)" = in_progress ] || die "alpha should be in_progress"
q "SELECT entry FROM session_log_entries WHERE session_id=$s_new;" | grep -q "RESUMED: previous session $s_old was cancelled (CANCELLED: freeing slot)" \
  || die "RESUMED entry missing: $(q "SELECT entry FROM session_log_entries WHERE session_id=$s_new;")"
pass "explicit claim opens a new session and logs RESUMED with the cancelled id"
out=$(H claim alpha) && die "a second claim must not stack another session"
pass "claim refuses a feature that already has an open session"
out=$(H log-out --changes x --verification v --closure c) && die "log-out must still require a review on the new session"
approve_and_log_out alpha
pass "record-review + log-out work on the resumed session"

echo "3. in_progress feature without a session"
P="$WORK/p3"; new_project "$P"
H claim gamma >/dev/null || die "claim gamma"
H cancel-session --force "$(q "SELECT id FROM session_log WHERE feature_id=3;")" "oops" >/dev/null || die "cancel"
[ "$(fstatus gamma)" = in_progress ] || die "gamma should still be in_progress"
H claim 3 >/dev/null || die "explicit claim by number of sessionless in_progress gamma"
approve_and_log_out gamma
pass "claim <number> resumes an in_progress feature and it can be logged out"

echo "4. migration pauses sessions of already-blocked features"
P="$WORK/p4"
legacy="$WORK/legacy_schema.sql"
sed -e 's/  paused_at TEXT,.*//' -e 's/ AND paused_at IS NULL//' "$TOOLKIT_DIR/db/schema.sqlite.sql" > "$legacy"
grep -q paused_at "$legacy" && die "legacy schema still mentions paused_at"
new_project "$P" "$legacy"
q "UPDATE features SET status='blocked' WHERE name='alpha';
INSERT INTO session_log (project_id, feature_id, agent) VALUES ('p1', 1, 'x');"
H status >/dev/null  # sourcing lib.sh runs the migration
[ -n "$(q "SELECT paused_at FROM session_log WHERE feature_id=1;")" ] || die "migration didn't pause the blocked feature's session"
H claim beta >/dev/null || die "claim beta after migration: $(H claim beta)"
pass "legacy blocked session is paused and the slot is free"

echo "all $PASS checks passed"
