-- Copy into a project-owned test, replace configuration values, and add cases
-- BEFORE the final ROLLBACK. Run with psql -X -v ON_ERROR_STOP=1 -f PATH.
-- No runner-specific wrapper is required. Never COMMIT test fixtures.
\set ON_ERROR_STOP on
-- If the harness_test_helpers schema is installed (test_helpers.enabled in
-- .harness.json), prepend it to the session's existing search_path so the
-- fixtures are callable by short name. Projects without it keep their
-- search_path untouched.
SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'harness_test_helpers')
    AS has_test_helpers \gset
\if :has_test_helpers
SELECT set_config('search_path', 'harness_test_helpers, ' || current_setting('search_path'), false)
    AS test_helpers_search_path \gset
\endif
\set test_schema '<SCHEMA>'
\set test_table '<TABLE>'
\set expect_table 'true'

BEGIN;
-- psql does not interpolate variables inside DO dollar quotes. Pass values
-- through a temporary relation using quoted psql literals outside the block.
CREATE TEMP TABLE acceptance_config (
    schema_name text NOT NULL,
    table_name text NOT NULL,
    expect_table boolean NOT NULL
) ON COMMIT DROP;
INSERT INTO acceptance_config VALUES (:'test_schema', :'test_table', :'expect_table'::boolean);
CREATE TEMP TABLE acceptance_baseline (row_count bigint NOT NULL) ON COMMIT DROP;

DO $$
DECLARE
    cfg record;
    table_exists boolean;
    baseline_count bigint;
BEGIN
    SELECT * INTO STRICT cfg FROM acceptance_config;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = cfg.schema_name) THEN
        RAISE EXCEPTION 'acceptance prerequisite: schema % missing', cfg.schema_name;
    END IF;
    SELECT EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = cfg.schema_name AND c.relname = cfg.table_name
          AND c.relkind IN ('r', 'p')
    ) INTO table_exists;
    IF table_exists IS DISTINCT FROM cfg.expect_table THEN
        RAISE EXCEPTION 'acceptance prerequisite: %.% existence %, expected %',
            cfg.schema_name, cfg.table_name, table_exists, cfg.expect_table;
    END IF;
    -- Guard the baseline before dynamic SQL; identifiers are quoted safely.
    IF table_exists THEN
        EXECUTE format('SELECT count(*) FROM %I.%I', cfg.schema_name, cfg.table_name)
          INTO baseline_count;
        INSERT INTO acceptance_baseline VALUES (baseline_count);
    END IF;
END
$$;
SELECT 'PASS' AS result, 't0_catalog_and_baseline' AS test_case;

-- Add actual assertions here: raise an exception when a condition fails, then
-- emit SELECT 'PASS' AS result, 't1_description_r1_r2' AS test_case.
-- Markers index evidence only. Reviewers must check the assertion and execution.
-- If testing a migration, apply the self-contained migration at the appropriate
-- point inside this transaction (check it for transaction control first).
ROLLBACK;
