# Verification, Test Runs and Budgets (harness-owned)

## Verification policy

A feature is never `done` without passing verification (`./init.sh` and the verify command). Ordinary green tests
are required unless the project explicitly accepts an applicable PostgreSQL baseline captured before changes:
then active feature/changed relevant tests must pass without suppression, the reviewer independently confirms
zero new regressions with `--all --baseline`, and remaining pre-existing `[STALE]` failures are documented. Never
widen a baseline to absorb new failures. See `harness/instructions/postgres.md`; project-owned checkpoints that
conflict need explicit local alignment.

## Verification effort

Use the smallest existing fixtures and checks that prove the approved behavior. One check may cover several
requirements; don't build a new test framework or expand unrelated coverage just to fill a traceability table.
Required project gates and independent review still apply.

Before creating deliverables, inspect `git status --short --untracked-files=all` and
`git check-ignore -v -- <planned paths>`. Tell harness-owned local exclusions apart from project-owned delivery
requirements; don't remove exclusions or change `.gitignore` merely to make status show a file. Resolve conflicts
against the project's delivery policy early.

Each role runs its required verification, but a command already run by that role's `./init.sh` need not run again
against the same inputs/environment. The leader never adds a third verification pass. On re-review, the reviewer
may reuse its own earlier passing behavioral evidence only after checking that code, tests, dependencies,
verification config and environment are unchanged; rerun what the revision affects. Required `./init.sh` runs and
stricter project checkpoints stay mandatory.

## Test runs

- **Targeted:** `scripts/harness.sh test <file...>` runs only those files via
  `.harness.json::test_targeted_command` (`{files}` = the quoted paths; `{files:FLAG}` repeats FLAG per file, e.g.
  `bunx ng test --watch=false {files:--include}`; when setting it, check with two files — a wrong form often
  passes with one), falling back to `verify_command`. Output goes to `progress/test_last.log`; only the result
  and the failure tail are printed.
- `./init.sh` runs the full suite once the same way. Grep the log — never re-run a suite just to read its output.

## Budgets

- **Review budget (advisory):** `log-out` logs `DIFF: code=N, tests=M` for its `--changes` since the claim
  (commits included) and warns when production code exceeds `review_budget_lines` (default 400; 0 disables).
  It never blocks.
- **Token budget (optional):** with `token_quota` set, `record-usage` (and so `./init.sh`) warns once the active
  feature's tokens reach `token_warn_percent` (default 15) of it; the leader tells the user before going on.

## Timing

When timing is requested, follow `harness/instructions/timing.md`. `scripts/harness.sh record-usage` stores each
agent invocation's interval and tokens (`./init.sh` runs it unless `.harness.json` sets `record_agent_usage` to
false); `scripts/harness.sh stats` reports them. Session start-to-close is elapsed time, not active work; never
subtract an unexplained gap as a confirmed pause or sum overlapping agents as user-visible elapsed time. Report
missing evidence rather than inventing precision.
