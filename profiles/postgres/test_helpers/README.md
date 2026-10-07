# Generic Postgres Test Helpers

Six PL/pgSQL functions installed into schema `harness_test_helpers` of a
project's dev/test database. They are **completely generic** — no project
schema, trigger, or category names are hard-coded — so they work for any
postgres project that uses `install.sh --profile postgres`.

The bundle is project-owned: `install.sh` copies it into
`<project>/harness/test_helpers/`, and `init.sh` installs it conditionally
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

- creates a `LIKE ... INCLUDING ALL EXCLUDING TRIGGERS` copy
- clones sequences attached to serial columns and rewires the column
  defaults to point at the new sequences
- re-creates every in-schema foreign key (FKs pointing outside
  `p_source_schema`, e.g. `public.countries`, are left pointing at the
  original — a deliberate trade-off)
- discovers and rebinds every trigger on the copied tables: each
  trigger's function body is moved into the tenant schema with a
  `SET search_path TO <tenant>, public`, and dictionary references are
  rewritten to point at the tenant's dictionary copy

If `p_dictionary_table` is non-NULL the named dictionary table is also
cloned into the tenant, populated with rows whose `category` is in
`p_dictionary_categories` (or all rows if NULL).

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

Companion to function 1. `DROP SCHEMA IF EXISTS <p_tenant> CASCADE`.
Idempotent and unconditional — useful in `ROLLBACK` blocks where you
also want to remove any leftover state.

### 3. `test_make_minimal_row`

```sql
harness_test_helpers.test_make_minimal_row(
    p_schema text,
    p_table text,
    p_extras jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
```

Introspects every `NOT NULL DEFAULT-less column` of `<schema>.<table>`
and emits a JSONB object with a stub value for each. `p_extras` is merged
on top so the caller can override any field.

Stub values: arrays → `[]`, jsonb/json → `{}`, numeric → `0`, text →
`'test_value'`, timestamp → `'1970-01-01 00:00:00'`, date →
`'1970-01-01'`, uuid → fresh `gen_random_uuid()`, enum → first
`enumsortorder` label.

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

Builds the row-type dynamically from `information_schema.columns` and
runs `INSERT INTO <schema>.<table> SELECT ... FROM jsonb_to_recordset($1)`.
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

The function assumes the table has a PRIMARY KEY or UNIQUE constraint
covering at least `(code, category)`. Projects whose dictionary uses a
different uniqueness rule should write a per-table Tier 2 helper.

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

`uninstall.sh` drops schema `harness_test_helpers CASCADE`. Production
DBs were never touched — the schema only exists on the DB your
`verify_command` runs against.

## Limitations

- **FKs to tables outside `p_source_schema` are not copied.** If
  `rushr_ec.assets.country_id` references `public.countries.id`, the
  tenant references the original `public.countries` table directly. This
  assumes the global catalogue is shared, which is the common case.
- **Triggers with side effects outside the source schema are not
  isolated.** A trigger that writes to a different schema (e.g. an
  audit-log table in `public.audit`) will still write there when fired
  in the tenant. Use Tier 2 for those tables.
- **Trigger rebinding only handles triggers named in pg_trigger.**
  Triggers defined on views (`INSTEAD OF`) and event triggers are out
  of scope. Triggers on partitioned tables work — the function copies
  them onto the leaf partitions of the LIKE copy.
- **`test_make_minimal_row` does not try to be smart about trigger
  validation.** See function 3's docstring.
- **`test_seed_dictionary_entries` requires `(code, category)` to be in
  a unique constraint.** Other uniqueness shapes → Tier 2.

## Extending with per-table helpers (Tier 2)

Projects whose tables have unusual constraints (complex triggers,
domain-specific NOT-NULL checks, etc.) can write their own per-table
helpers alongside this one:

```
<project>/harness/test_helpers/
├── install.sql                              # from personal_harness
├── install.sh                               # from personal_harness
├── README.md                                # from personal_harness
└── project_specific/                        # project-owned, git-tracked
    ├── test_make_minimal_campaign.sql       # returns a payload that
                                             # passes validate_campaign_fields
    └── test_insert_campaign.sql
```

The project's install/uninstall scripts load these after the Tier 1
ones. Convention: name them `test_make_minimal_<table>.sql` /
`test_insert_<table>.sql` so they live next to the generic names in
the search_path without colliding. The Tier 2 helpers know the trigger
contract — e.g. `test_make_minimal_campaign.sql` returns a payload with
`objective: 'AWARENESS'`, `target_devices: ['DESKTOP']`, etc. — so
the test author can use them in place of (or layered over) the generic
functions.

Tier 2 helpers are project-owned: they live in the project's repo and
are versioned with the project. They are NOT in `personal_harness`.