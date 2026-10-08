-- test_create_isolated_tenant.sql
--
-- Creates a fresh schema named `p_tenant` and populates it with copies of
-- the tables listed in `p_tables`, taken from `p_source_schema`. Foreign
-- keys between the copied tables are recreated against the tenant copies;
-- FKs that point at any table NOT in `p_tables` (another source table, or
-- e.g. public.countries) are not recreated — the tenant copy has no FK
-- there. Sequences attached to serial columns are also cloned. All
-- triggers on the source tables are rebound: each trigger function is
-- copied into the tenant schema with SET search_path TO
-- <tenant>, <source>, public (so unqualified names hit the tenant copies
-- first), and schema-qualified dictionary references in the function body
-- are rewritten to point at the tenant's own dictionary copy.
--
-- The dictionary table is cloned when `p_dictionary_table` is set
-- (default: 'public.dictionary_entries') AND exists; a missing default
-- dictionary is skipped with a NOTICE so projects without one can call
-- the function with only 3 arguments. Only rows whose `category` is in
-- `p_dictionary_categories` are copied (NULL means all rows).
--
-- The function runs with search_path = pg_catalog. That makes every
-- catalog-to-text conversion (regclass::text, pg_get_constraintdef,
-- pg_get_triggerdef) schema-qualify its output, regardless of the
-- caller's search_path. Without it, a source schema on the caller's path
-- (typically `public`) prints unqualified names and every rewrite below
-- silently matches nothing.
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
SET search_path = pg_catalog
AS $func$
DECLARE
    v_src_oid oid;
    t text;
    seq record;
    fk record;
    v_fk_def text;
    trig record;
    v_func_def text;
    v_header text;
    v_rest text;
    v_as_pos int;
    v_trig_def text;
    v_dict_oid oid;
    v_dict_schema text;
    v_dict_basename text;
