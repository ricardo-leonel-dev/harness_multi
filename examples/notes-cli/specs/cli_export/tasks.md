# Tasks — cli_export

- [ ] T1 (R1, R4) Add `cmd_export` and register the `export` subparser (positional `path`) in `src/cli.py`.
- [ ] T2 (R2) Add the existing-file check with atomic temp-file + `os.replace()` write.
- [ ] T3 (R3) Confirm empty-storage export writes `[]` (no special-case code, just verify behavior).
- [ ] T4 (R1) Add `test_export_writes_all_notes` in `tests/test_cli.py`.
- [ ] T5 (R2) Add `test_export_existing_path_fails` in `tests/test_cli.py`.
- [ ] T6 (R3) Add `test_export_empty_storage` in `tests/test_cli.py`.
- [ ] T7 (R4) Add `test_export_missing_path_arg` in `tests/test_cli.py`.
