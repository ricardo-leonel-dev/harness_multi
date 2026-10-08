-- test_drop_isolated_tenant.sql
-- Companion to test_create_isolated_tenant. Drops the tenant schema entirely.
-- Idempotent: re-running with the same tenant name is a no-op.
--
-- Guarded: only drops schemas carrying the COMMENT that
-- test_create_isolated_tenant sets. A typo or a real schema name (e.g. the
-- project's source schema) raises instead of running DROP SCHEMA ... CASCADE
-- against live data.

CREATE OR REPLACE FUNCTION harness_test_helpers.test_drop_isolated_tenant(
    p_tenant text
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_oid oid;
BEGIN
    SELECT oid INTO v_oid FROM pg_namespace WHERE nspname = p_tenant;
    IF v_oid IS NULL THEN
        RETURN;
    END IF;
    IF obj_description(v_oid, 'pg_namespace') IS DISTINCT FROM 'harness_test_helpers:isolated_tenant' THEN
        RAISE EXCEPTION 'test_drop_isolated_tenant: schema % was not created by test_create_isolated_tenant; refusing to drop it', p_tenant;
    END IF;
    EXECUTE format('DROP SCHEMA %I CASCADE', p_tenant);
END
$$;
