# Notion Integration (harness-owned)

Everything here is optional: it applies only when `.harness.json` has `notion_database_id` set. Every step is
best-effort — a missing token, unset id or failed request is a `[WARN]` (or `[]`), never a blocker — except
`notion-create-feature`, which must succeed before anything is blocked on it.

The token lives in the env var named by `notion_token_env` (default `NOTION_API_TOKEN`); one-time setup is in
`scripts/notion_check.sh`'s header comment. Capabilities: intake needs **Read content**, push-back needs
**Update content**, creating cards needs **Insert content**.

## Task intake (startup)

1. `scripts/harness.sh notion-check` queries the database for pages whose `Project` matches this project's
   `project_slug` and whose `Status` is `Ready`, and prints them already mapped to
   `{source_id, name, title, description, acceptance}`. It never puts Notion's raw API response into your
   context — keep it that way.
2. Pipe that through `scripts/harness.sh notion-diff` to drop anything already imported.
3. If any remain, ask the user (Claude Code: `AskUserQuestion`, multi-select) which ones to add.
4. Write the chosen ones to a temp file and run `scripts/harness.sh notion-import <file>`. This only inserts them
   as `pending`; **never claim or work on them in the same turn**.

## Status push-back (automatic)

`claim` sets a Notion-sourced feature's (one with a `source_id`) `Status` to `notion_status_in_progress`
(default `In Progress`); `log-out` sets `notion_status_done` (default `Done`); `supersede` sets
`notion_status_superseded` (default `Done`). Never call `scripts/notion_set_status.sh` directly. When the push
fails (no network in a subagent's sandbox, an HTTP error), the command prints a `[WARN]` naming
`scripts/harness.sh notion-push <N>`, which pushes the feature's current status again.

## Ad-hoc task → Notion card (with confirmation)

When a task arrives directly and no `pending` feature matches it, propose a Notion card to the user
(title/description/acceptance) before creating the local feature — writing to an external system is a visible
action. This applies only to the feature being created now, never retroactively. On confirmation:

```
scripts/harness.sh add-feature --name <slug> --title "<title>" --description "<description>" --acceptance "<item...>" [--sdd]
scripts/harness.sh notion-create-feature --project-path . --title "<title>" \
  --description "<description>" --acceptance "<acceptance>" --status Ready [--sdd]
scripts/harness.sh link-notion <slug> <page_id-from-the-previous-command's-output>
```

Pass `--sdd` to both commands or to neither: `add-feature --sdd` is what gates `claim`; the Notion flag only
ticks the card's optional "SDD" checkbox so the board matches. `link-notion` stamps `source_id`, so push-back
applies from the next `claim`. A feature created without `--sdd` that the user later wants with a spec gets
`scripts/harness.sh add-sdd <N> "<reason>"`; its card's "SDD" checkbox, if any, stays as it was. If the user declines the card, create the local feature anyway (`add-feature`
alone) — this never blocks the work.
