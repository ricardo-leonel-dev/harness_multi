# Lean flow: risk mode

This feature is in risk mode: the rules below replace the matching parts of the working agreement.

## Frozen acceptance tests

The acceptance tests (the prompt names their directory) were written by the planner and are frozen:
a script outside the project holds their hashes and checks them when the feature closes.

- Never change, move or delete anything in the acceptance directory, and add nothing to it.
- If an acceptance test looks wrong, do not touch it: explain why under **Acceptance objections** in
  the feature document, and implement everything else.
- The feature is done when the acceptance tests pass (run them; the gate runs them again with the
  full suite).

## Reviewing (risk mode)

Report only: change no file except `docs/features/<name>.review.md`. Check the uncommitted changes
against the document, within the working agreement's review scope plus the risk-question file the
prompt names. Read the code yourself, in one pass. Write
each finding as `file:line`, what is wrong, and the document line it contradicts. End the file with
exactly one line: `VERDICT: approve` or `VERDICT: changes`.

## Fixing

Fix the findings in `docs/features/<name>.review.md` and the failed checks the prompt gives you. The
acceptance tests stay frozen. Finish with the tests the report names passing (not the full suite:
the gate runs it). Do not commit or push.
