# Reusable PostgreSQL mock data

The harness supplies `scripts/mock_data.py` and three `scripts/harness.sh` commands.
Projects own `.harness.json` configuration, selections and `mock-data/` records.
Templates contain real selected records, including potentially sensitive values. Review
or anonymize project data before publishing it; do not put credentials in templates.

Configure `postgres_database` and `postgres_schemas` as a JSON array. Installation can
set both with `--profile postgres --postgres-database DB --postgres-schemas '["schema"]'`.
Connection settings follow `PSQL_HOST/PORT/USER/DB`, then `PGHOST/PORT/USER/DATABASE`,
then `.harness.json::verify_command`. Passwords are passed in the subprocess environment.
`PSQL_BIN` selects the PostgreSQL client. No Python database driver is required.

```bash
scripts/harness.sh mock-data-generate --version initial --selection mock-data/selection.json
scripts/harness.sh mock-data-check --version initial
scripts/harness.sh mock-data-check --version initial --offline
scripts/harness.sh mock-data-load --version initial --target-database harness_mock_example
scripts/harness.sh mock-data-generate --version feature-028 --extends initial --database harness_mock_migrated --selection mock-data/selection-feature-028.json
```

Generate reads a repeatable-read, read-only snapshot. Each table has its complete
column/constraint/trigger metadata and records in `mock-data/<schema>/<table>/<version>.json`.
`mock-data/manifests/<version>.json` chooses explicit versions and SHA-256 checksums.
Identical tables reuse the previous template; old versions cannot be overwritten.
A changed schema or record set creates a new table version. Removed tables disappear
from the new manifest. A new required field must be populated in the explicitly prepared
source first; values are never guessed. The tool does not apply migrations.

A selection is `{ "tables": [{"table":"schema.assets", "ids":[1,2]}] }`.
Composite primary keys use arrays in `ids`. All configured schema tables are included;
unspecified tables start with at most ten rows (`--limit`), then recursive FK parent
closure adds dependencies. Explicit empty `ids` keeps an empty table unless required
as a parent. Tables without primary keys fail with an actionable error. Cyclic row
references fail without disabling constraints; projects must provide a suitable seed
strategy. Partitioned datasets are not supported. Templates are immutable; edit a
prepared source/selection and generate a new version to change records.

Declare additional trigger/FK support tables in `mock_data.support_tables` (for example
`public.countries`, `public.dictionary_entries`) and select required records explicitly.
Declare known internal references without FK constraints in `mock_data.logical_references`:
`[{"table":"schema.campaigns","columns":["parent_campaign_id"],"references":"schema.campaigns","reference_columns":["id"]}]`.
References to other databases remain unchanged and are not inspected.

Load requires an explicitly named `harness_mock_*` database whose database comment is
exactly `harness mock-data disposable`. Create/mark that disposable target separately
and prepare its schema/functions/triggers using the project's existing schema workflow
or a schema-only dump. The command creates no databases or schema objects, never drops,
truncates or deletes records, rejects the configured source database, checks schema
compatibility, and requires every selected target table to be empty. Inserts run in one
transaction in row dependency order with FK/trigger checks enabled. Generated columns
are omitted and identity values are preserved. Serial/identity sequences (including unowned nextval defaults) advance
after successful inserts/constraint checks; PostgreSQL sequence state is not transactional.
A failed transaction can leave a sequence advanced only in the explicitly disposable DB.

Checks compare files/hashes, relationship closure and current database metadata.
Additive nullable/default/generated/identity fields are compatible with older records;
removed/changed columns, required fields without defaults and changed constraints/triggers
require a new version. Generation still versions any changed table metadata. Offline
checks intentionally cannot prove target compatibility or runtime trigger behavior.
Real schema compatibility and trigger behavior should be proved by loading a fresh
disposable database during feature verification. Keep initial/source databases read-only.

The system supports several configured schemas in one project; it does not introduce
tenant lifecycle management. Run `--help` on any mock-data command for options.


## Agent workflow: implementation

This workflow applies only when this guide and `scripts/mock_data.py` are installed
and `.harness.json::postgres_schemas` is a non-empty array. The implementer executes
the commands as part of the feature; the human need not prepare or load data manually.
Projects without this configuration keep their existing verification procedure.
These are agent instructions, not an automatic runtime migration orchestrator.

1. **Choose the base before making database changes.** Establish the intended source
   branch/revision, actual baseline schema and approved feature dependencies from
   current evidence. Inspect candidate manifests and check compatibility against that
   schema. Never infer the base from the highest feature number, newest file or all
   local canonical definitions: those may contain unrelated undeployed features.
   If feature 28 is not in dev and independent feature 29 adds an assets field,
   feature 29 extends `initial` when that matches dev; it must not implicitly acquire
   feature 28's association migration. A feature that requires 28 must record the
   dependency and use a schema/base that includes it. If evidence cannot establish a
   safe base, report the missing evidence rather than guess or promote a migration.
