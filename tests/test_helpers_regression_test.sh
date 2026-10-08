#!/usr/bin/env bash
# Regression for profiles/postgres/test_helpers. The shell part needs no
# database. The SQL part runs only when HARNESS_TEST_PG_DSN is set (a libpq
# conninfo/URL for a dev database): everything, including installing the
# working-copy helpers, happens inside one transaction that is rolled back,
# so the target database is left untouched.
set -eu
TOOLKIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS="$TOOLKIT/profiles/postgres/test_helpers"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass() { printf '  ok %s\n' "$1"; }

# uninstall.sh must resolve the same database as install.sh, including the
# verify_command that connects to `postgres` to check that the real db exists.
P="$WORK/project"; mkdir -p "$P/harness/test_helpers"
cat > "$P/.harness.json" <<'JSON'
{"verify_command": "PGPASSWORD=s3cret psql -h dbhost -p 5439 -U app -d postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='web-display';\" | grep -q 1"}
JSON
resolved() {
  env -u PGHOST -u PGPORT -u PGUSER -u PGDATABASE -u PGPASSWORD -u PG_PASSWORD \
      -u PSQL_HOST -u PSQL_PORT -u PSQL_USER -u PSQL_DB \
      bash -c '. "$1/lib_conn.sh"; SCRIPT_DIR="$2"; resolve_psql_conn; echo "$PSQL_HOST $PSQL_PORT $PSQL_USER $PSQL_DB $PGPASSWORD"' _ "$HELPERS" "$P/harness/test_helpers"
}
[ "$(resolved)" = "dbhost 5439 app web-display s3cret" ]
grep -q '\. "\$SCRIPT_DIR/lib_conn.sh"' "$HELPERS/install.sh"
grep -q '\. "\$SCRIPT_DIR/lib_conn.sh"' "$HELPERS/uninstall.sh"
pass 'install.sh and uninstall.sh share connection resolution (existence-check verify_command -> real db)'

# Tier 2 helpers are project-owned: they must be visible to git after install,
# while the harness-owned bundle stays excluded.
G="$WORK/repo"; mkdir -p "$G"; git -C "$G" init -q
(cd "$G" && bash "$TOOLKIT/install.sh" --slug helpers-test --profile postgres --human-user Tester --verify-command true) > "$WORK/install.log" 2>&1
[ -f "$G/harness/test_helpers/lib_conn.sh" ]
mkdir -p "$G/test_helpers"; printf -- '-- tier 2\n' > "$G/test_helpers/test_make_minimal_x.sql"
git -C "$G" check-ignore -q harness/test_helpers/install.sh
if git -C "$G" check-ignore -q test_helpers/test_make_minimal_x.sql; then echo 'Tier 2 helper is git-ignored' >&2; exit 1; fi
(cd "$G" && PROJECT_DIR="$G" SCRIPT_DIR="$G/harness/test_helpers" bash -c '. harness/test_helpers/lib_conn.sh; resolve_project_specific_dir; echo "$PROJECT_SPECIFIC_DIR"') > "$WORK/dir"
[ "$(cat "$WORK/dir")" = "$G/test_helpers" ]
pass 'Tier 2 directory is outside the git-excluded harness/ bundle and is what install.sh loads'

# The prologue only prepends the helpers schema when it is installed and keeps
# the session's own search_path.
T="$TOOLKIT/profiles/postgres/acceptance_test_prologue.sql"
if grep -q '^SET search_path' "$T"; then echo 'prologue sets search_path unconditionally' >&2; exit 1; fi
grep -q '^\\if :has_test_helpers' "$T"
grep -q "current_setting('search_path')" "$T"
pass 'prologue prepends harness_test_helpers conditionally'

if [ -z "${HARNESS_TEST_PG_DSN:-}" ]; then
  echo '  skip SQL regressions (set HARNESS_TEST_PG_DSN to a dev database to run them)'
  echo 'All test_helpers regressions passed.'
  exit 0
fi
command -v psql >/dev/null 2>&1 || { echo 'psql not found in PATH' >&2; exit 1; }

