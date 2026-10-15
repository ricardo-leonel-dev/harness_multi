# Optional closure timing

This harness-owned guide and `scripts/time_phase.py` are refreshed on reinstall.
Timing is opt-in; no command is inserted into the normal lifecycle, and no
verification or reviewer gate is removed. Python 3 is required only when used.

Run each explicit command with a fixed phase name:

```sh
python3 scripts/time_phase.py --phase evidence --log progress/closure_timing.jsonl -- python3 scripts/build_evidence.py
python3 scripts/time_phase.py --phase init --log progress/closure_timing.jsonl -- ./init.sh
# Implementer only, after recorded reviewer approval; replace placeholders:
python3 scripts/time_phase.py --phase logout --log progress/closure_timing.jsonl -- scripts/harness.sh log-out --changes FILE --verification SUMMARY --closure SUMMARY
```

The wrapper executes argv directly (no shell/eval), inherits child stdout/stderr,
and appends one JSON event to stdout and optionally to the chosen local JSONL
file. It records only the phase (`evidence`, `init`, `logout`), UTC start/end,
monotonic elapsed seconds and actual exit status. Commands, arguments, environment
and output are never copied into the event. Child output can still contain secrets,
just as without timing: follow the project's normal command/output handling.
Use a project-local excluded log (for example `progress/closure_timing.jsonl`);
the wrapper does not change Git excludes or write harness session state.

Child failures remain failures. Missing executables return 127, execution errors
126, and interruption/signal status uses 128 + signal. If the optional log cannot
be opened, the command is not run; if writing after execution fails, a warning is
printed and the command's status is preserved. Timing is evidence, not a success
substitute. This measures each invoked command, not unwrapped preparation or agent
execution time; agent launch/finish comes from `record-usage` (below).


## Agent intervals and waits

Agent intervals and token usage are recorded in `harness.db` (`agent_runs`) by
`scripts/harness.sh record-usage` (`scripts/agent_usage.py`, Python 3 stdlib). It reads Claude
Code transcripts and Codex CLI rollouts for this project and upserts one row per invocation —
leader/main session (depth 0), implementer, reviewer (every pass), spec_author and any nested
spawn — with role, label, parent/spawn depth, model, start/end, duration and input/cache/output/
reasoning/total tokens. Only numbers, ids, timestamps and the source path are stored, never
transcript content. Each run is attributed to the harness session whose window contains its
start (else the one it overlaps most; else none). It is idempotent and best-effort: parse
problems are `[WARN]`s and it always exits 0.

- Both runtimes: `./init.sh` runs it on every invocation (start of session, before declaring
  work done, and from the Claude Code `Stop` hook), before the snapshot and the Postgres/Supabase
  mirror sync, so both always see fresh `agent_runs`. It uses the default `--since` window, prints
  one `[OK]`/`[WARN]` line and never changes init's exit status. Opt out with
  `"record_agent_usage": false` in `.harness.json` (default true).
- Claude Code: the installed `SubagentStop` hook (`.claude/settings.json`) also runs it after each
  subagent with that subagent's and the leader's transcript paths.
- Codex CLI has no such hook: `./init.sh` covers it; the leader may still run
  `scripts/harness.sh record-usage` after each subagent and before its final report (idempotent).

`scripts/harness.sh stats [TARGET]` prints the invocation tree (parent -> children) per feature
with per-run duration/tokens and totals, plus summed agent effort, the union of agent intervals,
the agent span and the session elapsed time (claim -> log-out). `state/features/*.md` shows the
same runs under "Agent usage". Token columns: `input_tokens` is uncached input, cache read/write
are separate, `output_tokens` includes reasoning (`reasoning_tokens`, Codex only, is a subset)
and `total_tokens` = input + cache read + cache write + output. A transcript's duration is first
to last recorded event, so it includes that agent's own waits (tool runs, approvals).

When the user requests timing, the leader still records handoff times and explicit waits in
the feature handoff or a project-local excluded log, and the implementer/reviewer record the
commands above with their actual exit statuses; `record-usage`/`stats` provide the agent
intervals. Use the existing claim-time budget and compare it against observed work intervals;
elapsed session time alone is not a reason to interrupt an agent after a long external wait.

For an explicit wait (human approval, permission, unavailable service or execution suspension),
record its start/end and reason when known. A gap discovered later is an unknown interval unless
there is evidence of its cause; show it separately instead of declaring it inactive work.
If execution resumes after an interruption, record the resume time and preserve prior evidence.

Report session elapsed time, the union of observed agent intervals, documented waits and command
durations separately. Overlapping roles are counted once in elapsed time; their summed durations
are agent effort, not user waiting time. Command timings are nested within agent intervals and
must not be added again. Observed intervals include reasoning, tools and coordination; they do
not measure CPU time. Session claim can occur after startup, and close can precede the final reply;
state those bounds. Do not claim savings until comparable runs have actually been measured.
