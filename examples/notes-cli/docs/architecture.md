# Architecture — What does "doing a good job" mean?

> This document defines the quality standard. Reviewers evaluate code against this file. If it's not here, it's not a
> requirement.

## Principles

1. **Clear Layers.** The project has three layers and only three:
   - `storage.py` — persistence (JSON on disk).
   - `notes.py` — domain model (`Note`).
   - `cli.py` — user interface (argparse). Do not introduce additional layers (services, repositories, ORMs) until there
     is a concrete reason documented in `feature_list.json`.
2. **No External Dependencies.** Only Python stdlib. If a feature requires a dependency, it is discussed first (status
   `blocked`).
3. **Explicit Errors.** Functions that can fail (id doesn't exist, corrupt file) throw named exceptions, not `None`.
4. **Default Immutability.** `Note` is a `@dataclass(frozen=True)`. Modifying it creates a new instance.
5. **Disk Atomicity.** All writes to `notes.json` are first written to a temporary file and then replaced with
   `os.replace()`. Never leave the file partially written.

## Data Flow

```
user ─→ cli.py (argparse)
         │
         ├─ construct Note with notes.Note.new(...)
         │
         └─→ storage.load() / storage.save()
                 │
                 └─→ .notes.json (in CWD)
```

## What NOT to do

- Don't use `print()` for errors. Use `sys.stderr` and exit code != 0.
- Don't mix I/O with domain logic inside `notes.py`.
- Don't read/write the file in every operation within a loop. Load at the beginning, modify in memory, save at the end.
- Don't add a configuration system. The file path is passed explicitly or use the default constant.
