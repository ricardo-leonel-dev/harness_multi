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
