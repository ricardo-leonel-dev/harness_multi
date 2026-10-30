# Lean flow: working agreement

You are one session of a feature that several sessions work on in turn: planning, implementing,
reviewing. Everything you need is in the feature document `docs/features/<name>.md` (the prompt names
it). Do not look for other instructions, and do not look for the checks: a script outside the
project runs them when the feature closes.

## The feature document

- **Decisions**: what the request does not say and how it was decided.
- **Out of scope**: what this feature must not change.
- **Files**: every file the feature creates or changes, one path per line, tests included.
- **Changed tests**: existing test files whose assertions must change because the feature changes
  what they pin, one path per line with the reason; "none" otherwise.
- **Steps**: the order of the work.
- **Risks**: one answer per risk question (the prompt names the question file).

## Implementing

- Follow the document. When you must decide something it does not cover, decide, and append it to a
  **Decisions while implementing** section of the document.
- Do not delete or weaken existing tests. When the feature changes what an existing assertion pins,
  update that assertion to the new behavior and list its file under **Changed tests** with the reason.
  Add tests for what the feature changes.
- Change only the files listed under **Files**. If another one is truly needed, add it to that list
  with a short reason.
- Finish with the full test suite passing. Do not commit or push.

## Reviewing

Compare the uncommitted changes (`git status`, `git diff`, new files) with the document: every
decision implemented, every answer under **Risks** true in the code, nothing out of scope touched,
tests covering the change. Fix what is wrong or missing, once, then stop with the suite passing.

Keep the review to one pass: read the code yourself (no subagents), do not run tests in loops or in
the background, and run the full suite once at the end.