cat > "$WORK/regression.sql" <<SQL
\set ON_ERROR_STOP on
\set QUIET on
BEGIN;
\i '$HELPERS/install.sql'
SQL
cat >> "$WORK/regression.sql" <<'SQL'
CREATE SCHEMA zz_src;
CREATE TYPE zz_src.st AS ENUM ('a', 'b');
CREATE TABLE zz_src.users (id bigserial PRIMARY KEY, email text NOT NULL, st zz_src.st NOT NULL,
                           tags text[] NOT NULL, meta jsonb NOT NULL, cc char(2) NOT NULL);
CREATE TABLE zz_src.orders (id bigserial PRIMARY KEY, user_id bigint NOT NULL REFERENCES zz_src.users(id));
CREATE TABLE zz_src.dict (id serial, code text, category text, is_active int, label text, UNIQUE (code, category));
INSERT INTO zz_src.dict (code, category, is_active, label) VALUES ('OK', 'c', 1, 'ok');
CREATE FUNCTION zz_src.chk() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM zz_src.dict WHERE code = NEW.email) THEN
        RAISE EXCEPTION 'bad email %', NEW.email;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg BEFORE INSERT ON zz_src.users FOR EACH ROW EXECUTE FUNCTION zz_src.chk();

-- 1 + 2: FKs and triggers are rebound, with the source schema off and on the caller's search_path.
SELECT harness_test_helpers.test_create_isolated_tenant('zz_t1', 'zz_src', ARRAY['users','orders'], 'zz_src.dict');
SET LOCAL search_path TO zz_src, public;
SELECT harness_test_helpers.test_create_isolated_tenant('zz_t2', 'zz_src', ARRAY['users','orders'], 'zz_src.dict');
RESET search_path;
DO $$
DECLARE tenant text;
BEGIN
    FOREACH tenant IN ARRAY ARRAY['zz_t1', 'zz_t2'] LOOP
        IF (SELECT count(*) FROM pg_constraint
            WHERE contype = 'f' AND conrelid = format('%I.orders', tenant)::regclass
              AND confrelid = format('%I.users', tenant)::regclass) <> 1 THEN
            RAISE EXCEPTION '%: FK orders->users not recreated against the tenant', tenant;
        END IF;
        IF (SELECT p.pronamespace::regnamespace::text FROM pg_trigger tg JOIN pg_proc p ON p.oid = tg.tgfoid
            WHERE tg.tgrelid = format('%I.users', tenant)::regclass AND NOT tg.tgisinternal) IS DISTINCT FROM tenant THEN
            RAISE EXCEPTION '%: trigger missing or not bound to the tenant function copy', tenant;
        END IF;
    END LOOP;
END $$;
SELECT 'PASS' AS result, 'fk_and_trigger_rebinding_independent_of_search_path' AS test_case;

-- The rebound trigger reads the tenant dictionary, not the source one.
DELETE FROM zz_src.dict;
SELECT harness_test_helpers.test_insert_row('zz_t1', 'users',
    harness_test_helpers.test_make_minimal_row('zz_t1', 'users', '{"email": "OK"}')) AS t1_id \gset
DO $$
BEGIN
    PERFORM harness_test_helpers.test_insert_row('zz_t1', 'users',
        harness_test_helpers.test_make_minimal_row('zz_t1', 'users', '{"email": "NOPE"}'));
    RAISE EXCEPTION 'tenant trigger accepted a code missing from the tenant dictionary';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'bad email%' THEN RAISE; END IF;
END $$;
SELECT 'PASS' AS result, 'tenant_trigger_uses_tenant_dictionary' AS test_case;

-- 3 + 4: minimal rows are insertable (typed JSON for arrays/jsonb, enum from the source schema, char(2)).
-- DO blocks cannot see psql variables; pass the payload through a GUC.
SELECT set_config('zz.p', harness_test_helpers.test_make_minimal_row('zz_src', 'users', '{"email": "x"}')::text, true);
DO $$
DECLARE p jsonb := current_setting('zz.p')::jsonb;
BEGIN
    IF jsonb_typeof(p->'tags') <> 'array' OR jsonb_typeof(p->'meta') <> 'object'
       OR p->>'st' <> 'a' OR p->>'cc' <> 'te' THEN
        RAISE EXCEPTION 'unexpected minimal row %', p;
    END IF;
