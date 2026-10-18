# Cross-Project Dependencies (harness-owned)

Use this when a feature here needs work in a *different* sibling project that has its own harness (e.g. a backend
feature that needs a new table in a separate database project). There is no way to start work in another
project's `harness.db` directly — the request goes through Notion, the same board `notion-check`/`notion-import`
read from (see `harness/instructions/notion.md`).

1. **Propose before creating anything.** Ask the user (Claude Code: `AskUserQuestion`) with the target project's
   directory, a title, a description and acceptance criteria. Creating external content and blocking your own
   work on it is a visible action, never autonomous.
2. **On confirmation**, create the card:
   ```
   scripts/harness.sh notion-create-feature --project-path <absolute path to the target project's directory> \
     --title "<title>" --description "<description>" --acceptance "<acceptance>"
   ```
   **Always `--project-path`, never a hand-typed `--project <slug>`**: it reads the target's real `project_slug`
   from its `.harness.json`. A guessed slug creates a card that looks fine but the target's `notion-check` never
   matches, and the mismatch stays invisible. It prints `{"page_id", "url", "predicted_name"}` —
   `predicted_name` is the `name` the feature will get once the target imports it. If it fails, the card was
   not created: do not block anything on it.
3. **Block the current feature** with a note `check-blockers` can parse:
   ```
   scripts/harness.sh block <current-feature> "waiting on <target-project-slug>: BLOCKED_ON: path=<absolute path \
     to the target project's directory> feature=<predicted_name> notion_page=<url>"
   ```
   The feature becomes `blocked` and its session is **paused**: log, plan and any review verdict stay intact, but
   it no longer holds the single session slot, so other features can be claimed meanwhile.
4. Report what was created and that the feature is blocked, then end the session.
5. The user moves the card to `Ready` when work should start there; the target project's normal
   intake/claim/log-out flow picks it up and pushes `Status=Done` back.
6. **Resuming** happens on your next session here: startup runs `scripts/harness.sh check-blockers`, which reads
   each `BLOCKED_ON` note and queries the target's `harness.db` directly (not Notion). If the dependency is
   `done`, run `scripts/harness.sh unblock <feature>` and continue (it refuses while another session is active —
   finish or block that one first); otherwise report its status and work on something else.

**A feature that lost its session.** If a `blocked` or `in_progress` feature has no open session (e.g. after
`cancel-session --force`), `unblock` refuses — it only resumes sessions. Run `scripts/harness.sh claim <feature>`
with the feature named explicitly: it opens a new session and logs `RESUMED: previous session <id> was
cancelled`. Review verdicts don't carry over, so the `reviewer` must `record-review` again before `log-out`. Never
use `cancel-session --force` just to free the slot — `block` does that without discarding anything.

There is deliberately no background polling: resuming is tied to opening a session in this project again.