BEGIN
    SELECT oid INTO v_src_oid FROM pg_namespace WHERE nspname = p_source_schema;
    IF v_src_oid IS NULL THEN
        RAISE EXCEPTION 'test_create_isolated_tenant: source schema % does not exist', p_source_schema;
    END IF;

    -- Resolve the dictionary up front: a missing table is only an error
    -- when the caller named it explicitly.
    IF p_dictionary_table IS NOT NULL THEN
        v_dict_oid := to_regclass(p_dictionary_table);
        IF v_dict_oid IS NULL THEN
            IF p_dictionary_table = 'public.dictionary_entries' THEN
                RAISE NOTICE 'test_create_isolated_tenant: % not found, skipping dictionary copy', p_dictionary_table;
            ELSE
                RAISE EXCEPTION 'test_create_isolated_tenant: dictionary table % does not exist', p_dictionary_table;
            END IF;
        ELSE
            SELECT n.nspname, c.relname INTO v_dict_schema, v_dict_basename
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.oid = v_dict_oid;
        END IF;
    END IF;

    ----------------------------------------------------------------------
    -- 1. Create the tenant schema (and grant USAGE so other roles can see
    --    its objects during tests).
    ----------------------------------------------------------------------
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', p_tenant);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO PUBLIC', p_tenant);

    ----------------------------------------------------------------------
    -- 2. For each table in p_tables: create a LIKE copy in the tenant
    --    schema. PostgreSQL's LIKE clause never copies triggers or
    --    foreign keys, so steps 3 and 4 are the only paths that create
    --    them in the tenant. INCLUDING ALL copies serial defaults as
    --    text (still pointing at the source sequence), rewired below.
    ----------------------------------------------------------------------
    FOREACH t IN ARRAY p_tables LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace = v_src_oid AND relname = t) THEN
            RAISE EXCEPTION 'test_create_isolated_tenant: %.% does not exist', p_source_schema, t;
        END IF;

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.%I (LIKE %I.%I INCLUDING ALL)',
            p_tenant, t, p_source_schema, t
        );

        -- Walk pg_depend (not information_schema's column_default text)
        -- to find the sequence each nextval() default really points at.
        FOR seq IN
            SELECT a.attname AS column_name,
                   s.relname  AS seq_basename
            FROM pg_class     c
            JOIN pg_attribute a       ON a.attrelid = c.oid AND a.attnum > 0
            JOIN pg_attrdef   ad      ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
            JOIN pg_depend    d       ON d.objid = ad.oid
                                     AND d.classid = 'pg_attrdef'::regclass
                                     AND d.deptype = 'n'
            JOIN pg_class    s         ON s.oid = d.refobjid AND s.relkind = 'S'
            WHERE c.relnamespace = v_src_oid
              AND c.relname = t
              AND a.atthasdef
              AND pg_get_expr(ad.adbin, ad.adrelid) LIKE 'nextval%'
        LOOP
            EXECUTE format(
                'CREATE SEQUENCE IF NOT EXISTS %I.%I OWNED BY %I.%I.%I',
                p_tenant, seq.seq_basename,
                p_tenant, t, seq.column_name
            );
            EXECUTE format(
                'ALTER TABLE %I.%I ALTER COLUMN %I SET DEFAULT nextval(%L::regclass)',
                p_tenant, t, seq.column_name, format('%I.%I', p_tenant, seq.seq_basename)
            );
        END LOOP;
    END LOOP;

    ----------------------------------------------------------------------
    -- 3. Recreate foreign keys whose source AND target are both copied
    --    tables. Matching is by oid/relname, never by regclass text.
    ----------------------------------------------------------------------
    FOR fk IN
        SELECT con.conname,
               src.relname                   AS src_table,
               tgt.relname                   AS tgt_table,
               pg_get_constraintdef(con.oid) AS def
        FROM pg_constraint con
        JOIN pg_class src ON src.oid = con.conrelid
        JOIN pg_class tgt ON tgt.oid = con.confrelid
        WHERE con.contype = 'f'
          AND src.relnamespace = v_src_oid AND src.relname = ANY (p_tables)
          AND tgt.relnamespace = v_src_oid AND tgt.relname = ANY (p_tables)
    LOOP
        -- search_path = pg_catalog guarantees the REFERENCES target is
        -- printed schema-qualified, so this rewrite is exact.
        v_fk_def := replace(
            fk.def,
            'REFERENCES ' || format('%I.%I', p_source_schema, fk.tgt_table) || '(',
            'REFERENCES ' || format('%I.%I', p_tenant, fk.tgt_table) || '('
        );
        -- Drop-then-add gives idempotency without needing a UNIQUE check
        -- on constraint names across tenants.
        EXECUTE format(
            'ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS %I',
            p_tenant, fk.src_table, fk.conname
        );
        EXECUTE format(
            'ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
            p_tenant, fk.src_table, fk.conname, v_fk_def
        );
    END LOOP;

    ----------------------------------------------------------------------
    -- 4. Discover and rebind every trigger on the copied tables. We do
    --    not name any specific triggers — the loop reads them straight
    --    out of pg_trigger.
    ----------------------------------------------------------------------
    FOR trig IN
        SELECT tg.tgname        AS trigger_name,
               c.relname        AS table_name,
               p.proname        AS function_name,
               n.nspname        AS function_schema,
               p.oid            AS function_oid,
               tg.oid           AS trigger_oid
        FROM pg_trigger tg
        JOIN pg_class    c   ON c.oid = tg.tgrelid
        JOIN pg_proc     p   ON p.oid = tg.tgfoid
        JOIN pg_namespace n  ON n.oid = p.pronamespace
        WHERE NOT tg.tgisinternal
          AND c.relnamespace = v_src_oid
          AND c.relname = ANY (p_tables)
    LOOP
        -- 4a. Pull the full function DDL. pg_get_functiondef always
        --     schema-qualifies the function name in the header.
        v_func_def := pg_get_functiondef(trig.function_oid);

        -- 4b. Rewrite the schema qualifier on the function name so the
        --     new copy lives in the tenant namespace.
        v_func_def := replace(
            v_func_def,
            format('%I.%I', trig.function_schema, trig.function_name),
            format('%I.%I', p_tenant, trig.function_name)
        );

        -- 4c. Rewrite dictionary references in the body. This is the only
        --     string-rewrite we do inside function bodies; we never touch
        --     references to other tables. replace() is exact, so
        --     'public.dictionary_entries' becomes '<tenant>.dictionary_entries'
        --     while 'public.countries' (say) stays as 'public.countries'.
        IF v_dict_oid IS NOT NULL THEN
            v_func_def := replace(
                v_func_def,
                format('%I.%I', v_dict_schema, v_dict_basename),
                format('%I.%I', p_tenant, v_dict_basename)
            );
        END IF;

        -- 4d. Pin the copy's search_path so unqualified names resolve
        --     against the tenant copies first. pg_get_functiondef puts
        --     every option (LANGUAGE, SET ...) in the header before the
        --     first line starting with 'AS '; we drop any existing
        --     search_path there and add ours, for any function language.
        v_as_pos := position(E'\nAS ' IN v_func_def);
        v_header := regexp_replace(left(v_func_def, v_as_pos - 1),
                                   E'\n SET search_path TO [^\n]*', '', 'g');
        v_rest := substr(v_func_def, v_as_pos);
        v_func_def := v_header
            || format(E'\n SET search_path TO %I, %I, public', p_tenant, p_source_schema)
            || v_rest;

        -- 4e. Create the function copy in the tenant.
        EXECUTE v_func_def;

        -- 4f. Pull the trigger DDL and point both the table and the
        --     function at the tenant. pg_get_triggerdef qualifies the
        --     function name here because search_path = pg_catalog.
        v_trig_def := pg_get_triggerdef(trig.trigger_oid);
        v_trig_def := replace(
            v_trig_def,
            ' ON ' || format('%I.%I', p_source_schema, trig.table_name) || ' ',
            ' ON ' || format('%I.%I', p_tenant, trig.table_name) || ' '
        );
        v_trig_def := replace(
            v_trig_def,
            'EXECUTE FUNCTION ' || format('%I.%I', trig.function_schema, trig.function_name) || '(',
            'EXECUTE FUNCTION ' || format('%I.%I', p_tenant, trig.function_name) || '('
        );

        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I',
                       trig.trigger_name, p_tenant, trig.table_name);
        EXECUTE v_trig_def;
    END LOOP;

    ----------------------------------------------------------------------
    -- 5. Clone the dictionary table into the tenant and copy the rows
    --    the caller asked for. OVERRIDING SYSTEM VALUE keeps GENERATED
    --    ALWAYS identity columns copyable.
    ----------------------------------------------------------------------
    IF v_dict_oid IS NOT NULL THEN
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.%I (LIKE %I.%I INCLUDING ALL)',
            p_tenant, v_dict_basename, v_dict_schema, v_dict_basename
        );

        IF p_dictionary_categories IS NULL THEN
            EXECUTE format(
                'INSERT INTO %I.%I OVERRIDING SYSTEM VALUE SELECT * FROM %I.%I ON CONFLICT DO NOTHING',
                p_tenant, v_dict_basename, v_dict_schema, v_dict_basename
            );
        ELSE
            EXECUTE format(
                'INSERT INTO %I.%I OVERRIDING SYSTEM VALUE SELECT * FROM %I.%I
                 WHERE category = ANY($1) ON CONFLICT DO NOTHING',
                p_tenant, v_dict_basename, v_dict_schema, v_dict_basename
            ) USING p_dictionary_categories;
        END IF;
    END IF;
END
$func$;
