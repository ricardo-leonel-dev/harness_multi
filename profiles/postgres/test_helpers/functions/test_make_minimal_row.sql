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
    v_enum_label text;
    v_type_kind char;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_namespace n
        JOIN pg_class c ON c.relnamespace = n.oid
        WHERE n.nspname = p_schema AND c.relname = p_table AND c.relkind = 'r'
    ) THEN
        RAISE EXCEPTION 'test_make_minimal_row: %.% is not a regular table', p_schema, p_table;
    END IF;

    FOR col IN
        SELECT column_name, data_type, udt_name, character_maximum_length
        FROM information_schema.columns
        WHERE table_schema = p_schema
          AND table_name   = p_table
          AND is_nullable  = 'NO'
          AND column_default IS NULL
        ORDER BY ordinal_position
    LOOP
        -- We use a string-based CASE and then to_jsonb() the result so
        -- every branch has type text — that keeps PostgreSQL happy when
        -- it tries to pick a common type for the CASE expression. (Doing
        -- the same with mixed jsonb/int/text branches trips the "could
        -- not determine polymorphic type" error.)
        v_value := to_jsonb(
            CASE
                -- Arrays always default to an empty JSON array.
                WHEN col.data_type = 'ARRAY' THEN '[]'

                -- JSON columns default to a JSON object so callers can
                -- chain key updates without juggling NULL vs '{}'.
                WHEN col.udt_name IN ('jsonb', 'json') THEN '{}'

                -- Enums and other USER-DEFINED types: resolved below
                -- the CASE expression. For non-enum UDTs (composite,
                -- range, domain), we fall back to NULL — extras must
                -- provide.
                WHEN col.data_type = 'USER-DEFINED' THEN NULL

                -- Timestamps: epoch. With and without time zone both parse.
                WHEN col.data_type = 'timestamp with time zone'
                    THEN '1970-01-01 00:00:00+00'
                WHEN col.data_type LIKE 'timestamp%'
                    THEN '1970-01-01 00:00:00'

                WHEN col.data_type = 'time with time zone'    THEN '00:00:00+00'
                WHEN col.data_type = 'time without time zone' THEN '00:00:00'

                -- Booleans default to false — many tables use a flag
                -- column to mean "active" or "deleted", and false is
                -- the safer default than true.
                WHEN col.data_type = 'boolean' THEN 'false'

                -- Numeric family — 0.
                WHEN col.data_type IN ('integer','smallint','bigint') THEN '0'
                WHEN col.data_type IN ('numeric','real','double precision') THEN '0'

                -- String types — sentinel value that signals "this is a
                -- stub"; tests can grep for it if they want to assert
                -- against it, but in practice tests override via extras.
                WHEN col.data_type IN (
                    'text','character varying','character','name','citext'
                ) THEN 'test_value'

                WHEN col.data_type = 'date' THEN '1970-01-01'

                -- UUIDs: fresh per call so a row inserted twice doesn't
                -- collide on PK uniqueness (when the column is the PK).
                WHEN col.udt_name = 'uuid' THEN gen_random_uuid()::text

                -- Default case: unknown / exotic type, leave NULL.
                ELSE NULL
            END
        );

        -- USER-DEFINED enum resolution is special-cased because the
        -- CASE expression above can't issue a SELECT. We do it here.
        IF col.data_type = 'USER-DEFINED' THEN
            SELECT t.typtype INTO v_type_kind
            FROM pg_type t
            WHERE t.oid = (p_schema || '.' || col.udt_name)::regtype;
            IF v_type_kind = 'e' THEN
                SELECT enumlabel INTO v_enum_label
                FROM pg_enum
                WHERE enumtypid = (p_schema || '.' || col.udt_name)::regtype
                ORDER BY enumsortorder
                LIMIT 1;
                v_value := to_jsonb(v_enum_label);
            ELSE
                v_value := to_jsonb(NULL);
            END IF;
        END IF;

        v_payload := v_payload || jsonb_build_object(col.column_name, v_value);
    END LOOP;

    RETURN v_payload || p_extras;
END
$func$;