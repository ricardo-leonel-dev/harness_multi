-- test_drop_isolated_tenant.sql
-- Companion to test_create_isolated_tenant. Drops the tenant schema entirely.
-- Idempotent: re-running with the same tenant name is a no-op.

CREATE OR REPLACE FUNCTION harness_test_helpers.test_drop_isolated_tenant(
    p_tenant text
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- We never accept a tenant name that escapes the identifier into something
    -- dangerous; format(%I, ...) handles that, but the bare SCHEMA CASCADE
    -- is the safe path. If the schema doesn't exist, this is a no-op.
    EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', p_tenant);
END
$$;