-- test_insert_row.sql
--
-- Single-row INSERT driven by a JSONB payload. The function introspects
-- the destination table, builds a row-type matching the columns present
-- in `p_payload`, and uses jsonb_to_recordset to bind the JSON keys to
-- the row type — so we never hand-roll a parser for JSON-to-SQL casts.
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
        SELECT c.column_name, c.data_type, c.udt_name,
               c.character_maximum_length, c.numeric_precision, c.numeric_scale,
               c.ordinal_position
        FROM information_schema.columns c
        WHERE c.table_schema = p_schema
          AND c.table_name   = p_table
          AND c.column_name = ANY (SELECT jsonb_object_keys(p_payload))
        ORDER BY c.ordinal_position
    LOOP
        v_col_list := v_col_list || quote_ident(col.column_name) || ', ';

        -- Map information_schema types to PostgreSQL cast expressions
        -- that jsonb_to_recordset will accept. Most are 1:1; the cases
        -- we have to handle are: array udt_name (which has a leading
        -- underscore like '_text'), varchar length annotation, and
        -- timestamp-with-time-zone abbreviation.
        v_row_type_expr := CASE
            WHEN col.data_type = 'ARRAY' THEN
                -- udt_name for arrays is '_int4', '_text', etc.
                -- Strip the leading underscore and append '[]'.
                regexp_replace(col.udt_name, '^_(.+)$', '\1[]')
            WHEN col.data_type = 'character varying' AND col.character_maximum_length IS NOT NULL THEN
                format('varchar(%s)', col.character_maximum_length)
            WHEN col.data_type = 'character' AND col.character_maximum_length IS NOT NULL THEN
                format('char(%s)', col.character_maximum_length)
            WHEN col.data_type = 'numeric' AND col.numeric_precision IS NOT NULL
                 AND col.numeric_scale IS NOT NULL THEN
                format('numeric(%s,%s)', col.numeric_precision, col.numeric_scale)
            WHEN col.data_type = 'numeric' AND col.numeric_precision IS NOT NULL THEN
                format('numeric(%s)', col.numeric_precision)
            WHEN col.data_type = 'timestamp with time zone'    THEN 'timestamptz'
            WHEN col.data_type = 'timestamp without time zone' THEN 'timestamp'
            WHEN col.data_type = 'time with time zone'         THEN 'timetz'
            WHEN col.data_type = 'time without time zone'      THEN 'time'
            WHEN col.data_type IN ('integer','bigint','smallint','numeric','real',
                                   'double precision','text','boolean','date',
                                   'jsonb','json','uuid','bytea','interval','money',
                                   'xml','inet','cidr','macaddr','macaddr8')
                THEN col.data_type
            WHEN col.data_type = 'USER-DEFINED' OR col.data_type LIKE 'character%'
                THEN col.udt_name
            ELSE col.data_type
        END;

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