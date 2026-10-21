# Feature Lifecycle Details (harness-owned)

## Local feature dependencies

A feature can require other features in this same project to be `done` first: `add-feature ... --depends-on
<name...>` at creation, or `scripts/harness.sh set-depends-on <target> <name...>` later (each name must already
exist; no names clears the list). `import-features`/`notion-import` accept an optional `"depends_on": [name...]`
per item. `claim` refuses — for an explicit target and for the "lowest pending" default alike — while any
dependency isn't `done`, naming the outstanding ones.

A description saying "depends on X" is prose nothing reads; record it with `depends_on` whenever a feature
genuinely can't be implemented (not just "is nicer after") without another landing first. Otherwise the single
open session can get stuck on a feature that can never finish. This is separate from the cross-project
`block`/`check-blockers` mechanism (`harness/instructions/cross-project.md`).

## Log out

1. Run `./init.sh` — verification passes under the accepted policy (`harness/instructions/testing.md`). It also
   regenerates `state/` and best-effort syncs the Postgres/Supabase mirror. Accepted `[STALE]` failures stay
   documented; passing with a baseline does not mean every historical test is green.
2. If the task is finished:
   ```
   scripts/harness.sh log-out --changes <file1> <file2> ... --verification "<summary>" --closure "<summary>"
   ```
   This closes the session and marks the feature `done`; the closed session *is* the history entry. `log-out`
   refuses unless a `reviewer` already ran `scripts/harness.sh record-review approved` on this session, and
   unless both that approval and the last `./init.sh` of the session saw exactly the files being closed (a
   change after the approval goes back to the reviewer; one after `./init.sh` needs another run). Both compare
   file contents, so committing the approved code doesn't invalidate them.
3. Leave no temporary files, debug prints, or TODOs without context.

## Reconciling work implemented outside the harness

Trigger: you're told (or discover) a feature is effectively finished — shipped, merged — but `status` shows no
open session for it. The review gate never ran, so it has had **zero** spec-conformance checking. Before marking
it `done`:

1. **Read the actual shipped code** — the real diff, not a PR description, commit message or another session's
   summary. Self-reports describe intent, not what happened.
2. **Diff it against the ground truth**: `specs/<name>/{requirements.md,design.md}` for `sdd=1`, or the feature's
   `description`/`acceptance` for `sdd=0`. Check the actual shape (input names, optional vs. required, scope of
   a change), not just whether it "looks right".
3. **Document every deviation**, even ones that seem cosmetic, in the session log (step 5).
4. **If a deviation would break a dependent feature** (one listing this one in `depends_on`), propose a follow-up
   feature to the user (ad-hoc flow; Notion if configured), and once created add it as an *additional*
   `depends_on` (`set-depends-on`, keeping existing entries) on every feature that needs the fix first.
5. Then reconcile: `claim` the feature, `append-log` what you verified and every deviation (reference the real
   commits/PR), `record-review approved` attributed to whoever accepts the shipped state (`--by 'human:<name>'`
   for a literal human, or omit `--by` to auto-attribute), run `./init.sh`, then `log-out` referencing the real
   commits/PR.

This is a one-time reconciliation, not an alternate lifecycle: future work on the feature goes through
`claim`/`record-review`/`log-out` normally.

## Notes outside a session, and absorbed features

- `scripts/harness.sh append-log --feature <target> "<note>"` writes a feature-level note when no session is open
  (e.g. after `mark-spec-ready`); `state/features/` shows them.
- When one feature's scope is fully covered by another, don't `delete-feature` it — propose to the user, then
  `scripts/harness.sh supersede <target> --by <other> --reason "<why>"` (only `pending`/`spec_drafting`/
  `spec_ready` with no open session). It records the reason, pushes `notion_status_superseded` if linked, and is
  reversible with `unsupersede <target> <reason>`. Fix any `depends_on` it warns about.

## If you get stuck

Syntax errors, generator errors and failing assertions in your own code/tests are normal iteration: inspect,
fix, rerun the affected check — don't pause for them. A genuinely unavailable tool, external service, permission
or unsafe environment is a blocker: never work around it or the reviewer gate. Reread the relevant `docs/`;
if still blocked, `append-log "<what's blocking you>"` and `set-next-step`, then end without logging out (the
feature stays `in_progress` with its session open for the next run).
