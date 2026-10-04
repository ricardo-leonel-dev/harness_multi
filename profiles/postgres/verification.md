# Shared PostgreSQL verification tools

These scripts and these instructions are harness-owned and refreshed by an
explicit `install.sh --profile postgres` installation. Edit them in the source
harness and reinstall. Your docs, configuration, tests, specs and migrations
remain project-owned. Read docs/verification.md for the projects actual runner
and database setup; this profile installs no credentials or runner defaults.

Copy `scripts/templates/acceptance_test_prologue.sql` to your own acceptance test.
Replace SCHEMA/TABLE, set expect_table to true or false, and insert assertions
before the explicit ROLLBACK. The template requires an existing schema; false
means the table must be absent and skips the baseline. Standalone execution:

```sh
psql -X -v ON_ERROR_STOP=1 -f tests/your_acceptance.sql
```

Use a disposable database for migration verification. Tests own their transaction
and rollback. Check migrations for COMMIT/transaction control before applying
inside tests; a runner is not assumed to undo data. psql stops on exceptions;
connection closure rolls back an interrupted transaction. Never add COMMIT to
acceptance fixtures. Dollar-quoted DO bodies do not expand psql variables: the
prologue passes configuration via a temporary table and quotes dynamic identifiers.

For an SDD evidence index, name actual assertions `t1_description_r1_r2` and emit
`SELECT 'PASS' AS result, 't1_description_r1_r2' AS test_case;`. Then run:

```sh
scripts/build_traceability.sh feature_slug --test tests/your_acceptance.sql
```

`--test-file PATH` is accepted as a compatibility alias for explicit selection.
Omitting the test path is always an error. The scanner reads `## R1` requirement headings and literal PASS/test_case SELECTs
(case-sensitive aliases), supports multiline rows, and flags missing references
with a nonzero exit. Use plain SELECT statements with one assertion per statement;
it is a naming scanner, not a SQL parser (commented-out blocks and dynamic SQL
must be checked by the reviewer). It never searches other feature tests, executes
SQL, proves semantic coverage, or measures time savings. Include actual execution
results separately and have the reviewer inspect the named assertions.

Maintain self-contained migration diffs for execution against external databases.
For every changed function, include its full CREATE OR REPLACE FUNCTION body in
the diff; deliver complete modified definitions so external execution requires
no access to the local source tree.
Do not replace repeated definitions with local file includes to reduce report or
generation length. Group report evidence when appropriate using
`harness/instructions/coverage.md`; each requirement still needs passing evidence.
