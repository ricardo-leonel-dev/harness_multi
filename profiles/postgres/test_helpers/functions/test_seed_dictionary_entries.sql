-- test_seed_dictionary_entries.sql
--
-- Inserts (or refreshes) a list of dictionary entries into the named
-- table inside a tenant schema. The function is generic over schema and
-- table name — it expects the destination table to expose at least
-- (code text, category text, is_active smallint/bool, label text), and
-- to have a UNIQUE or PRIMARY KEY constraint whose columns are a
-- superset of (code, category) so ON CONFLICT can resolve duplicates.
--
-- Projects whose dictionary uses a different uniqueness rule (single
-- column, composite of three, no key) should write a per-table Tier 2
-- helper. We do not silently degrade to ON CONFLICT DO NOTHING on the
-- PK column, because that would defeat the "refresh existing entries"
-- purpose of this function.

CREATE OR REPLACE FUNCTION harness_test_helpers.test_seed_dictionary_entries(
    p_schema text,
    p_table text DEFAULT 'dictionary_entries',
    p_entries jsonb DEFAULT '[]'::jsonb
) RETURNS void
LANGUAGE plpgsql
AS $func$
DECLARE
    entry record;
    v_target_ok boolean;
    v_target_cols text[];
BEGIN
    -- Pre-flight that the destination table exists, has a usable
    -- uniqueness target, and exposes the four columns we need.
    IF NOT EXISTS (
        SELECT 1 FROM pg_namespace n
        JOIN pg_class c ON c.relnamespace = n.oid
        WHERE n.nspname = p_schema AND c.relname = p_table AND c.relkind = 'r'
    ) THEN
        RAISE EXCEPTION 'test_seed_dictionary_entries: %.% is not a regular table',
            p_schema, p_table;
    END IF;

    -- Look for a UNIQUE or PRIMARY KEY constraint whose key columns are
    -- a prefix-subset of (code, category) — that's the conflict target
    -- ON CONFLICT needs to know about. We accept supersets too (so a
    -- UNIQUE on (code, category, language_code) still works), but we
    -- reject disjoint ones (a PK on id alone, say).
    SELECT con.conkey::int[] INTO v_target_cols
    FROM pg_constraint con
    WHERE con.conrelid = (p_schema || '.' || p_table)::regclass
      AND con.contype IN ('u', 'p')
      AND (
          -- (code, category) both appear in the constraint key in order.
          SELECT bool_and(c.column_name IN ('code','category'))
          FROM information_schema.columns c
          WHERE c.table_schema = p_schema
            AND c.table_name = p_table
            AND c.ordinal_position = ANY (con.conkey::int[])
      )
    ORDER BY array_length(con.conkey::int[], 1) ASC
    LIMIT 1;

    v_target_ok := v_target_cols IS NOT NULL;

    IF NOT v_target_ok THEN
        RAISE EXCEPTION 'test_seed_dictionary_entries: %.% needs a UNIQUE or PRIMARY KEY constraint that covers (code, category) so ON CONFLICT can refresh existing rows. Otherwise the function would silently duplicate entries on every call.',
            p_schema, p_table;
    END IF;

    FOR entry IN
        SELECT e.value
        FROM jsonb_array_elements(p_entries) AS e(value)
    LOOP
        EXECUTE format(
            'INSERT INTO %I.%I (code, category, is_active, label)
             VALUES ($1, $2, $3, $4)
             ON CONFLICT (code, category) DO UPDATE
                SET is_active = EXCLUDED.is_active,
                    label     = EXCLUDED.label',
            p_schema, p_table
        ) USING
            entry.value->>'code',
            entry.value->>'category',
            COALESCE((entry.value->>'is_active')::smallint, 1),
            entry.value->>'label';
    END LOOP;
END
$func$;