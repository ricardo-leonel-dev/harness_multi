# Lean flow: working agreement

You are one session of a feature that several sessions work on in turn: planning, implementing,
reviewing. Everything you need is in the feature document `docs/features/<name>.md` (the prompt names
it). Do not look for other instructions, and do not look for the checks: a script outside the
project runs them when the feature closes.

## Boundaries

- Read the feature document, the files under **Files**, the code and tests they touch, and the
  project's own docs (`docs/architecture.md`, `docs/conventions.md`, ...) when you need them.
- Do not read the harness or other features' work: `lean/`, `harness/`, the harness's own scripts
  (`scripts/harness.sh`, `scripts/lib.sh`, `scripts/snapshot.sh`, `scripts/sync_postgres.sh`,
  `scripts/notion_*.sh`), `init.sh`, `.harness.json`, `progress/`, `state/`, `~/.cache`, `specs/`,
  other `docs/features/` documents. Nothing there is for this step, except a file the prompt names
  (the risk-question file). The files under **Files**, and the code and tests they touch, are
  always fine to read, wherever they are (the project's own `scripts/` included).
- Do not run `./init.sh`, `lean/gate.sh`, `scripts/harness.sh` or the full test suite: the gate
  runs them after your session, outside it, and they refuse to run inside it
  (`LEAN_GATE_UNSANDBOXED` has no effect here). Run the feature's own tests and targeted checks
  (the test files you add or change, a type check or lint of the changed files).

## The feature document

- **Decisions**: what the request does not say and how it was decided.
- **Out of scope**: what this feature must not change.
- **Files**: every file the feature creates, changes or deletes (a rename: both paths), one path per
  line, tests included.
- **Changed tests**: existing test files whose assertions must change because the feature changes
  what they pin, one path per line with the reason; "none" otherwise.
- **Steps**: the order of the work.
- **Risks**: one answer per risk question (the prompt names the question file).
- **Leader actions** (a `## Leader actions` section, often absent until a session adds it):
  what only the leader or the user can do, one `- [ ] ...` item per line.

## Leader actions

Anything the feature needs that you can't or must not do yourself goes in the document's
`## Leader actions` section (add it at the end when it is missing), one `- [ ] <what and why>`
item per line: a change to harness config (`.harness.json`, such as `verify_command` or
`lean.acceptance_command` so the new tests run), a dependency to install, environment setup, a
file outside **Files** you needed, existing data a migration or test stumbled on. Never only in
prose elsewhere (**Decisions while implementing**, your final message): the leader reads that
section before closing, and the feature can't close while an item is open. Never check an item
off (`- [x]`) or remove one, yours or another session's: only the leader does, once it is done.
Keep the heading exactly `## Leader actions` (no other words in it: a heading or bullet naming
**Files** reads as that list) and each item one top-level `- [ ]` line, details indented below it;
code in a fenced block.

## Implementing

- Follow the document. When you must decide something it does not cover, decide, and append it to a
  **Decisions while implementing** section of the document.
- **Files** and **Changed tests** are fixed: the checks read them as the planner wrote them, and
  fail on any path you add to or remove from them. Do not edit those two lists (other sections,
  such as **Decisions while implementing**, are fine to append).
- Do not delete or weaken existing tests. When the feature changes what an existing assertion pins,
  update that assertion to the new behavior only in a file listed under **Changed tests**. Add tests
  for what the feature changes.
- Change only the files listed under **Files** (a file you delete or rename, both paths, counts). If
  another file is truly needed (or an assertion in a test file not under **Changed tests** must
  change), do not change it: add it to **Leader actions**, with the file and why, and finish the
  rest. The leader decides whether the plan grows.
- Never delete, rewrite or migrate existing rows in a database by hand (`psql`, scripts, ad hoc
  SQL), even local ones: only the migrations and tests the feature adds may change data. When
  existing data stops a migration or a test, stop and add it to **Leader actions**, with the query
  that finds the rows; the user decides.
- Finish with the feature's own tests passing (the gate runs the full suite). Do not commit or push.

## Reviewing

Review only the change: the diff against the base the prompt gives (`git diff <base>`, plus the
untracked files `git status --short` lists), the files under **Files** and the document itself. Check
every decision implemented, every answer under **Risks** true in the code, nothing out of scope
touched, tests covering the change. Fix what is wrong or missing, once, in the files under **Files**,
then stop. Leave the document as it is, except **Leader actions** (risk mode: in the review
report instead, never in the document): **Files** and **Changed tests**
are fixed, so a fix that needs another file is not made; add it to **Leader actions**, with the
file and why, as anything else only the leader or the user can do.

Keep the review to one pass: read the code yourself (no subagents), and run the feature's own tests
at most once at the end, not in loops, in the background or as the full suite (the prompt holds the
gate's results; it runs again after you).
