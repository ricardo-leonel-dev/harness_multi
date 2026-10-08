-- test_make_minimal_row.sql
--
-- Introspects a table's NOT-NULL columns (those without a DEFAULT), and
-- returns a JSONB object with a stub value for each. The caller can merge
-- real values into `p_extras` to override any default.
--
-- LIMITATION (documented for honesty, not as a hidden trap): for tables
-- whose NOT-NULL columns are validated by triggers (e.g. an ENUM
-- check), the stub values this function emits will *fail* the trigger on
-- INSERT. That is expected — the caller is expected to override those
-- fields via `p_extras` with values that pass the trigger, or to use a
-- per-table Tier 2 helper that knows the trigger's contract. We do not
-- silently try to make the stub values pass arbitrary triggers, because
-- that requires knowing the project's domain.

CREATE OR REPLACE FUNCTION harness_test_helpers.test_make_minimal_row(
    p_schema text,
    p_table text,
    p_extras jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $func$
DECLARE
    col record;
    v_payload jsonb := '{}'::jsonb;
    v_value jsonb;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_namespace n
        JOIN pg_class c ON c.relnamespace = n.oid
        WHERE n.nspname = p_schema AND c.relname = p_table AND c.relkind = 'r'
    ) THEN
        RAISE EXCEPTION 'test_make_minimal_row: %.% is not a regular table', p_schema, p_table;
    END IF;

    FOR col IN
        SELECT column_name, data_type, udt_schema, udt_name, character_maximum_length
        FROM information_schema.columns
        WHERE table_schema = p_schema
          AND table_name   = p_table
          AND is_nullable  = 'NO'
          AND column_default IS NULL
          AND is_identity  = 'NO'
          AND is_generated = 'NEVER'
        ORDER BY ordinal_position
    LOOP
        -- Every branch yields a typed jsonb value (not a JSON string), so
        -- test_insert_row's jsonb_to_recordset receives a real JSON array
        -- for array columns and a real object for json/jsonb columns.
        v_value := CASE
            -- Arrays always default to an empty JSON array.
            WHEN col.data_type = 'ARRAY' THEN '[]'::jsonb

            -- JSON columns default to a JSON object so callers can
            -- chain key updates without juggling NULL vs '{}'.
            WHEN col.udt_name IN ('jsonb', 'json') THEN '{}'::jsonb

            -- Enums: the first label in sort order. The type is looked
            -- up in udt_schema — a tenant copy's enum column still uses
            -- the type from the source schema. Other USER-DEFINED types
            -- (composite, range) fall back to NULL — extras must provide.
            WHEN col.data_type = 'USER-DEFINED' THEN (
                SELECT to_jsonb(e.enumlabel::text)
                FROM pg_type ty
                JOIN pg_namespace tn ON tn.oid = ty.typnamespace
                JOIN pg_enum e ON e.enumtypid = ty.oid
                WHERE tn.nspname = col.udt_schema AND ty.typname = col.udt_name
                ORDER BY e.enumsortorder
                LIMIT 1
            )

            -- Timestamps: epoch. With and without time zone both parse.
            WHEN col.data_type = 'timestamp with time zone'
                THEN to_jsonb('1970-01-01 00:00:00+00'::text)
            WHEN col.data_type LIKE 'timestamp%'
                THEN to_jsonb('1970-01-01 00:00:00'::text)

            WHEN col.data_type = 'time with time zone'    THEN to_jsonb('00:00:00+00'::text)
            WHEN col.data_type = 'time without time zone' THEN to_jsonb('00:00:00'::text)

            -- Booleans default to false — many tables use a flag
            -- column to mean "active" or "deleted", and false is
            -- the safer default than true.
            WHEN col.data_type = 'boolean' THEN 'false'::jsonb

            -- Numeric family — 0.
            WHEN col.data_type IN ('integer','smallint','bigint',
                                   'numeric','real','double precision') THEN '0'::jsonb

            -- String types — sentinel value that signals "this is a
            -- stub"; tests override via extras in practice. Truncated
            -- to the column length so char(2)/varchar(5) columns accept it.
            WHEN col.data_type IN (
                'text','character varying','character','name','citext'
            ) THEN to_jsonb(left('test_value', coalesce(col.character_maximum_length, 10)))

            WHEN col.data_type = 'date' THEN to_jsonb('1970-01-01'::text)

            -- UUIDs: fresh per call so a row inserted twice doesn't
            -- collide on PK uniqueness (when the column is the PK).
            WHEN col.udt_name = 'uuid' THEN to_jsonb(gen_random_uuid()::text)

            -- Default case: unknown / exotic type, leave NULL.
            ELSE 'null'::jsonb
        END;
        v_value := coalesce(v_value, 'null'::jsonb);

        v_payload := v_payload || jsonb_build_object(col.column_name, v_value);
    END LOOP;

    RETURN v_payload || p_extras;
END
$func$;