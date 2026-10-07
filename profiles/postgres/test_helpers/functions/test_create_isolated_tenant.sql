-- test_create_isolated_tenant.sql
--
-- Creates a fresh schema named `p_tenant` and populates it with copies of
-- the tables listed in `p_tables`, taken from `p_source_schema`. Foreign
-- keys are recreated for in-schema relationships; FKs that point outside
-- p_source_schema (e.g. a public.countries reference) are intentionally
-- left alone — the tenant references them directly. Sequences attached
-- to serial columns are also cloned. All triggers on the source tables
-- are rebind-bound: each trigger's body is moved into the tenant schema
-- (so the tenant is fully self-contained), with a SET search_path that
-- points only at the tenant + public, and dictionary references in the
-- function body are rewritten to point at the tenant's own dictionary
-- copy.
--
-- The dictionary table itself is cloned when `p_dictionary_table` is set
-- (default: 'public.dictionary_entries'); only rows whose `category` is
-- in `p_dictionary_categories` are copied (NULL means all rows).
--
-- Generic — no project-specific schema, trigger, or category names are
-- hard-coded. Everything configurable is a parameter.

CREATE OR REPLACE FUNCTION harness_test_helpers.test_create_isolated_tenant(
    p_tenant text,
    p_source_schema text,
    p_tables text[],
    p_dictionary_table text DEFAULT 'public.dictionary_entries',
    p_dictionary_categories text[] DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $func$
DECLARE
    t text;
    seq record;
    v_seq_basename text;   -- e.g. 'witnesses_id_seq'
    v_seq_qualified text;  -- e.g. '"smoke_tenant".witnesses_id_seq' (with quotes)
    fk record;
    v_fk_def text;
    trig record;
    v_func_def text;
    v_trig_def text;
    v_func_qualified_orig text;
    v_func_qualified_new text;
    v_dict_basename text;
    v_dict_basename_quoted text;
BEGIN
    ----------------------------------------------------------------------
    -- 1. Create the tenant schema (and grant USAGE so other roles can see
    --    its objects during tests).
    ----------------------------------------------------------------------
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', p_tenant);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO PUBLIC', p_tenant);

    ----------------------------------------------------------------------
    -- 2. For each table in p_tables: create a LIKE copy in the tenant
    --    schema. PostgreSQL's LIKE clause never copies triggers
    --    (INCLUDING ALL doesn't include them either), so the rebinding
    --    in step 4 is the only path that creates them in the tenant.
    --    We do need INCLUDING DEFAULTS to copy serial/identity defaults
    --    so we can detect them via column_default in the loop below.
    ----------------------------------------------------------------------
    FOREACH t IN ARRAY p_tables LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.%I (LIKE %I.%I INCLUDING ALL)',
            p_tenant, t, p_source_schema, t
        );

        -- Detect columns whose default is a nextval(...) reference to a
        -- sequence in the source schema, create the same sequence in the
        -- tenant, and rewire the column default to point at it. We do
        -- this per-table because the LIKE ... INCLUDING DEFAULTS clause
        -- only copies the default expression text — the sequence itself
        -- is not moved by it.
        --
        -- information_schema.columns.column_default prints the regclass
        -- argument without its schema (e.g. `nextval('witnesses_id_seq'::regclass)`
        -- even though the sequence is in 'rushr_ec'), so we walk
        -- pg_depend instead — that gives us the sequence's real
        -- schema-qualified identity, which we strip down to a basename
        -- before recreating in the tenant.
        FOR seq IN
            SELECT a.attname AS column_name,
                   s.relname  AS seq_basename
            FROM pg_class     c
            JOIN pg_namespace n       ON n.oid = c.relnamespace
            JOIN pg_attribute a       ON a.attrelid = c.oid AND a.attnum > 0
            JOIN pg_attrdef   ad      ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
            JOIN pg_depend    d       ON d.objid = ad.oid
                                     AND d.classid = 'pg_attrdef'::regclass
                                     AND d.deptype = 'n'
            JOIN pg_class    s         ON s.oid = d.refobjid
            WHERE n.nspname = p_source_schema
              AND c.relname = t
              AND a.atthasdef
              AND pg_get_expr(ad.adbin, ad.adrelid) LIKE 'nextval%'
        LOOP
            v_seq_basename := seq.seq_basename;

            EXECUTE format(
                'CREATE SEQUENCE IF NOT EXISTS %I.%I OWNED BY %I.%I.%I',
                p_tenant, v_seq_basename,
                p_tenant, t, seq.column_name
            );

            v_seq_qualified := format('%I.%I', p_tenant, v_seq_basename);
            EXECUTE format(
                'ALTER TABLE %I.%I ALTER COLUMN %I SET DEFAULT nextval(%L::regclass)',
                p_tenant, t, seq.column_name, v_seq_qualified
            );
        END LOOP;
    END LOOP;

    ----------------------------------------------------------------------
    -- 3. Recreate in-schema foreign keys. We only copy FKs whose target
    --    table is also in p_source_schema; FKs that point at, say,
    --    public.countries stay pointing at the original. This is a
    --    documented trade-off: it assumes the global catalogue is shared,
    --    which is the common case.
    ----------------------------------------------------------------------
    FOR fk IN
        SELECT c.conname,
               c.conrelid::regclass::text  AS src_table,
               pg_get_constraintdef(c.oid) AS def
        FROM pg_constraint c
        WHERE c.contype = 'f'
          AND c.connamespace = (SELECT oid FROM pg_namespace WHERE nspname = p_source_schema)
          AND c.confrelid::regnamespace = (SELECT oid FROM pg_namespace WHERE nspname = p_source_schema)
          AND (c.conrelid::regclass::text = ANY (
                SELECT p_source_schema || '.' || tbl FROM unnest(p_tables) tbl
              ))
    LOOP
        v_fk_def := replace(
            fk.def,
            quote_ident(p_source_schema) || '.',
            quote_ident(p_tenant) || '.'
        );
        -- Drop-then-add gives idempotency without needing a UNIQUE check
        -- on constraint names across tenants.
        EXECUTE format(
            'ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS %I',
            p_tenant, split_part(fk.src_table, '.', 2), fk.conname
        );
        EXECUTE format(
            'ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
            p_tenant, split_part(fk.src_table, '.', 2), fk.conname, v_fk_def
        );
    END LOOP;

    ----------------------------------------------------------------------
    -- 4. Discover and rebind every trigger on the copied tables. We do
    --    not name any specific triggers — the loop reads them straight
    --    out of pg_trigger.
    ----------------------------------------------------------------------
    FOR trig IN
        SELECT t.tgname        AS trigger_name,
               t.tgrelid::regclass::text AS table_full_name,
               p.proname       AS function_name,
               n.nspname       AS function_schema,
               p.oid           AS function_oid,
               t.oid           AS trigger_oid
        FROM pg_trigger t
        JOIN pg_class    c   ON c.oid = t.tgrelid
        JOIN pg_namespace nsp ON nsp.oid = c.relnamespace
        JOIN pg_proc p        ON t.tgfoid = p.oid
        JOIN pg_namespace n   ON p.pronamespace = n.oid
        WHERE NOT t.tgisinternal
          AND nsp.nspname = p_source_schema
          AND (t.tgrelid::regclass::text = ANY (
                SELECT p_source_schema || '.' || tbl FROM unnest(p_tables) tbl
              ))
    LOOP
        -- 4a. Pull the full function DDL.
        v_func_def := pg_get_functiondef(trig.function_oid);

        -- 4b. Rewrite the schema qualifier on the function name so the
        --     new copy lives in the tenant namespace.
        v_func_qualified_orig := format('%I.%I', trig.function_schema, trig.function_name);
        v_func_qualified_new   := format('%I.%I', p_tenant, trig.function_name);
        v_func_def := replace(v_func_def, v_func_qualified_orig, v_func_qualified_new);

        -- 4c. Rewrite dictionary references in the body. This is the only
        --     string-rewrite we do inside function bodies; we never touch
        --     references to other public tables. replace() is exact, so
        --     'public.dictionary_entries' becomes '<tenant>.dictionary_entries'
        --     while 'public.countries' (say) stays as 'public.countries'.
        IF p_dictionary_table IS NOT NULL
           AND position(p_dictionary_table IN v_func_def) > 0
        THEN
            v_dict_basename       := split_part(p_dictionary_table, '.', 2);
            v_dict_basename_quoted := quote_ident(v_dict_basename);
            v_func_def := replace(
                v_func_def,
                p_dictionary_table,
                quote_ident(p_tenant) || '.' || v_dict_basename
            );
        END IF;

        -- 4d. Inject SET search_path so the function's unqualified names
        --     resolve against the tenant's own copies, not the source.
        --     pg_get_functiondef always emits the LANGUAGE clause on its
        --     own line followed by 'AS $tag$', which is what we anchor on.
        v_func_def := replace(
            v_func_def,
            E'LANGUAGE plpgsql\nAS ',
            E'LANGUAGE plpgsql\n SET search_path TO ' || quote_ident(p_tenant) || E', public\nAS '
        );

        -- 4e. Create the function copy in the tenant.
        EXECUTE v_func_def;

        -- 4f. Pull the trigger DDL, swap the source schema for the tenant
        --     schema in the table reference, and qualify the function
        --     call. pg_get_triggerdef returns the unqualified function
        --     name (just 'validate_asset_fields'), so we schema-qualify
        --     it explicitly so the right copy is invoked.
        v_trig_def := pg_get_triggerdef(trig.trigger_oid);
        v_trig_def := replace(
            v_trig_def,
            'ON ' || quote_ident(p_source_schema) || '.',
            'ON ' || quote_ident(p_tenant) || '.'
        );
        v_trig_def := regexp_replace(
            v_trig_def,
            'EXECUTE FUNCTION[[:space:]]+(' || quote_literal(trig.function_name) || ')',
            'EXECUTE FUNCTION ' || quote_ident(p_tenant) || '.' || trig.function_name,
            'i'
        );

        EXECUTE v_trig_def;
    END LOOP;

    ----------------------------------------------------------------------
    -- 5. Clone the dictionary table into the tenant and copy the rows
    --    the caller asked for. If no dictionary was specified, skip —
    --    some projects don't have one and that's fine.
    ----------------------------------------------------------------------
    IF p_dictionary_table IS NOT NULL THEN
        v_dict_basename := split_part(p_dictionary_table, '.', 2);
        DECLARE
            v_dict_schema text := split_part(p_dictionary_table, '.', 1);
        BEGIN
            EXECUTE format(
                'CREATE TABLE IF NOT EXISTS %I.%I (LIKE %I.%I INCLUDING ALL)',
                p_tenant, v_dict_basename, v_dict_schema, v_dict_basename
            );

            IF p_dictionary_categories IS NULL THEN
                EXECUTE format(
                    'INSERT INTO %I.%I SELECT * FROM %I.%I ON CONFLICT DO NOTHING',
                    p_tenant, v_dict_basename, v_dict_schema, v_dict_basename
                );
            ELSE
                EXECUTE format(
                    'INSERT INTO %I.%I SELECT * FROM %I.%I
                     WHERE category = ANY($1) ON CONFLICT DO NOTHING',
                    p_tenant, v_dict_basename, v_dict_schema, v_dict_basename
                ) USING p_dictionary_categories;
            END IF;
        END;
    END IF;
END
$func$;