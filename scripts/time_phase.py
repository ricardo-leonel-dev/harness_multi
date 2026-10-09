#!/usr/bin/env python3
"""Opt-in command timing, with no command/argument/output capture in events."""
import argparse
from datetime import datetime, timezone
import json
import subprocess
import sys
import time


def utc():
    return datetime.now(timezone.utc).isoformat(timespec='milliseconds')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', required=True, choices=('init', 'evidence', 'logout'))
    parser.add_argument('--log', help='optional local JSONL event file')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('an explicit command is required after --')
    log = None
    if args.log:
        try:
            log = open(args.log, 'a', encoding='utf-8')
        except OSError:
            print('time_phase: cannot open timing log; command was not run', file=sys.stderr)
            return 2
    started, tick = utc(), time.monotonic()
    try:
        status = subprocess.run(command, check=False).returncode
        status = status if status >= 0 else 128 - status
    except FileNotFoundError:
        status = 127
    except OSError:
        status = 126
    except KeyboardInterrupt:
        status = 130
    event = {'phase': args.phase, 'started_utc': started, 'finished_utc': utc(),
             'elapsed_seconds': round(time.monotonic() - tick, 6), 'exit_status': status}
    row = json.dumps(event, sort_keys=True)
    # Child stdout/stderr inherit unchanged. This single summary follows on stdout.
    print(row, flush=True)
    if log:
        try:
            log.write(row + '\n')
            log.close()
        except OSError:
            print('time_phase: timing log write failed; command status preserved', file=sys.stderr)
    return status


if __name__ == '__main__':
    sys.exit(main())
