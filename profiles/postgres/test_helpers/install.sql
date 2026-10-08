-- install.sql — installs the 6 generic PL/pgSQL test helpers into schema
-- harness_test_helpers of the current database. Idempotent: every object
-- is CREATE OR REPLACE / IF NOT EXISTS.
--
-- This file is the single entry point used by install.sh. It is never
-- committed to a project's database/ or diffs/ folder — production never
-- sees the harness_test_helpers schema, only the project's dev/test DB.

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS harness_test_helpers;
GRANT USAGE ON SCHEMA harness_test_helpers TO PUBLIC;

-- \ir resolves paths relative to this file, so the includes work
-- regardless of the caller's cwd (init.sh runs from the project root,
-- where 'functions/' does not exist) and of spaces in the path.
\ir functions/test_drop_isolated_tenant.sql
\ir functions/test_create_isolated_tenant.sql
\ir functions/test_make_minimal_row.sql
\ir functions/test_insert_row.sql
\ir functions/test_seed_dictionary_entries.sql
\ir functions/test_assert_field_equals.sql

-- Grant EXECUTE to PUBLIC on every function we just created. We resolve
-- them dynamically (rather than hard-coding names) so adding a new
-- function to functions/ does not require touching this file.
DO $helpers_grant$
DECLARE
    fn record;
BEGIN
    FOR fn IN
        SELECT p.oid, n.nspname, p.proname,
               pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'harness_test_helpers'
    LOOP
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION %I.%I(%s) TO PUBLIC',
            fn.nspname, fn.proname, fn.args
        );
    END LOOP;
END
$helpers_grant$;