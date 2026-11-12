# Lean flow: planning a feature

Read by the planner (the leader, in the user's Claude or Codex session). The plan is the only thing
the implementer gets besides the code, so it must stand on its own.

## Gathering context (cheap)

Every tool call re-reads the whole conversation, so planning cost is mostly the number of calls.

- Start with one call: `lean/run.sh brief <name> <keyword...>` (keywords: the routes, tables, types
  or file names the request mentions). It prints the feature, these rules, the risk questions, an
  earlier plan as a format example, the docs' headings with line numbers, the project's files and
  the lines matching each keyword. Don't read `lean/README.md` or this file separately.
- Then read only what the plan needs, batched into as few calls as possible: one Bash call with
  several `sed -n '<from>,<to>p' <file>` ranges taken from the brief's line numbers. Not whole files,
  not `git show` of whole commits, not a `cat` of a file you only need a function from.
- Stop reading once you can name every file in **Files** and answer every risk question; the
  implementer reads the code again anyway. Aim for at most 3–4 calls before writing the document.

## The document: `docs/features/<name>.md`

At most about 60 lines. Start with the user's request verbatim, then these sections:

- **Decisions**: what the request does not say and how you decided it, one line each.
- **Out of scope**: what this feature must not change.
- **Files**: every file the feature creates, changes or deletes (a rename or move: both its old and
  its new path), one path per line (tests included), relative
  to the project directory (the one with `.harness.json`, even when it is a subfolder of the git
  repository: `src/x.rs`, not `backend/src/x.rs`). The gate compares this list with the files
  actually changed: name paths exactly. Its rule: a path names `<project>/<path>`; only when nothing
  is there (no file, no change) and the path starts with the project's folder in the repository
  (`git rev-parse --show-prefix`) is it read from the repository root, which still lands inside the
  project. Files outside the project directory can't be listed: changing one fails the gate.
- **Changed tests**: existing test files whose assertions must change because the feature changes
  what they pin (a format, a status, a rule), one path per line with the reason, relative to the
  project directory too; "none" otherwise.
  The gate fails on removed assertions in any other existing test file.
- **Steps**: the order of the work.
- **Risks**: answer each question in the project's risk question file (`lean/risk-questions/<list>.md`
  or the project's own), one line each, "n/a: <why>" when it does not apply. Think about who may
  read as well as who may change, and about what already exists (rows, clients, files).

## Risk mode only: acceptance tests

Then write the acceptance tests in the acceptance directory (`.harness.json::lean.acceptance_dir`,
default `acceptance/`), one file per feature, `<name>.test.<ext>`:

- Check, through the public interface, every acceptance criterion and every decision and risk answer
  that can be observed from outside (concurrency included: real concurrent requests, not mocks).
- Write them against behavior, not against names the implementer will choose.
- Don't run them: `lean/run.sh freeze <name>`, right after approval, runs them and shows which fail.
  They must fail for the right reason (the feature is missing); when freeze shows a syntax or setup
  error instead, fix the tests and ask for approval again.

Change no other file. Don't `claim` before the plan is approved, and don't read earlier reports in
`progress/` unless the brief points at one. Then the feature's plan is ready for approval (risk
mode) and for `lean/run.sh freeze <name>` (risk mode, after approval), then `lean/run.sh implement
<name>`.
