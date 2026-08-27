# Design — cli_export

## Files touched

- `src/cli.py` — new `cmd_export(args: argparse.Namespace) -> int` and a new `export` subparser
  (positional `path` argument).
- No changes to `src/notes.py` or `src/storage.py` — `storage.load()` already returns the full list of
  `Note` objects; export only needs to serialize what it returns.

## Approach

1. `cmd_export` calls `storage.load()` to get every `Note`.
2. If `os.path.exists(args.path)` (R2): print an error to stderr, return a non-zero exit code, and stop
   before touching the file at all.
3. Otherwise, serialize each `Note` via `dataclasses.asdict()` into a list, `json.dump()` it to
   `args.path` — following `docs/architecture.md`'s disk-atomicity rule (write to a temp file, then
   `os.replace()`), same as `storage.py` already does for its own writes, even though this file isn't
   `notes.json` itself.
4. Empty note list (R3) serializes to `[]` naturally — no special case needed in code, just a test to
   confirm it.

## Discarded alternative

Considered reusing `storage.py`'s internal atomic-write helper directly for the export file too (not
just conceptually following its pattern). Rejected: `storage.py`'s writer is scoped to the fixed
`notes.json` path and its specific `Note`-list format; parameterizing it for an arbitrary path invites
`cli.py` to reach into `storage.py` internals for something that's really a CLI-layer concern (dumping
already-loaded domain objects to a user-chosen file), not a storage-layer one. A short, local
temp-file-then-`os.replace()` sequence in `cmd_export` itself keeps the layer boundary from
`docs/architecture.md` clean instead.

## Risks / notes

- `dataclasses.asdict()` on a frozen `Note` is safe and doesn't require special handling — no cycles,
  no non-serializable fields.
