# Lean flow: planning a feature

Read by the planner (the leader, in the user's Claude or Codex session). The plan is the only thing
the implementer gets besides the code, so it must stand on its own.

## The document: `docs/features/<name>.md`

At most about 60 lines. Start with the user's request verbatim, then these sections:

- **Decisions**: what the request does not say and how you decided it, one line each.
- **Out of scope**: what this feature must not change.
- **Files**: every file the feature creates or changes, one path per line (tests included). The gate
  compares this list with the files actually changed: name paths exactly.
- **Changed tests**: existing test files whose assertions must change because the feature changes
  what they pin (a format, a status, a rule), one path per line with the reason; "none" otherwise.
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
- Run them once: they must fail now, for the right reason (the feature is missing), not because of a
  syntax or setup error.

Change no other file. Then the feature's plan is ready for approval (risk mode) and for
`lean/run.sh freeze <name>` (risk mode, after approval), then `lean/run.sh implement <name>`.