END $$;
SELECT harness_test_helpers.test_assert_field_equals('zz_t1', 'users', :t1_id, 'tags', '[]');
SELECT harness_test_helpers.test_assert_field_equals('zz_t1', 'users', :t1_id, 'meta', '{}');
SELECT harness_test_helpers.test_assert_field_equals('zz_t1', 'users', :t1_id, 'st', '"a"');
SELECT 'PASS' AS result, 'minimal_row_round_trips_arrays_jsonb_enums_on_tenant' AS test_case;

-- 5: the default dictionary is optional; an explicit missing one is an error.
ALTER TABLE IF EXISTS public.dictionary_entries RENAME TO zz_hidden_dictionary_entries;
SELECT harness_test_helpers.test_create_isolated_tenant('zz_t3', 'zz_src', ARRAY['orders']);
DO $$
BEGIN
    PERFORM harness_test_helpers.test_create_isolated_tenant('zz_t4', 'zz_src', ARRAY['orders'], 'zz_src.nope');
    RAISE EXCEPTION 'missing explicit dictionary accepted';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%dictionary table zz_src.nope does not exist%' THEN RAISE; END IF;
END $$;
SELECT 'PASS' AS result, 'dictionary_copy_optional_by_default' AS test_case;

-- 8: seed needs a unique index on exactly (code, category) and casts is_active to the column type.
CREATE TABLE zz_src.d_ok (code text, category text, is_active boolean, label text, PRIMARY KEY (category, code));
CREATE TABLE zz_src.d_code (code text UNIQUE, category text, is_active int, label text);
CREATE TABLE zz_src.d_wide (code text, category text, lang text, is_active int, label text, UNIQUE (code, category, lang));
SELECT harness_test_helpers.test_seed_dictionary_entries('zz_src', 'd_ok',
    '[{"code": "A", "category": "c", "label": "a"}, {"code": "B", "category": "c", "is_active": 0, "label": "b"}]');
SELECT harness_test_helpers.test_seed_dictionary_entries('zz_src', 'd_ok',
    '[{"code": "A", "category": "c", "is_active": 0, "label": "a2"}]');
DO $$
DECLARE t text;
BEGIN
    IF (SELECT count(*) FROM zz_src.d_ok) <> 2
       OR (SELECT is_active OR label <> 'a2' FROM zz_src.d_ok WHERE code = 'A') THEN
        RAISE EXCEPTION 'seed did not insert/refresh as expected';
    END IF;
    FOREACH t IN ARRAY ARRAY['d_code', 'd_wide'] LOOP
        BEGIN
            PERFORM harness_test_helpers.test_seed_dictionary_entries('zz_src', t, '[]');
            RAISE EXCEPTION 'seed accepted unusable conflict target on %', t;
        EXCEPTION WHEN raise_exception THEN
            IF SQLERRM NOT LIKE '%exactly (code, category)%' THEN RAISE; END IF;
        END;
    END LOOP;
END $$;
SELECT 'PASS' AS result, 'seed_conflict_target_and_is_active_type' AS test_case;
ROLLBACK;
SQL
psql "$HARNESS_TEST_PG_DSN" -X -q -v ON_ERROR_STOP=1 -f "$WORK/regression.sql" > "$WORK/sql.log" 2>&1 || { cat "$WORK/sql.log" >&2; exit 1; }
for c in fk_and_trigger_rebinding_independent_of_search_path tenant_trigger_uses_tenant_dictionary \
         minimal_row_round_trips_arrays_jsonb_enums_on_tenant dictionary_copy_optional_by_default \
         seed_conflict_target_and_is_active_type; do
  grep -q "PASS *| *$c" "$WORK/sql.log" || { cat "$WORK/sql.log" >&2; echo "missing PASS for $c" >&2; exit 1; }
  pass "$c"
done
echo 'All test_helpers regressions passed.'
