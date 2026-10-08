# Generic Postgres Test Helpers

Six PL/pgSQL functions installed into schema `harness_test_helpers` of a
project's dev/test database. They are **completely generic** — no project
schema, trigger, or category names are hard-coded — so they work for any
postgres project that uses `install.sh --profile postgres`.

The bundle is harness-owned: `install.sh` refreshes it into
`<project>/harness/test_helpers/` on every reinstall (git-excluded, never
edit it there), and `init.sh` installs it conditionally
when `.harness.json::test_helpers.enabled = true`. Production never sees
the `harness_test_helpers` schema — it is installed only into the dev/test
DB the project's `verify_command` points at.

## Quick start

```bash
# 1. install.sh --profile postgres (one-time per project, idempotent)
bash install.sh --profile postgres --slug my-db --verify-command "..."

# 2. opt in via .harness.json
jq '.test_helpers = { enabled: true, schema: "harness_test_helpers" }' \
  .harness.json > .harness.json.tmp && mv .harness.json.tmp .harness.json

# 3. bash init.sh — installs the 6 functions into your DB on every run
bash init.sh

# 4. use them from any acceptance test
psql -v ON_ERROR_STOP=1 -f tests/foo.sql
```

## The 6 functions

All live in schema `harness_test_helpers`, are `CREATE OR REPLACE`, and
have `GRANT EXECUTE TO PUBLIC` so any role in the project's dev DB can
call them.

### 1. `test_create_isolated_tenant`

```sql
harness_test_helpers.test_create_isolated_tenant(
    p_tenant text,
    p_source_schema text,
    p_tables text[],
    p_dictionary_table text DEFAULT 'public.dictionary_entries',
    p_dictionary_categories text[] DEFAULT NULL
) RETURNS void
```

Creates a fresh schema `p_tenant` and populates it with copies of every
table in `p_tables`, drawn from `p_source_schema`. Per table, the function:

- creates a `LIKE ... INCLUDING ALL` copy (LIKE never copies triggers
  or foreign keys; both are handled below)
- clones sequences attached to serial columns and rewires the column
  defaults to point at the new sequences
- re-creates every foreign key between two tables in `p_tables`,
  pointing at the tenant copies. FKs to any other table (another table
  of the source schema, or e.g. `public.countries`) are not recreated —
  a deliberate trade-off
- discovers and rebinds every trigger on the copied tables: each
  trigger function is copied into the tenant schema with
  `SET search_path TO <tenant>, <source>, public`, and schema-qualified
  dictionary references are rewritten to point at the tenant's
  dictionary copy

The function runs with `search_path = pg_catalog` internally, so it
behaves the same whether or not the source schema (typically `public`)
is on the caller's `search_path`.

If `p_dictionary_table` (schema-qualified) is non-NULL the named
dictionary table is also cloned into the tenant, populated with rows
whose `category` is in `p_dictionary_categories` (or all rows if NULL).
When the default `public.dictionary_entries` does not exist the copy is
skipped with a NOTICE, so projects without a dictionary can call the
function with three arguments; an explicitly named table that does not
exist is an error.

**Examples** — rushr-style and a generic postgres project:

```sql
-- rushr_web_display style: copy 3 witness tables + dictionary
SELECT harness_test_helpers.test_create_isolated_tenant(
    'smoke_tenant', 'rushr_ec',
    ARRAY['witnesses','witnesses_logs','witnesses_media']
);
-- Same, but only seed the two dictionary categories the validate_X
-- triggers actually check (others are noise).
SELECT harness_test_helpers.test_create_isolated_tenant(
    'smoke_tenant', 'rushr_ec',
    ARRAY['campaigns','assets'],
    'public.dictionary_entries',
    ARRAY['target_device','campaign_objective']
);

-- Generic project: copy users/orders, no dictionary at all
SELECT harness_test_helpers.test_create_isolated_tenant(
    'order_test', 'app',
    ARRAY['users','orders'],
    NULL   -- no dictionary table to clone
);
```

