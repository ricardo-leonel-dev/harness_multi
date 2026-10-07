-- uninstall.sql — removes the harness_test_helpers schema (and all 6
-- functions) from the current database. Used by uninstall.sh. Production
-- never imports install.sql, so this is mostly a developer convenience
-- for re-running the install cleanly.

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS harness_test_helpers CASCADE;