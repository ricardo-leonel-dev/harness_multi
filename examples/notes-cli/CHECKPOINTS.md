# CHECKPOINTS — Final State Evaluation

> In multi-agent systems, the path is not evaluated; the destination is. These are the objective checkpoints that a
> judge (human or AI) can use to decide if the project is healthy.

## C1 — The harness is complete

- [ ] The 4 base files exist: `AGENTS.md`, `init.sh`, `feature_list.json`, `progress/current.md`.
- [ ] The 3 docs exist: `docs/architecture.md`, `docs/conventions.md`, `docs/verification.md`.
- [ ] `./init.sh` ends with exit code 0.

## C2 — The state is consistent

- [ ] At most one feature in `in_progress` in `feature_list.json`.
- [ ] Every `done` feature has associated tests that pass.
- [ ] `progress/current.md` is empty or describes the active session (it does not contain garbage from previous
      sessions).

## C3 — The code respects the architecture

- [ ] `src/` only contains the modules specified in `docs/architecture.md`.
- [ ] There are no external dependencies in `requirements.txt` (it must be empty or not exist).
- [ ] There are no loose `print()` statements for debugging, nor TODOs without context.

## C4 — The verification is real

- [ ] `tests/` has at least one test per module in `src/`.
- [ ] The tests use `tempfile.TemporaryDirectory()`, not mocks of function files.
- [ ] `python3 -m unittest discover -s tests -v` returns > 0 tests and all are green.

## C5 — The session closed successfully

- [ ] No suspicious untracked files (`*.tmp`, `__pycache__` outside of `.gitignore`).
- [ ] `progress/history.md` has one entry for the last session.
- [ ] The last feature worked on is reflected in its correct state.

--

**How to use this file:** A reviewer agent (`.claude/agents/reviewer.md`) iterates through each checkbox, marks `[x]` or
`[ ]`, and rejects the session closure if there are any empty boxes in C1-C5.