### 2. `test_drop_isolated_tenant`

```sql
harness_test_helpers.test_drop_isolated_tenant(p_tenant text) RETURNS void
```

Companion to function 1. `DROP SCHEMA <p_tenant> CASCADE`, idempotent
(a missing schema is a no-op). Guarded: function 1 marks every schema it
creates with `COMMENT ON SCHEMA ... IS 'harness_test_helpers:isolated_tenant'`,
and this function raises on any schema without that mark — so a typo or a
real schema name (`'rushr_ec'`, `'public'`) can never be dropped through it.
Function 1 applies the same check: it refuses to reuse an existing schema it
did not create (or `p_tenant = p_source_schema`), since that would rebind
triggers on live tables.

### 3. `test_make_minimal_row`

```sql
harness_test_helpers.test_make_minimal_row(
    p_schema text,
    p_table text,
    p_extras jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
```

Introspects every `NOT NULL DEFAULT-less column` of `<schema>.<table>`
(identity and generated columns excluded) and emits a JSONB object with
a stub value for each. `p_extras` is merged on top so the caller can
override any field. The result is directly insertable with
`test_insert_row`.

Stub values: arrays → JSON array `[]`, jsonb/json → JSON object `{}`,
numeric → `0`, boolean → `false`, text → `'test_value'` (truncated to
the column length), timestamp → `'1970-01-01 00:00:00'`, date →
`'1970-01-01'`, uuid → fresh `gen_random_uuid()`, enum → first
`enumsortorder` label (looked up in the type's own schema, so enum
columns of a tenant copy work too).

**Honest limitation:** for tables whose NOT-NULL columns are validated
by triggers that look up domain-specific values (e.g. `validate_campaign_fields`
checks `target_devices` against `dictionary_entries.category = 'target_device'`),
the stub values do NOT pass the trigger. Override those fields via
`p_extras`, or write a Tier 2 per-table helper that knows the trigger's
contract. The function is deliberately not silent about this — its
docstring above names the limitation, and the failure mode on INSERT
is clear (`RAISE EXCEPTION 'Invalid target type ...'`).

### 4. `test_insert_row`

```sql
harness_test_helpers.test_insert_row(
    p_schema text,
    p_table text,
    p_payload jsonb
) RETURNS bigint
```

Builds the row-type dynamically from the catalog (`format_type()` of each
column, so enums, arrays and typmods are exact) and runs
`INSERT INTO <schema>.<table> SELECT ... FROM jsonb_to_recordset($1)`.
Array columns take JSON arrays (`["a","b"]`).
Returns the new id when the table has a bigint/int/smallint `id` column
(common case), or `1` as a sentinel otherwise.

Columns omitted from `p_payload` keep the table's `DEFAULT`. JSON nulls
become SQL nulls (so a NOT-NULL column without a DEFAULT will reject the
row, as expected).

### 5. `test_seed_dictionary_entries`

```sql
harness_test_helpers.test_seed_dictionary_entries(
    p_schema text,
    p_table text DEFAULT 'dictionary_entries',
    p_entries jsonb DEFAULT '[]'::jsonb
) RETURNS void
```

Inserts or refreshes dictionary entries into `<schema>.<p_table>`.
`p_entries` is a JSONB array of `{code, category, is_active, label}`
objects. `ON CONFLICT (code, category) DO UPDATE` so re-running the
same entries refreshes them in place.

The table needs a non-partial UNIQUE index or PRIMARY KEY on exactly
`(code, category)` (either order) — that is what `ON CONFLICT (code,
category)` can infer; `(code)` alone or `(code, category, lang)` does
not qualify and the function raises up front. `is_active` is cast to
the column's own type (smallint, integer or boolean) and defaults to 1.
Projects whose dictionary uses a different uniqueness rule should write
a per-table Tier 2 helper.

### 6. `test_assert_field_equals`

```sql
harness_test_helpers.test_assert_field_equals(
    p_schema text,
    p_table text,
    p_id bigint,
    p_field text,
    p_expected jsonb
) RETURNS void
```

