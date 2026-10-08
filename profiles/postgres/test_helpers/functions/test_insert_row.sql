-- test_insert_row.sql
--
-- Single-row INSERT driven by a JSONB payload. The function introspects
-- the destination table, builds a row-type matching the columns present
-- in `p_payload`, and uses jsonb_to_recordset to bind the JSON keys to
-- the row type — so we never hand-roll a parser for JSON-to-SQL casts.
-- Array columns take JSON arrays (["a","b"]); json/jsonb columns take
-- any JSON value.
--
-- Columns omitted from `p_payload` keep the table's DEFAULT. JSON nulls
-- become SQL NULLs (so a NOT-NULL column with no DEFAULT will reject
-- the row, as expected).
--
-- Returns the new id when the table has a single bigint column named
-- `id` (the conventional PK in this profile). For tables without an
-- `id` column, returns 1 — a sentinel meaning "no id to return",
-- callers should use RETURNING in their own INSERT for those tables.

CREATE OR REPLACE FUNCTION harness_test_helpers.test_insert_row(
    p_schema text,
    p_table text,
    p_payload jsonb
) RETURNS bigint
LANGUAGE plpgsql
AS $func$
DECLARE
    col record;
    v_col_list text := '';
    v_row_def  text := '';
    v_sql text;
    v_uses_id boolean := false;
    v_returning_clause text := 'RETURNING 1::bigint';
    v_new_id bigint;
    v_row_type_expr text;
BEGIN
    -- Verify the table exists. The whole point of this function is to
    -- drive dynamic INSERTs safely, and a typo in p_table shouldn't
    -- turn into a vague parser error further down.
    IF NOT EXISTS (
        SELECT 1 FROM pg_namespace n
        JOIN pg_class c ON c.relnamespace = n.oid
        WHERE n.nspname = p_schema AND c.relname = p_table AND c.relkind = 'r'
    ) THEN
        RAISE EXCEPTION 'test_insert_row: %.% is not a regular table', p_schema, p_table;
    END IF;

    -- Walk the columns the caller actually populated in p_payload, in
    -- ordinal order. If the caller leaves a key out, the table's
    -- DEFAULT (or NULL) is used — we don't synthesize NULL defaults
    -- here. That's why callers usually pair this with test_make_minimal_row.
    FOR col IN
        SELECT a.attname AS column_name, a.atttypid, a.atttypmod
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = p_schema
          AND c.relname = p_table
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND a.attname = ANY (SELECT jsonb_object_keys(p_payload))
        ORDER BY a.attnum
    LOOP
        v_col_list := v_col_list || quote_ident(col.column_name) || ', ';

        -- format_type() prints the exact declared type (varchar(N),
        -- numeric(p,s), arrays, ...) and schema-qualifies it whenever it
        -- is not visible on the current search_path. That keeps enums
        -- working when the table is a tenant copy whose enum type still
        -- lives in the source schema. The column definition is
        -- evaluated under this same search_path, so the printed name
        -- always resolves to the same type.
        v_row_type_expr := format_type(col.atttypid, col.atttypmod);

        v_row_def := v_row_def
            || quote_ident(col.column_name) || ' ' || v_row_type_expr || ', ';
    END LOOP;

    -- Trim trailing ", " from both lists.
    v_col_list := rtrim(v_col_list, ', ');
    v_row_def  := rtrim(v_row_def, ', ');

    -- If nothing matched, the payload is empty — refuse rather than
    -- silently inserting a row of all defaults.
    IF v_col_list = '' THEN
        RAISE EXCEPTION 'test_insert_row: p_payload has no columns matching %.%', p_schema, p_table;
    END IF;

    -- Decide what to put in RETURNING. If the table has a column named
    -- 'id' of any integer flavour, return it. Otherwise, return 1 as
    -- a sentinel — callers that need a real PK must use RETURNING in
    -- their own INSERT.
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = p_schema AND table_name = p_table
          AND column_name = 'id'
          AND data_type IN ('bigint','integer','smallint')
    ) INTO v_uses_id;
    IF v_uses_id THEN
        v_returning_clause := 'RETURNING id';
    END IF;

    v_sql := format(
        'INSERT INTO %I.%I (%s)
         SELECT %s
         FROM jsonb_to_recordset($1) AS x(%s)
         %s',
        p_schema, p_table, v_col_list, v_col_list, v_row_def, v_returning_clause
    );

    EXECUTE v_sql USING jsonb_build_array(p_payload) INTO v_new_id;
    RETURN v_new_id;
END
$func$;