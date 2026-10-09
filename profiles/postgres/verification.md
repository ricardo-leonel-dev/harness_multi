# Shared PostgreSQL verification tools

These scripts and these instructions are harness-owned and refreshed by an
explicit `install.sh --profile postgres` installation. Edit them in the source
harness and reinstall. Your docs, configuration, tests, specs and migrations
remain project-owned. Read docs/verification.md for the project's verification command. The runner uses
explicit PG* environment variables first, then `.harness.json::postgres_database`;
only the Web Display project retains its legacy `web-display` fallback. Set the
target explicitly with `install.sh --profile postgres --postgres-database NAME`
or `PGDATABASE`. Host, port, user and password remain configurable through PG*
environment variables; the runner retains its existing local defaults. Project-specific
credentials are not copied into the installation.

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

`scripts/run_tests.sh` can classify accepted pre-existing failures by basename.
This is a regression policy, not evidence that every historical test passes.
It applies only to projects using this runner and an explicitly accepted baseline;
other projects still require ordinary green tests.

- Before feature changes, run
  `bash scripts/run_tests.sh --all --baseline-write progress/.test_baseline`
  to capture a proposed stale set. The command may exit nonzero because it captures
  failing tests. Inspect the raw logs and accept only demonstrated pre-existing
  failures. Document acceptance, baseline path, revision, database/schema state and
  environment in the session log or project verification policy; preserve pre-change
  output for comparison. A generated file alone is not approval.
- Confirm that evidence still applies to the current branch/revision and database
  environment. A baseline from another branch, tenant state or database is not
  automatically applicable. Establish comparable pre-change evidence when needed.
- Run `bash scripts/run_tests.sh --all --baseline <accepted-path>` against that set.
  Listed failures are `[STALE]` and do not raise the exit code; unlisted failures
  are `[REGRESSION]`, exit nonzero and block approval/log-out. The runner auto-loads
  `progress/.test_baseline` when no explicit flag is provided, so record which
  baseline actually applied.
- Never widen/rewrite a baseline to absorb failures introduced by feature work.
  When fixing stale tests, remove only proven-fixed entries after verification;
  do not regenerate the baseline from a changed failing suite as a shortcut.

Use `--changed` for iteration, but confirm selection includes every added/changed
relevant test, including untracked or ignored files. A basename-level baseline can
mask new failures inside a listed file: all active feature tests and changed relevant
tests must pass without baseline suppression, with passing evidence for every active
acceptance/spec requirement. For SQL tests, execute explicitly selected files using
`psql -X -v ON_ERROR_STOP=1 -f <test-path>` with the project's configured connection,
or run the project's targeted runner with `--no-baseline` where available. Do not
substitute a baseline-filtered zero exit for these checks.

The reviewer independently runs the full suite with `--all --baseline <accepted-path>`,
executes active/changed relevant tests without suppression, and compares stale failure
details to the original evidence. New regressions, changed behavior without passing
proof, or an inapplicable/unaccepted baseline block sign-off. Both handoff and review
record commands, results, baseline provenance and remaining stale failures; report
"no new regressions with accepted stale failures", never "all tests pass".

`./init.sh` and the configured verification command must still exit 0 under the
accepted policy; unrelated setup/lint failures remain blocking. Installation
preserves project-owned `CHECKPOINTS.md` and `docs/verification.md`. If those still
require universal historical green results, explicitly align the local project
policy before closure; shared guidance does not silently override stricter criteria.

## Assemble full migration definitions

Use the installed Python 3 assembler to avoid rebuilding ad-hoc extraction scripts:

```sh
python3 scripts/assemble_migration.py --ddl progress/migration_ddl.sql \
  --definition database/functions/first.sql \
  --definition database/functions/second.sql --output diffs/new_migration.sql
```

It reads DDL followed by the explicitly listed canonical files in argument order,
preserves their text (including multiline `ALTER FUNCTION ... OWNER TO ...`),
and adds a single outer `BEGIN;`/`COMMIT;`. The artifact contains no local includes
and is deterministic for identical input bytes/order. It never connects to a DB or
executes SQL. Ownership capture/reapplication, tenant handling and business rules
remain explicit project-specific input SQL. Review the resulting migration and
verify it with the project's normal database procedure.

Accepted fragments are UTF-8 PostgreSQL SQL without a BOM, with semicolon-terminated top-level
statements. SQL standard strings/quoted identifiers, E strings, dollar quotes,
line comments and nested block comments are lexically recognized. Standard strings
assume `standard_conforming_strings=on` (PostgreSQL default); use E strings for
backslash escapes. No psql metacommands are allowed outside literals/comments.
Top-level transaction controls (`BEGIN`, `START TRANSACTION`, `COMMIT`, `END`,
`ROLLBACK`, `ABORT`, `SAVEPOINT`, `RELEASE`, `PREPARE TRANSACTION`,
`SET [LOCAL] TRANSACTION`) and all `SET SESSION` statements are refused.
The latter exclusion deliberately includes session transaction defaults.
This is a narrow lexical fragment validator, not a SQL parser: it does not inspect
quoted procedure bodies or prove SQL validity/transaction safety. Routine bodies
must be quoted; unquoted SQL `BEGIN ATOMIC` bodies are outside the supported format. Review bodies and dynamic
SQL separately, and supply transactional DDL (no concurrent index creation or other
statements incompatible with a transaction). Database encoding/configuration and
whether definitions execute correctly remain verification responsibilities.

Missing, empty/comments-only, duplicate resolved paths, malformed quoted text,
transaction controls, includes and unfinished statements fail before writing.
Output cannot alias an input. A successful result replaces output atomically;
validation/read/write failures preserve an existing output. No output directory is
created automatically. Keep preparation SQL local according to your project policy.
