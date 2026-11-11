#!/usr/bin/env bash
# chain.sh — `lean/run.sh chain <name>`: every step of the lean flow, headless, in one call,
# with a short summary. Sourced by run.sh (after the document check), not executed.
#
# Each step runs as its own `run.sh <step> <name> --headless` process, so it keeps its own
# checks (document, trusted hashes, pin, sandbox). Order:
#   normal: implement -> review (may fix once) -> gate -> [fix -> gate when the gate fails]
#   risk:   freeze -> implement -> review (verdict) -> [gate] -> fix (verdict `changes` or
#           gate failed) -> gate
# Risk mode needs the frozen manifest (approve-plan, or freeze by hand without the harness);
# with the harness, a feature whose plan approval is pending is refused before any step.
# Stops at the first failure: a step exiting non-zero or past its time cap, a session whose
# result JSON is missing or says is_error, a risk review without a VERDICT line or one that
# changed files. Fix runs at most once. Never logs out: the caller runs
# `scripts/harness.sh log-out --lean` itself (its own gate run is the suite run it needs).
#
# Output: one line per step (result, duration, turns and cost from the result JSON), the final
# gate's headings only, where the full logs are, `git status --short`, the feature's usage
# table (the sessions this chain opened, a sum over them, and how many earlier ones
# `run.sh usage <name>` shows: lean/lib.sh lean_usage_table), on PASS with
# scripts/harness.sh present a `next:` line holding the log-out --lean command to run (its
# --changes: the files the gate checked, lean/lib.sh lean_repo_changes, relative to the
# project, quoted for the shell, progress/ and state/ left out; only --closure to fill in),
# and a last line `CHAIN: PASS` or `CHAIN: FAIL at <step> (<reason>)`. Exit 0 only on PASS.
#
# Per-step cap: --step-minutes N (decimals allowed), else .harness.json::lean.step_minutes,
# else 30. On expiry the step's process group gets TERM, then KILL 5 s later (perl: stock
# macOS bash 3.2 has no timeout). A process that started a session of its own (the gate's
# suite, lean/lib.sh lean_in_group) is stopped by its parent's TERM trap, not by the cap.
# With scripts/harness.sh present, each step's result is appended to the session log
# (best-effort: a failed append-log never fails the chain).

# lean_chain_run <seconds> <log> <command...> — the command in a process group of its own,
# stdin from /dev/null, output to <log>; exit 124 when it ran past <seconds>.
lean_chain_run() {
  local secs="$1" out="$2"; shift 2
  perl -e '
    use POSIX ();
    my $secs = shift;
    my $pid = fork;
    defined $pid or die "chain: fork: $!\n";
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"; }
    setpgrp($pid, $pid);
    my $timed_out = 0;
    $SIG{ALRM} = sub {
      $timed_out = 1;
      kill "TERM", -$pid;
      for (1 .. 10) { last unless kill 0, -$pid; select(undef, undef, undef, 0.5); }
      kill "KILL", -$pid;
    };
    alarm $secs;
    my $r;
    do { $r = waitpid($pid, 0) } while ($r == -1 && $!{EINTR});
    my $st = $?;
    alarm 0;
    exit 124 if $timed_out;
    exit(($st & 127) ? 128 + ($st & 127) : $st >> 8);
  ' "$secs" "$@" < /dev/null > "$out" 2>&1
}

