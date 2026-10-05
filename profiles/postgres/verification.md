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

## Avoid byte-level fingerprints in acceptance tests

Do not assert `md5(pg_get_functiondef(...))`, `sha256(pg_get_functiondef(...))`,
or any hash-of-body as a primary acceptance check. They fail on every
legitimate modification to the function body — adding a column, reordering
SELECT columns, adding a comment, renaming an internal variable — forcing
unnecessary churn on every feature that touches the function. When the
expected hash is forgotten in that churn, the test silently lies: a future
incidental refactor can re-match the stale hash and the test passes while
the function it claims to verify has drifted. `scripts/lint_test_fingerprints.sh`
scans `tests/*.sql` for these patterns on every `init.sh` run and fails the
lint gate; adding a fingerprint test requires updating the linter first.
Prefer behavioral assertions: assert the JSON output's required keys or
types (`jsonb_object_keys`, `jsonb_typeof`), or call the procedure with the
input you care about and check the response. Real regressions (renamed
public field, broken join) still surface in other tests; the fingerprint
adds friction without proportionate signal.

## Pre-existing test failures: the baseline cache

DB-schema projects accumulate pre-existing test failures over time as the
schema evolves: stored procedure bodies drift in ways that make old
acceptance assertions stale (e.g. a fixture row count that the original
test assumed to be zero), feature work retroactively changes a column type
that an older test then asserts incorrectly, or a function gets renamed.
When a test suite has 5–10 of these stale failures, every implementer
spends 5–15 minutes per task proving "this is not mine" via `git stash`
plus a re-run, even though the work has nothing to do with those tests.

`scripts/run_tests.sh` ships a baseline cache to break that cycle:

- Run `bash scripts/run_tests.sh --all --baseline-write progress/.test_baseline`
  once when you accept a known-stale set. The script writes the basenames
  of currently failing tests to that file (one per line, `#` comments).
- From then on, run `bash scripts/run_tests.sh --all --baseline progress/.test_baseline`.
  Tests that fail and ARE in the baseline are reported as `[STALE]`
  (informational, no exit code bump). Tests that fail and are NOT in
  the baseline are `[REGRESSION]` (non-zero exit, blocks log-out).
- Re-run `--baseline-write` whenever a previously-stale test is actually
  fixed, to refresh the captured set.

The implementer's dev loop should still use `--changed` (or
`--changed --baseline`) for fast iteration on the in-progress feature.
The reviewer runs `--all --baseline` at log-out time to verify no
regressions; pre-existing failures do not block sign-off.
