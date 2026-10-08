-- test_assert_field_equals.sql
--
-- Asserts that a specific column of a specific row equals a JSON value.
-- The function uses dynamic SQL with safe identifier quoting so it
-- works on any table/schema. On mismatch it RAISE EXCEPTIONs with a
-- useful message naming the row, field, expected and actual values.

CREATE OR REPLACE FUNCTION harness_test_helpers.test_assert_field_equals(
    p_schema text,
    p_table text,
    p_id bigint,
    p_field text,
    p_expected jsonb
) RETURNS void
LANGUAGE plpgsql
AS $func$
DECLARE
    v_actual jsonb;
    v_exists boolean;
BEGIN
    -- Existence check first so the error message is meaningful when
    -- the row is missing rather than misleading ("expected X got NULL").
    EXECUTE format(
        'SELECT EXISTS (SELECT 1 FROM %I.%I WHERE id = $1)',
        p_schema, p_table
    ) INTO v_exists USING p_id;
    IF NOT v_exists THEN
        RAISE EXCEPTION 'test_assert_field_equals: %.% has no row with id=%',
            p_schema, p_table, p_id;
    END IF;

    -- Pull the field as JSONB so callers can compare structured values
    -- without having to pick the right cast for each column type.
    EXECUTE format(
        'SELECT to_jsonb(%I) FROM %I.%I WHERE id = $1',
        p_field, p_schema, p_table
    ) INTO v_actual USING p_id;

    IF v_actual IS DISTINCT FROM p_expected THEN
        RAISE EXCEPTION 'test_assert_field_equals: %.%.id=% field % expected %, got %',
            p_schema, p_table, p_id, p_field, p_expected, v_actual;
    END IF;
END
$func$;