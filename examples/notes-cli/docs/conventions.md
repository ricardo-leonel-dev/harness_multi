# Code Conventions

> Extreme homogeneity. AI predicts better when the repository looks like itself throughout.

## Python Style

- **Version:** Python 3.9+ (`list[str]` syntax allowed).
- **Format:** PEP 8. Lines maximum 100 characters.
- **Imports:** stdlib first, then locales. One line per module.
- **Strings:** Double quotes `"..."` always. Single quotes only to escape double quotes within.
- **f-strings** for interpolation. No `.format()` or `%`.

## Names

| Type                  | Convention    | Example              |
| --------------------- | ------------- | -------------------- |
| Modules               | `snake_case`  | `notes.py`           |
| Classes               | `PascalCase`  | `Note`               |
| Functions / Variables | `snake_case`  | `load_notes`         |
| Constants             | `UPPER_SNAKE` | `DEFAULT_NOTES_PATH` |
| Private               | prefix `_`    | `_atomic_write`      |

## File Structure

Each file in `src/` begins with:

```python
"""A line describing the purpose of the module."""
from __future__ import annotations

# imports stdlib
import json
import os

# imports locales
from src.notes import Note
```

## Tests

- One test file per module: `tests/test_<module>.py`.
- One `Test<Thing>(unittest.TestCase)` class per logical unit.
- Each test uses a `tempfile.TemporaryDirectory()` and cleans up after itself.
- Descriptive test names: `test_load_returns_empty_when_file_missing`.

## Error Handling

Domain exceptions in `src/notes.py`:

```python
class NoteError(Exception):
    """Base for domain errors."""

class NoteNotFound(NoteError):
    """Throws when searching for a non-existent note."""
```

The CLI catches domain exceptions, prints a message to `stderr`, and exits with code 1. It never propagates stack traces
to the user.

## Comments

By default, comments are **not** written. They are only allowed when they explain a non-obvious _why_ (e.g., documented
workaround, subtle invariant). The names should do the rest.
