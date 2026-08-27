# Requirements — cli_export

## R1
WHEN the user runs `python -m src.cli export <path>`, the system SHALL write every note in storage to
`<path>` as a single JSON array, each element having the same fields as `Note`.

## R2
IF `<path>` already exists THEN the system SHALL exit with a non-zero exit code and SHALL NOT modify
the existing file.

## R3
WHEN there are no notes in storage, the system SHALL write an empty JSON array (`[]`) to `<path>` and
exit with code 0 — exporting "nothing" is not an error.

## R4
IF the export command is run without a `<path>` argument THEN the system SHALL exit with a non-zero
exit code and SHALL print a usage message to stderr.

---

## Traceability to original acceptance criteria

| Original acceptance bullet | Covered by |
|---|---|
| `python -m src.cli export <path>` escribe todas las notas como un array JSON en `<path>` | R1, R3 |
| Si `<path>` ya existe, exit code != 0 y no sobreescribe el archivo | R2 |
| tests/test_cli.py cubre: export exitoso y export contra un path existente | R1, R2 |

R4 was added during drafting — the original acceptance criteria didn't cover the missing-argument
case, but `docs/conventions.md`'s argparse conventions require every subcommand to fail loudly on
missing required arguments, so it's included for consistency with `cli_edit`/`cli_recent`.
