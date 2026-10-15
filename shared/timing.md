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
execution time; record agent launch/finish separately for a full wall-clock view.


## Agent intervals and waits

When the user requests timing, the leader records each invocation's role, UTC start/end and
handoff time in the feature handoff or a project-local excluded log. The implementer/reviewer
record the commands above with their actual exit statuses. No new harness DB fields are needed.
Use the existing claim-time budget and compare it against observed work intervals; elapsed
session time alone is not a reason to interrupt an agent after a long external wait.

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
