-- test_seed_dictionary_entries.sql
--
-- Inserts (or refreshes) a list of dictionary entries into the named
-- table inside a tenant schema. The function is generic over schema and
-- table name — it expects the destination table to expose at least
-- (code, category, is_active, label), and to have a non-partial UNIQUE
-- index (or PRIMARY KEY) on exactly (code, category), in either order.
-- That is what `ON CONFLICT (code, category)` can infer; an index on more
-- columns, e.g. (code, category, language_code), or on (code) alone does
-- not qualify.
--
-- `is_active` is cast to whatever type the column has, so smallint,
-- integer and boolean columns all accept 1/0 (and true/false for
-- boolean). It defaults to 1 when the entry omits it.
--
-- Projects whose dictionary uses a different uniqueness rule should
-- write a per-table Tier 2 helper. We do not silently degrade to
-- ON CONFLICT DO NOTHING on the PK column, because that would defeat the
-- "refresh existing entries" purpose of this function.

CREATE OR REPLACE FUNCTION harness_test_helpers.test_seed_dictionary_entries(
    p_schema text,
    p_table text DEFAULT 'dictionary_entries',
    p_entries jsonb DEFAULT '[]'::jsonb
) RETURNS void
LANGUAGE plpgsql
AS $func$
DECLARE
    entry record;
    v_rel oid;
    v_is_active_type text;
BEGIN
    -- Pre-flight that the destination table exists and has a usable
    -- conflict target.
    SELECT c.oid INTO v_rel
    FROM pg_namespace n
    JOIN pg_class c ON c.relnamespace = n.oid
    WHERE n.nspname = p_schema AND c.relname = p_table AND c.relkind = 'r';
    IF v_rel IS NULL THEN
        RAISE EXCEPTION 'test_seed_dictionary_entries: %.% is not a regular table',
            p_schema, p_table;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_index i
        WHERE i.indrelid = v_rel
          AND i.indisunique
          AND i.indpred IS NULL
          AND i.indexprs IS NULL
          AND (
              SELECT array_agg(a.attname::text ORDER BY a.attname)
              FROM unnest(i.indkey::int2[]) AS k(attnum)
              JOIN pg_attribute a ON a.attrelid = v_rel AND a.attnum = k.attnum
          ) = ARRAY['category', 'code']
    ) THEN
        RAISE EXCEPTION 'test_seed_dictionary_entries: %.% needs a UNIQUE index or PRIMARY KEY on exactly (code, category) so ON CONFLICT can refresh existing rows. Other uniqueness shapes need a Tier 2 helper.',
            p_schema, p_table;
    END IF;

    SELECT format_type(a.atttypid, a.atttypmod) INTO v_is_active_type
    FROM pg_attribute a
    WHERE a.attrelid = v_rel AND a.attname = 'is_active' AND NOT a.attisdropped;
    IF v_is_active_type IS NULL THEN
        RAISE EXCEPTION 'test_seed_dictionary_entries: %.% has no is_active column', p_schema, p_table;
    END IF;

    FOR entry IN
        SELECT e.value
        FROM jsonb_array_elements(p_entries) AS e(value)
    LOOP
        EXECUTE format(
            'INSERT INTO %I.%I (code, category, is_active, label)
             VALUES ($1, $2, $3::%s, $4)
             ON CONFLICT (code, category) DO UPDATE
                SET is_active = EXCLUDED.is_active,
                    label     = EXCLUDED.label',
            p_schema, p_table, v_is_active_type
        ) USING
            entry.value->>'code',
            entry.value->>'category',
            COALESCE(entry.value->>'is_active', '1'),
            entry.value->>'label';
    END LOOP;
END
$func$;