# lean_chain_quote <word> — the word as is when it only holds characters no shell expands,
# else single-quoted (a ' inside written '\'').
lean_chain_quote() {
  case "$1" in
    ''|*[!A-Za-z0-9_./@%+:,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# lean_chain_close_line <steps> — the `next:` line: the log-out --lean command for the files the
# gate checked (base as run.sh's gate step resolves it: --base, else the session's, else HEAD).
lean_chain_close_line() {
  local b="$base" prefix f files=""
  [ -n "$b" ] || b=$(bash scripts/harness.sh session-base "$name" 2>/dev/null || true)
  b="${b:-HEAD}"
  prefix=$(git rev-parse --show-prefix 2>/dev/null || true)
  while IFS= read -r f; do
    [ -n "$f" ] && files="$files $(lean_chain_quote "$f")"
  done < <(lean_repo_changes "$b" 2>/dev/null \
    | awk -v p="$prefix" 'p == "" || index($0, p) == 1 { print substr($0, length(p) + 1) }' \
    | { grep -vE '^(progress|state)/' || true; })
  printf 'next: scripts/harness.sh log-out --lean%s --verification "lean chain PASS: %s ok, gate ALL CHECKS PASS" --closure "<fill in>"\n' \
    "${files:+ --changes$files}" "$1"
}

# lean_chain_mode — "risk", "normal", or a refusal on stderr (exit 1). Risk mode is the frozen
# manifest, as for every step; with the harness its status also tells a risk feature whose
# plan is not approved (no manifest yet) and a normal one waiting for approval.
lean_chain_mode() {
  local row="" hmode="" frozen="$state/frozen/$name.sha"
  if [ -f scripts/harness.sh ]; then
    row=$(bash scripts/harness.sh status 2>/dev/null | awk -v n="$name" '
      /^--- lean mode/ { on = 1; next } /^--- / { on = 0 } on && $2 == n { print; exit }' || true)
    hmode=$(awk '{print $3}' <<<"$row")
    case "$row" in *"approval pending"*) echo "the plan is not approved (approve-plan first)" >&2; return 1 ;; esac
  fi
  if [ -f "$frozen" ]; then echo risk; return 0; fi
  [ "$hmode" != risk ] || { echo "risk mode: no frozen manifest ($frozen; approve-plan freezes it)" >&2; return 1; }
  echo normal
}

lean_chain() {
  local mode="" secs mins logs gate_log="" fixed=0 n=0 total=0 cost_total="" verdict="" last_rc=0
  local fail_step="" fail_reason="" ran="" usage_before
  usage_before=$(lean_usage_count "$project" "$name" 2>/dev/null || echo 0)
  local -a lines=()
  mins="${step_minutes:-$(jq -r '.lean.step_minutes // 30' .harness.json 2>/dev/null || echo 30)}"
  [[ "$mins" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "--step-minutes / lean.step_minutes must be a number of minutes: $mins" >&2; return 2; }
  secs=$(awk -v m="$mins" 'BEGIN { s = int(m * 60); print (s < 1 ? 1 : s) }')
  mkdir -p "$state/lean" && logs=$(mktemp -d "$state/lean/$name.chain.$(date +%Y%m%d%H%M%S).XXXX") \
    || { echo "can't create a log folder in $state/lean" >&2; return 2; }
  local -a pass_args=(--headless)
  [ -z "$base" ] || pass_args+=(--base "$base")

  fmt_dur() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }
  note() {   # best-effort session log line
    [ -f scripts/harness.sh ] || return 0
    bash scripts/harness.sh append-log "lean chain: $1" >/dev/null 2>&1 || true
  }
  # step <step> — runs it, adds its line, sets fail_reason (empty: ok).
  step() {
    local st="$1" log rc=0 start dur res="" info="" extra="" parsed
    n=$((n + 1)); log="$logs/$n-$st.log"; fail_reason=""
    start=$SECONDS
    lean_chain_run "$secs" "$log" bash "$LEAN_DIR/run.sh" "$st" "$name" "${pass_args[@]}" || rc=$?
    dur=$((SECONDS - start)); total=$((total + dur)); last_rc=$rc
    if [ "$rc" = 124 ]; then
      fail_reason="timed out after ${mins}m"
    elif [ "$st" = gate ] && [ "$rc" = 1 ]; then
      fail_reason="gate failed"
    elif [ "$rc" != 0 ]; then
      fail_reason="exit $rc: $(grep -v '^\[lean\]' "$log" | sed '/^$/d' | tail -1 | cut -c1-120)"
    fi
    case "$st" in
      implement|review|fix)
        res=$(sed -n 's/^\[lean\] result: //p' "$log" | tail -1)
        if [ -n "$res" ] && parsed=$(jq -r 'select(type == "object")
             | "\(.is_error) \(.num_turns // "-") \(.total_cost_usd // "-")"' "$res" 2>/dev/null) && [ -n "$parsed" ]; then
          set -- $parsed
          info=" turns=$2"
          [ "$3" = - ] || { info="$info cost=\$$(printf '%.2f' "$3")"
            cost_total=$(awk -v a="${cost_total:-0}" -v b="$3" 'BEGIN { printf "%.2f", a + b }'); }
          [ -n "$fail_reason" ] || [ "$1" != true ] || fail_reason="the session reported is_error"
        elif [ -z "$fail_reason" ]; then
          fail_reason="no result JSON from the session${res:+ ($res)}"
        fi ;;
      freeze) extra=$(sed -n 's/^\[lean\] before implementing: *//p' "$log" | tail -1 | sed 's/ *$//')
              [ -z "$extra" ] || extra=" (before implementing: $extra)" ;;
      gate) gate_log="$log" ;;
    esac
    if [ "$st" = review ] && [ "$mode" = risk ] && [ -z "$fail_reason" ]; then
      verdict=$(jq -r '.verdict // "none"' "$state/lean/$name.review.json" 2>/dev/null || echo none)
      extra=" verdict=$verdict"
      if [ "$verdict" != approve ] && [ "$verdict" != changes ]; then
        fail_reason="no VERDICT line in docs/features/$name.review.md"
      elif [ "$(jq -r '.reviewer_changed_files' "$state/lean/$name.review.json" 2>/dev/null)" = true ]; then
        fail_reason="the reviewer changed files (it must only report)"
      fi
    fi
    ran="${ran:+$ran, }$st$([ -z "$fail_reason" ] || [ "$st" != gate ] || echo ' failed')"
    lines+=("$(printf '%-9s %-4s %7s%s%s' "$st" "$([ -z "$fail_reason" ] && echo ok || echo fail)" "$(fmt_dur "$dur")" "$info" "$extra")")
    note "$st $([ -z "$fail_reason" ] && echo ok || echo "fail ($fail_reason)") $(fmt_dur "$dur")$info$extra"
    if [ -n "$fail_reason" ]; then fail_step="$st"; return 1; fi
    fail_step=""
    return 0
  }
  # gate_and_fix — gate; when it fails and fix has not run yet: fix, gate again.
  gate_and_fix() {
    if step gate; then return 0; fi
    [ "$last_rc" = 1 ] && [ "$fixed" = 0 ] || return 1   # only failed checks get a fix round
    fixed=1; step fix || return 1
    step gate
  }

  if ! mode=$(lean_chain_mode 2>"$logs/mode.err"); then
    fail_step=start; fail_reason=$(tail -1 "$logs/mode.err")
  else
    echo "lean chain: $name ($mode mode, at most ${mins}m per step)"
    run_all() {
      if [ "$mode" = risk ]; then
        step freeze && step implement && step review || return 1
        if [ "$verdict" = changes ]; then fixed=1; step fix && step gate; return; fi
        gate_and_fix
      else
        step implement && step review || return 1
        gate_and_fix
      fi
    }
    run_all || true
  fi

  local l
  for l in ${lines[@]+"${lines[@]}"}; do echo "$l"; done
  [ "$n" = 0 ] || echo "total: $(fmt_dur "$total")${cost_total:+, cost \$$cost_total}"
  if [ -n "$gate_log" ]; then
    echo "gate:"
    { grep -E '^(ALL CHECKS PASS|HEAD MOVED|SANDBOX UNAVAILABLE|SUITE FAILS|FROZEN |ACCEPTANCE TESTS FAIL|ASSERTION LINES REMOVED|MISSING: |CHANGED BUT NOT LISTED|PATHS WITH A NEWLINE|FOLDERS THE GATE|CLAUDE\.md / |CHANGED OUTSIDE|\[WARN\])' "$gate_log" || true; } \
      | cut -c1-160 | head -10 | sed 's/^/  /'
    echo "  full report: $gate_log"
  fi
  [ "$n" = 0 ] || echo "logs: $logs (result JSON paths in each step's log)"
  echo "git status:"
  { git status --short 2>/dev/null || true; } | awk 'NR <= 30 { print "  " $0 } END { if (NR > 30) printf "  ... (%d more)\n", NR - 30 }'
  [ "$n" = 0 ] || lean_usage_table "$project" "$name" "$usage_before" 2>/dev/null || true
  if [ -z "$fail_step" ]; then
    note "PASS"
    [ ! -f scripts/harness.sh ] || lean_chain_close_line "$ran"
    echo "CHAIN: PASS"
    return 0
  fi
  [ "$n" = 0 ] || note "FAIL at $fail_step ($fail_reason)"
  echo "CHAIN: FAIL at $fail_step ($fail_reason)"
  return 1
}
