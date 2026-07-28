# Verification — How to prove that the feature works

> Golden rule: **the agent doesn't say "it works," it proves it**. Every feature ends with executable evidence, not just
> claims.

## Verification Levels

### Level 1 — Unit Tests (mandatory)

Every public function in `src/` has at least one test in `tests/` that:

1. Covers the successful path.
2. Covers at least one failure path if the function can fail.

Command:

```bash
python3 -m unittest discover -s tests -v
```

### Level 2 — CLI Integration Test (Required for UI Features)

Features that add commands to the CLI are verified by running the actual CLI against a temporary file:

```python
import subprocess, tempfile, os
with tempfile.TemporaryDirectory() as d:
    env = {**os.environ, "NOTES_FILE": os.path.join(d, "notes.json")}
    out = subprocess.check_output(
        ["python3", "-m", "src.cli", "add", "hola", "--body", "mundo"],
        env=env, text=True,
    )
    assert "id=" in out
```

### Level 3 — Manual Smoke Test (Optional but Recommended)

Before logging out, run a End-to-end flow with a temporary file in `/tmp`:

```bash
NOTES_FILE=/tmp/notes_demo.json python3 -m src.cli add "test" --body "x"
NOTES_FILE=/tmp/notes_demo.json python3 -m src.cli list
rm /tmp/notes_demo.json
```

## Anti-patterns (do not do)

- ❌ "I added the command, it should work." → Missing executable test.
- ❌ Test that only verifies that the function doesn't throw an exception. → It needs to check the actual result.
- ❌ Filesystem mock. → Use the real `tempfile.TemporaryDirectory()`.
- ❌ Marking the feature as `done` without passing `./init.sh`.

## Final Check Before Closing

```bash
./init.sh # must end with [OK] Environment Ready
```

If `./init.sh` is red, **do not** mark anything as `done`. Note the block in `progress/current.md` with a `blocked`
status in `feature_list.json`.