2. **Prepare and load the baseline.** Create a uniquely named `harness_mock_*` database,
   mark its database comment `harness mock-data disposable`, and record its ownership.
   Use the project's schema-only preparation procedure from the verified baseline,
   including functions, triggers and configured support tables. Selected tables must
   be empty. Check the chosen base online against this target and load it there before
   applying the task migration. Keep source/dev business data read-only; do not apply
   migrations there or change project connection configuration to target a disposable.
   The mock-data tools neither prepare schema objects nor apply migrations.
3. **Apply only the task and its established dependencies.** Use the project's normal
   migration procedure on the disposable. Supply any new required values explicitly
   according to the feature's rules; never invent them. Extend the project selection
   with the scenarios needed for the feature and keep FK/trigger checks enabled.
   Internal configured references and support tables remain in scope. Preserve known
   references to other databases without inspecting those databases; their validation
   is outside this workflow unless the project explicitly includes it.
4. **Reuse or generate deliberately.** A non-schema feature reuses the compatible
   existing dataset unless its scenarios require new records. Additive nullable/default
   fields can load older records when the compatibility check accepts them; changed
   schema metadata still requires a new table version when generating the updated
   dataset. For changed schema/records, generate from the prepared migrated disposable
   with an explicit base and project-owned selection. Unchanged templates are reused.
   Versions are immutable: on resume inspect and reuse an existing feature manifest
   if applicable; never delete/overwrite it or blindly repeat generation. If the schema
   or records changed again, use a unique revision such as `feature-029-r2`, extending
   the documented appropriate base. Keep earlier versions and report the lineage.
5. **Prove the result.** Check the resulting manifest online against the migrated
   target. Prepare a second fresh marked disposable with the expected post-feature
   schema and load that exact manifest into empty selected tables. Run the relevant
   behavioral/acceptance tests against that explicitly targeted database and the
   project's required verification policy. Loading proves the seed works with real
   constraints/triggers; tests must still prove the feature. Offline checks prove only
   file integrity/closure and cannot substitute for either runtime check.
6. **Handoff and cleanup.** Record branch/revision and schema evidence, base-selection
   rationale, manifest/version/selection paths, tables reused or changed, exact commands
   and results, and elapsed preparation/verification time in `progress/impl_<feature>.md`
   (and the session log when a session exists). Keep evidence and project templates.
   Remove only disposables positively identified as created by this task, checking the
   marker/name and recorded ownership; never remove another task's database. The reviewer
   prepares its own independent targets. Normal reviewer approval/log-out still applies.

For the independent feature-29 example, after preparing/marking an empty baseline
target `harness_mock_feature029_work` using the project's verified schema procedure:

```bash
scripts/harness.sh mock-data-check --version initial --database harness_mock_feature029_work
scripts/harness.sh mock-data-load --version initial --target-database harness_mock_feature029_work
# Apply this task's migration to that disposable using the project procedure.
scripts/harness.sh mock-data-generate --version feature-029 --extends initial --database harness_mock_feature029_work --selection mock-data/selection-feature-029.json
scripts/harness.sh mock-data-check --version feature-029 --database harness_mock_feature029_work
# Prepare/mark harness_mock_feature029_reload with the expected migrated schema.
scripts/harness.sh mock-data-load --version feature-029 --target-database harness_mock_feature029_reload
# Run the project's feature tests with an explicit connection to the reload target.
```

If no dataset exists, bootstrap only from an authorized, read-only scoped source
matching the established baseline and the project's explicit selection/support-table
policy. Generate a uniquely named initial version and validate it through a fresh
disposable load before reuse. Do not silently expand scope or guess reference records.

## Agent workflow: independent review

Read the implementation evidence and inspect the actual manifests/templates. Confirm
that the chosen base matches the intended branch/schema and approved dependencies,
that baseline load preceded the task migration, and that unrelated undeployed changes
were not included. Check immutable version lineage and exact table-version reuse.
Independently prepare an owned, empty, marked disposable with the expected post-feature
schema; run the online compatibility check, load the exact resulting (or deliberately
reused) manifest and execute the relevant feature tests. Inspect real outcomes rather
than accepting offline checks or implementation prose as runtime proof. Record commands,
results, base/schema evidence and elapsed review verification time in `progress/review.md`.
Confirm safe cleanup of owned targets and preservation of source/project artifacts.
Missing proof or new failures require changes under the normal review policy; this
workflow does not waive the existing suite, baseline or mechanical review requirements.