Reads `<schema>.<table>.id = p_id`'s `<p_field>` as JSONB and asserts
it equals `p_expected`. On mismatch it `RAISE EXCEPTION`s with the
row id, field, expected, and actual values.

## Opt-out

```bash
bash harness/test_helpers/uninstall.sh
# or by config:
jq 'del(.test_helpers)' .harness.json > .harness.json.tmp \
  && mv .harness.json.tmp .harness.json
```

`uninstall.sh` drops schema `harness_test_helpers CASCADE` from the same
database `install.sh` installs into (both resolve the connection through
`lib_conn.sh`, including the `datname='<db>'` existence-check pattern of
`verify_command`).

### Host lock

`install.sh` and `uninstall.sh` refuse any host not explicitly allowed, so a
`verify_command` (or `PG*` env) that points at a shared or remote database
never gets these DDL-running, `EXECUTE`-to-`PUBLIC` functions installed.
Allowed by default: `localhost`, `127.0.0.1`, `::1` and Unix sockets. If your
dev/test DB lives elsewhere (Docker host name, a dev server), list it:

```bash
jq '.test_helpers.allowed_hosts = ["localhost", "dev-db.internal"]' \
  .harness.json > .harness.json.tmp && mv .harness.json.tmp .harness.json
```

Setting `allowed_hosts` replaces the defaults (keep `localhost` if you still
want it); Unix sockets are always allowed. Never list a production host.

## Limitations

- **Only FKs between copied tables are recreated.** If
  `rushr_ec.assets.country_id` references `public.countries.id` (or a
  source table you did not list in `p_tables`), the tenant copy has no
  FK for that column. Copy the referenced table too if a test depends
  on the constraint.
- **Triggers with side effects outside the source schema are not
  isolated.** A trigger that writes to a different schema (e.g. an
  audit-log table in `public.audit`) will still write there when fired
  in the tenant. Use Tier 2 for those tables.
- **Only row/statement triggers on the copied tables are rebound.**
  Event triggers and triggers on views are out of scope. Partitioned
  tables are copied by `LIKE` as plain tables.
- **`test_make_minimal_row` does not try to be smart about trigger
  validation.** See function 3's docstring.
- **`test_seed_dictionary_entries` requires a unique index on exactly
  `(code, category)`.** Other uniqueness shapes → Tier 2.

## Extending with per-table helpers (Tier 2)

Projects whose tables have unusual constraints (complex triggers,
domain-specific NOT-NULL checks, etc.) can write their own per-table
helpers. They live **outside** `harness/` — `install.sh` of the toolkit
lists `harness/` in `.git/info/exclude`, and Tier 2 files must be
versioned with the project:

```
<project>/
├── harness/test_helpers/                    # from personal_harness (git-excluded)
└── test_helpers/                            # project-owned, git-tracked
    ├── test_make_minimal_campaign.sql       # returns a payload that
    │                                        # passes validate_campaign_fields
    └── test_insert_campaign.sql
```

The directory defaults to `test_helpers/` at the project root; override
it with `.harness.json::test_helpers.project_specific_dir`.
`harness/test_helpers/install.sh` loads every `*.sql` in it, in name
order, right after the Tier 1 functions (so on every `init.sh` run when
`test_helpers.enabled = true`). Each file should be idempotent
(`CREATE OR REPLACE FUNCTION harness_test_helpers.<name>(...)`) so
`uninstall.sh` removes it together with the schema.

Convention: name them `test_make_minimal_<table>.sql` /
`test_insert_<table>.sql` so they live next to the generic names in
the search_path without colliding. The Tier 2 helpers know the trigger
contract — e.g. `test_make_minimal_campaign.sql` returns a payload with
`objective: 'AWARENESS'`, `target_devices: ['DESKTOP']`, etc. — so
the test author can use them in place of (or layered over) the generic
functions.

Tier 2 helpers are project-owned: they live in the project's repo and
are versioned with the project. They are NOT in `personal_harness`.
