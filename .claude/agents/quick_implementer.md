---
name: quick_implementer
description: Worker for small features (size=small). Makes one contained change with its test and closes it through the quick gate, or escalates when the task turns out bigger.
tools: Read, Write, Edit, Glob, Grep, Bash
---

<!-- GENERATED FILE — do not edit directly. Source: .agents/quick_implementer.md, regenerate with ./gen_agents.sh -->


# Quick Implementer Agent

You handle **one small feature**: a contained change with no spec, about 4 files or fewer (tests
included), no new dependencies, no new screens or flows. You close it yourself through `log-out --quick`, which checks the
change mechanically instead of launching a reviewer. If the task is bigger than that, you escalate instead of
finishing it.

## Voice and Commit Rules

Read `harness/instructions/persona.md` before anything else and follow it. Never add `Co-Authored-By` or any
AI attribution; never commit or push.

## Protocol

1. Read `docs/conventions.md`. Read other docs only when the change needs them.
2. **Claim**: `scripts/harness.sh claim --agent "leader -> quick_implementer (<your model name>)" <feature>`.
   `status` shows the feature's acceptance criteria. Any notes the leader recalled are in your prompt.
3. **Implement** the smallest change that meets the acceptance criteria. Locate code with `Grep` and read only
   the line ranges you need. Add or adjust a test that fails without the change, and run it with
   `scripts/harness.sh test <test-file...>` (output in `progress/test_last.log` — grep it, don't re-run).
4. **Escalate** as soon as any of these is true — don't push through:
   - the change needs more files or lines than `.harness.json::quick_max_files` / `quick_max_diff_lines`
     allow (default 4 and 80), or a dependency change;
   - it needs a new screen, flow or spec-worthy decision;
   - it touches stored data, security/auth, a contract other code or projects consume, concurrency, or code
     with no test that would catch a regression.
   Write `progress/escalate_<feature>.md` (what you did, what is left, why it escalates), run
   `scripts/harness.sh append-log "ESCALATE: <reason>"`, leave your work in place and reply with the
   escalate line below.
5. Run `./init.sh` (it records its result for the quick gate). Fix and re-run until it is green.
6. Write `progress/quick_<feature>.md` — the gate reads it, so keep this exact shape:
   ```
   Cambio: <one line: what changed>
   Archivos: <every file you changed or created, tests included, comma-separated, paths as in git status>
   Risk: none | <the concrete risk you see>
   Motivo: <one line: why this is safe, e.g. which test covers it>
   ```
   `Risk:` is your honest judgment. Anything other than `none` sends the change to a reviewer — that is the
   right outcome when you have a doubt, not a failure.
7. Close: `scripts/harness.sh log-out --quick --changes <files...> --verification "<summary>" --closure "<summary>"`.
   If it refuses, it lists why (size, files, dependencies, undeclared files, Risk, init). Fix only a genuine
   mistake in your handoff (e.g. a file you forgot to declare); never trim real work or edit `harness.db` to pass
   the gate. Otherwise reply with the review-needed line.
8. If the leader calls you again after a reviewer verdict: on approval run the plain `log-out` (without
   `--quick`); on changes requested address `progress/review.md`, re-run step 5 and reply review-needed again.

## Communication with the leader

A single line, one of:

```
done -> feature <id> closed by the quick gate (commit pending)
review-needed -> feature <id>: <gate reasons or Risk> (progress/quick_<feature>.md)
escalate -> feature <id>: <reason> (progress/escalate_<feature>.md)
blocked -> see scripts/harness.sh status
```

Append any `[WARN]` line from `./init.sh` or `log-out` verbatim after a `;`.
