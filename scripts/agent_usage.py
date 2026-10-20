#!/usr/bin/env python3
"""Per-agent duration and token usage for the harness (Claude Code + Codex CLI).

Subcommands (normally reached through scripts/harness.sh record-usage / stats):

  collect  read Claude Code transcripts and/or Codex CLI rollouts for this
           project and upsert one agent_runs row per invocation (leader/main
           session, implementer, reviewer, spec_author, research and nested
           spawns). Read-only on the transcripts; copies only numbers, role,
           label, model, timestamps, ids and the source path — never prompt or
           transcript content. Unknown/malformed input is a [WARN] on stderr
           and the file is skipped; collect always exits 0.
           Incremental: a transcript whose size and mtime match its
           agent_usage_files record is skipped without parsing (--full
           rescans everything; --transcript always parses the given file).
           Bounded: --max-seconds (default 20) caps the run; at the limit it
           stops scanning, records what it already parsed, prints one [WARN]
           and the next run continues where this one stopped.
           Warns when a finished subagent was sent a follow-up while carrying
           at least --reopen-warn-tokens of context (a fresh agent is cheaper).
  stats    print the invocation tree (parent -> children) per feature with
           per-run duration/tokens, totals per feature and per project.

Sources:
  Claude Code  $CLAUDE_CONFIG_DIR (default ~/.claude)/projects/<slug>/<session>.jsonl
               (main session, depth 0, role 'leader') and
               <session>/subagents/agent-<id>.jsonl + agent-<id>.meta.json.
               <slug> = absolute project path with every non-alphanumeric
               character replaced by '-'. Usage of one message.id is repeated
               on every content-block line; it is de-duplicated (last wins).
  Codex CLI    $CODEX_HOME (default ~/.codex)/sessions/YYYY/MM/DD/rollout-*.jsonl.
               session_meta gives id/cwd/agent_role/parent; the LAST non-null
               token_count info.total_token_usage is the cumulative usage.

Token columns: input_tokens is uncached input (Codex input_tokens includes
cached input, which is subtracted), cache_read/cache_write are separate,
output includes reasoning, reasoning_tokens is Codex-only (NULL for Claude),
and total_tokens = input + cache_read + cache_write + output (Codex: its own
total_tokens, the same quantity).
"""
import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import time

RUNTIMES = ('claude', 'codex')
TOKEN_FIELDS = ('input_tokens', 'cache_read_tokens', 'cache_write_tokens',
                'output_tokens', 'reasoning_tokens', 'total_tokens')
DEFAULT_MAX_SECONDS = 20.0
DEFAULT_REOPEN_WARN_TOKENS = 80_000  # context a finished subagent carries into a follow-up
MAX_BUSY_SECONDS = 3.0  # sqlite busy wait, carved out of the --max-seconds budget
_now = time.monotonic  # indirection so tests can drive the deadline with a fake clock
ROW_FIELDS = ('runtime', 'agent_role', 'label', 'external_id', 'parent_external_id',
              'spawn_depth', 'model', 'started_at', 'finished_at', 'duration_seconds',
              *TOKEN_FIELDS, 'source_path')


def warn(message):
    print(f'[WARN]  agent_usage: {message}', file=sys.stderr)


class DeadlineReached(Exception):
    pass


class Deadline:
    """Wall-clock budget for one collect run. The scan stops busy_seconds
    before the limit so the final commit (and its sqlite busy wait) still fits."""

    def __init__(self, max_seconds):
        self.max_seconds = max(float(max_seconds), 0.0)
        self.busy_seconds = min(MAX_BUSY_SECONDS, self.max_seconds / 4)
        self.scan_until = _now() + self.max_seconds - self.busy_seconds

    def expired(self):
        return _now() >= self.scan_until

    def check(self):
        if self.expired():
            raise DeadlineReached()


DEADLINE = None  # set by cmd_collect; read_lines/claude_spawner poll it on long files


def poll_deadline(counter):
    if DEADLINE is not None and counter % 2000 == 0:
        DEADLINE.check()


def parse_ts(value):
    """Parse an ISO-8601 timestamp (Z or offset, any fraction length) to aware UTC."""
    if not isinstance(value, str) or not value:
        return None
    text = value.strip().replace('Z', '+00:00')
    match = re.match(r'^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})(\.\d+)?(.*)$', text)
    if not match:
        return None
    base, frac, tail = match.groups()
    frac = (frac or '.0')[1:7].ljust(6, '0')
    try:
        parsed = datetime.fromisoformat(f'{base}.{frac}{tail}')
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def fmt_ts(value):
    if value is None:
        return None
    return value.strftime('%Y-%m-%dT%H:%M:%S.') + f'{value.microsecond // 1000:03d}Z'


def claude_slug(path):
    return re.sub(r'[^A-Za-z0-9]', '-', path)


def under_root(cwd, roots):
    if not isinstance(cwd, str) or not cwd:
        return False
    candidates = {cwd, os.path.realpath(cwd)}
    return any(c == r or c.startswith(r.rstrip('/') + '/') for c in candidates for r in roots)


def read_lines(path):
    """Yield parsed JSON objects; count malformed lines instead of failing."""
    stats = {'bad': 0, 'good': 0}

    def gen():
        with open(path, 'r', encoding='utf-8', errors='replace') as handle:
            for count, line in enumerate(handle, 1):
                poll_deadline(count)
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    stats['bad'] += 1
                    continue
                if not isinstance(obj, dict):
                    stats['bad'] += 1
                    continue
                stats['good'] += 1
                yield obj
    return gen(), stats


def as_int(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def finish_row(row, first, last):
    row['started_at'] = fmt_ts(first)
    row['finished_at'] = fmt_ts(last)
    row['duration_seconds'] = (round((last - first).total_seconds(), 3)
                               if first and last else None)
    return row


def parse_claude(path, roots=None):
    """Return an agent_runs row dict for one Claude Code transcript, or None."""
    path = Path(path)
    lines, stats = read_lines(path)
    usage = {}
    first = last = None
    cwds, session_id, agent_id = set(), None, None
    finished, reopens, awaiting = False, [], False
    for obj in lines:
        stamp = parse_ts(obj.get('timestamp'))
        if stamp:
            first = stamp if first is None or stamp < first else first
            last = stamp if last is None or stamp > last else last
        if isinstance(obj.get('cwd'), str):
            cwds.add(obj['cwd'])
        session_id = session_id or (obj.get('sessionId') if isinstance(obj.get('sessionId'), str) else None)
        agent_id = agent_id or (obj.get('agentId') if isinstance(obj.get('agentId'), str) else None)
        message = obj.get('message')
        if obj.get('type') == 'user' and isinstance(message, dict) and is_prompt(message.get('content')):
            # A prompt after the agent ended its turn is a follow-up sent to an
            # agent that already answered: it re-reads its whole context.
            awaiting, finished = finished, False
        if obj.get('type') == 'assistant' and isinstance(message, dict):
            blocks = message.get('content') if isinstance(message.get('content'), list) else []
            tools = [b.get('name') for b in blocks if isinstance(b, dict) and b.get('type') == 'tool_use']
            if tools:
                # Handing the report back to the caller ends the agent's turn.
                finished = all(isinstance(t, str) and t.endswith('Handback') for t in tools)
            elif any(isinstance(b, dict) and b.get('type') == 'text' for b in blocks):
                finished = True
            mid, use = message.get('id'), message.get('usage')
            if isinstance(mid, str) and isinstance(use, dict):
                usage[mid] = (use, message.get('model'))  # repeated per content block: last wins
                if awaiting:
                    reopens.append(sum(as_int(use.get(k)) for k in
                                       ('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')))
                    awaiting = False
    if stats['bad']:
        warn(f'{path}: skipped {stats["bad"]} malformed line(s)')
    if first is None or (session_id is None and not usage):
        warn(f'{path}: unrecognized Claude transcript format — skipped')
        return None
    if roots is not None and cwds and not any(under_root(c, roots) for c in cwds):
        return None

    is_subagent = path.parent.name == 'subagents'
    meta = {}
    if is_subagent:
        meta_path = path.with_name(path.name[:-len('.jsonl')] + '.meta.json')
        try:
            loaded = json.loads(meta_path.read_text(encoding='utf-8'))
            meta = loaded if isinstance(loaded, dict) else {}
        except (OSError, ValueError):
            meta = {}
        stem = path.name[:-len('.jsonl')]
        external = agent_id or (stem[len('agent-'):] if stem.startswith('agent-') else stem)
        depth = meta.get('spawnDepth') if isinstance(meta.get('spawnDepth'), int) else 1
        parent = path.parent.parent.name or session_id
        if depth > 1:
            # Nested spawn: the parent is whichever transcript issued the tool_use
            # that launched it, not the session's leader. NULL if not found.
            parent = claude_spawner(path, meta.get('toolUseId'))
        role = meta.get('agentType') if isinstance(meta.get('agentType'), str) else 'subagent'
        label = meta.get('description') if isinstance(meta.get('description'), str) else None
    else:
        external, parent, depth, role, label = session_id or path.stem, None, 0, 'leader', None

    model = None
    totals = dict.fromkeys(('input_tokens', 'cache_read_tokens', 'cache_write_tokens', 'output_tokens'), 0)
    for use, msg_model in usage.values():
        totals['input_tokens'] += as_int(use.get('input_tokens'))
        totals['cache_read_tokens'] += as_int(use.get('cache_read_input_tokens'))
        totals['cache_write_tokens'] += as_int(use.get('cache_creation_input_tokens'))
        totals['output_tokens'] += as_int(use.get('output_tokens'))
        if isinstance(msg_model, str) and msg_model and not msg_model.startswith('<'):
            model = msg_model
    row = {'runtime': 'claude', 'agent_role': role, 'label': label, 'external_id': external,
           'parent_external_id': parent, 'spawn_depth': depth, 'model': model,
           **totals, 'reasoning_tokens': None, 'total_tokens': sum(totals.values()),
           'source_path': str(path), '_reopens': reopens if is_subagent else []}
    return finish_row(row, first, last)


def is_prompt(content):
    """A user turn written as a prompt (text), not a tool result."""
    if isinstance(content, str):
        return bool(content.strip())
    return (isinstance(content, list) and any(isinstance(b, dict) and b.get('type') == 'text' for b in content)
            and not any(isinstance(b, dict) and b.get('type') == 'tool_result' for b in content))


def claude_spawner(path, tool_use_id):
    """external_id of the sibling subagent (or main session) transcript whose
    assistant message contains a tool_use block with this id, else None."""
    if not isinstance(tool_use_id, str) or not tool_use_id:
        return None
    session_dir = path.parent.parent
    candidates = [p for p in sorted(path.parent.glob('agent-*.jsonl')) if p != path]
    candidates.append(session_dir.parent / f'{session_dir.name}.jsonl')
    for candidate in candidates:
        try:
            with open(candidate, 'r', encoding='utf-8', errors='replace') as handle:
                for count, line in enumerate(handle, 1):
                    poll_deadline(count)
                    if tool_use_id not in line:
                        continue
                    try:
                        obj = json.loads(line)
                    except ValueError:
                        continue
                    message = obj.get('message') if isinstance(obj, dict) else None
                    content = message.get('content') if isinstance(message, dict) else None
                    if obj.get('type') != 'assistant' or not isinstance(content, list):
                        continue
                    if any(isinstance(b, dict) and b.get('type') == 'tool_use' and b.get('id') == tool_use_id
                           for b in content):
                        if candidate.parent.name == 'subagents':
                            stem = candidate.name[:-len('.jsonl')]
                            return obj.get('agentId') or stem[len('agent-'):]
                        return obj.get('sessionId') or session_dir.name
        except OSError:
            continue
    return None


def codex_meta(path):
    """First session_meta payload of a rollout (cheap peek), or None."""
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as handle:
            for _, line in zip(range(5), handle):
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if isinstance(obj, dict) and obj.get('type') == 'session_meta' and isinstance(obj.get('payload'), dict):
                    return obj['payload']
    except OSError:
        return None
    return None


def parse_codex(path, roots=None):
    """Return an agent_runs row dict for one Codex rollout, or None."""
    path = Path(path)
    lines, stats = read_lines(path)
    meta, usage, model = None, None, None
    first = last = None
    tasks, finished, reopens, awaiting = 0, False, [], False
    for obj in lines:
        stamp = parse_ts(obj.get('timestamp'))
        if stamp:
            first = stamp if first is None or stamp < first else first
            last = stamp if last is None or stamp > last else last
        payload = obj.get('payload')
        if not isinstance(payload, dict):
            continue
        kind = obj.get('type')
        if kind == 'session_meta' and meta is None:
            meta = payload
        elif kind == 'turn_context' and isinstance(payload.get('model'), str):
            model = payload['model']
        elif kind == 'event_msg' and payload.get('type') == 'token_count':
            info = payload.get('info')
            if isinstance(info, dict) and isinstance(info.get('total_token_usage'), dict):
                usage = info['total_token_usage']  # cumulative: the last one wins
                last_use = info.get('last_token_usage')
                if awaiting and isinstance(last_use, dict):
                    reopens.append(as_int(last_use.get('input_tokens')))
                    awaiting = False
        elif kind == 'event_msg' and payload.get('type') == 'task_complete':
            finished = True
        elif (kind == 'response_item' and payload.get('type') == 'agent_message' and meta
              and payload.get('recipient') and payload.get('recipient') == own_path(meta)):
            # The parent's first message is the task; one sent after the agent
            # completed a turn reopens it with everything it has read so far.
            tasks += 1
            awaiting = tasks > 1 and finished
            finished = False  # task_complete events copied from the parent's history don't count
    if stats['bad']:
        warn(f'{path}: skipped {stats["bad"]} malformed line(s)')
    if meta is None or not isinstance(meta.get('id'), str):
        warn(f'{path}: no session_meta — unrecognized Codex rollout format, skipped')
        return None
    if roots is not None and not under_root(meta.get('cwd'), roots):
        return None
    source = meta.get('source') if isinstance(meta.get('source'), dict) else {}
    subagent = source.get('subagent') if isinstance(source.get('subagent'), dict) else {}
    spawn = subagent.get('thread_spawn') if isinstance(subagent.get('thread_spawn'), dict) else {}
    parent = meta.get('parent_thread_id') or spawn.get('parent_thread_id')
    role = meta.get('agent_role') or spawn.get('agent_role') or ('subagent' if parent else 'leader')
    depth = spawn.get('depth') if isinstance(spawn.get('depth'), int) else (1 if parent else 0)
    label = (meta.get('agent_nickname') or spawn.get('agent_nickname')
             or spawn.get('agent_path') or meta.get('agent_path'))
    start = parse_ts(meta.get('timestamp')) or first
    row = {'runtime': 'codex', 'agent_role': role, 'label': label, 'external_id': meta['id'],
           'parent_external_id': parent, 'spawn_depth': depth, 'model': model,
           'source_path': str(path), '_reopens': reopens if parent else []}
    if usage:
        cached = as_int(usage.get('cached_input_tokens'))
        written = as_int(usage.get('cache_write_input_tokens'))
        row.update(input_tokens=max(as_int(usage.get('input_tokens')) - cached - written, 0),
                   cache_read_tokens=cached, cache_write_tokens=written,
                   output_tokens=as_int(usage.get('output_tokens')),
                   reasoning_tokens=as_int(usage.get('reasoning_output_tokens')),
                   total_tokens=as_int(usage.get('total_tokens')))
    else:
        row.update(dict.fromkeys(TOKEN_FIELDS))
    return finish_row(row, start, last if last and start and last >= start else start)


def own_path(meta):
    source = meta.get('source') if isinstance(meta.get('source'), dict) else {}
    subagent = source.get('subagent') if isinstance(source.get('subagent'), dict) else {}
    spawn = subagent.get('thread_spawn') if isinstance(subagent.get('thread_spawn'), dict) else {}
    return meta.get('agent_path') or spawn.get('agent_path')


def warn_reopens(rows, limit):
    """One [WARN] per subagent that got a follow-up while already carrying a
    large context: a fresh agent reading only the handoff costs a fraction."""
    if limit <= 0:
        return
    for row in rows:
        heavy = [n for n in row.get('_reopens') or [] if n >= limit]
        if heavy:
            name = f'{row["agent_role"]} "{row["label"]}"' if row.get('label') else row['agent_role']
            warn(f'{name} reopened with {max(heavy) // 1000}k context ({len(heavy)} follow-up(s), '
                 f'{(row.get("total_tokens") or 0) / 1e6:.1f}M tokens in total) — launch a fresh agent '
                 'for follow-ups instead of messaging a finished one')


def detect_and_parse(path, roots):
    meta = codex_meta(path)
    if meta is not None:
        return parse_codex(path, roots)
    return parse_claude(path, roots)


def file_key(path):
    """(mtime_ns, size) change key of a transcript, or None if it vanished. A
    Claude subagent's .meta.json counts too (its mtime can move the key)."""
    try:
        info = path.stat()
    except OSError:
        return None
    mtime_ns, size = info.st_mtime_ns, info.st_size
    if path.parent.name == 'subagents':
        try:
            mtime_ns = max(mtime_ns, path.with_name(path.name[:-len('.jsonl')] + '.meta.json').stat().st_mtime_ns)
        except OSError:
            pass
    return mtime_ns, size


def claude_candidates(root_paths):
    home = Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude')
    files = []
    for slug in sorted({claude_slug(r) for r in root_paths}):
        base = (home / 'projects' / slug).resolve()  # resolved like --transcript paths
        if not base.is_dir():
            continue
        files += list(base.glob('*.jsonl')) + list(base.glob('*/subagents/agent-*.jsonl'))
    return [('claude', p) for p in sorted(set(files))]


def codex_candidates():
    home = Path(os.environ.get('CODEX_HOME') or Path.home() / '.codex')
    base = (home / 'sessions').resolve()
    if not base.is_dir():
        return []
    # No YYYY/MM/DD directory pre-filter: a long-running thread lives in the
    # directory of the day it started, so only the file mtime decides.
    return [('codex', p) for day in sorted(base.glob('[0-9]*/[0-9]*/[0-9]*'))
            for p in sorted(day.glob('rollout-*.jsonl'))]


def parse_candidate(kind, path, roots):
    if kind == 'claude':
        # The slug directory already scopes runs to this project; no cwd re-check.
        return parse_claude(path)
    meta = codex_meta(path)
    if meta is None:
        warn(f'{path}: no session_meta — unrecognized Codex rollout format, skipped')
        return None
    if not under_root(meta.get('cwd'), roots):
        return None
    return parse_codex(path, roots)


def has_table(conn, name):
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def connect(db_path, busy_seconds=5.0):
    # mode=rw: never create an empty database file for a mistyped/missing path.
    # timeout = sqlite busy wait when another writer holds the lock.
    conn = sqlite3.connect(Path(db_path).resolve().as_uri() + '?mode=rw', uri=True, timeout=busy_seconds)
    conn.row_factory = sqlite3.Row
    if not has_table(conn, 'agent_runs'):
        raise RuntimeError('agent_runs table missing — run through scripts/harness.sh (it migrates harness.db)')
    return conn


def project_id(conn, slug):
    row = conn.execute('SELECT id FROM projects WHERE slug=? AND deleted_at IS NULL LIMIT 1', (slug,)).fetchone()
    if not row:
        raise RuntimeError(f'unknown project slug: {slug}')
    return row['id']


def load_sessions(conn, pid):
    now = datetime.now(timezone.utc)
    sessions = []
    for row in conn.execute('SELECT id, feature_id, started_at, closed_at, deleted_at FROM session_log '
                            'WHERE project_id=?', (pid,)):
        start = parse_ts(row['started_at'])
        if start is None:
            continue
        sessions.append({'id': row['id'], 'feature_id': row['feature_id'], 'start': start,
                         'end': parse_ts(row['closed_at']) or now,
                         'deleted': row['deleted_at'] is not None})
    return sessions


def attribute(run, sessions):
    """Session whose [started_at, closed_at|now] window contains the run's start;
    non-deleted sessions first, latest start wins. Fallback: the session that
    overlaps the run the longest (e.g. a leader that started before claim)."""
    start, end = parse_ts(run['started_at']), parse_ts(run['finished_at'])
    if start is None:
        return None
    end = end or start
    for deleted in (False, True):
        pool = [s for s in sessions if s['deleted'] == deleted]
        hits = [s for s in pool if s['start'] <= start <= s['end']]
        if hits:
            return max(hits, key=lambda s: (s['start'], s['id']))
        overlaps = [((min(end, s['end']) - max(start, s['start'])).total_seconds(), s) for s in pool]
        overlaps = [(o, s) for o, s in overlaps if o > 0]
        if overlaps:
            return max(overlaps, key=lambda pair: (pair[0], pair[1]['id']))[1]
    return None


def default_since(conn, pid):
    row = conn.execute("SELECT min(started_at) AS s FROM session_log WHERE project_id=? AND closed_at IS NULL "
                       "AND deleted_at IS NULL", (pid,)).fetchone()
    if not row['s']:
        row = conn.execute('SELECT max(started_at) AS s FROM session_log WHERE project_id=? '
                           'AND deleted_at IS NULL', (pid,)).fetchone()
    fallback = datetime.now(timezone.utc) - timedelta(days=30)
    found = parse_ts(row['s']) if row['s'] else None
    # A leader usually starts before claim: look back one extra day.
    return (found - timedelta(days=1)) if found else fallback


def parse_since(value):
    match = re.fullmatch(r'(\d+)([dh])', value or '')
    if match:
        amount = int(match.group(1))
        delta = timedelta(days=amount) if match.group(2) == 'd' else timedelta(hours=amount)
        return datetime.now(timezone.utc) - delta
    stamp = parse_ts(value if 'T' in value else f'{value}T00:00:00Z')
    if stamp is None:
        raise ValueError(f'invalid --since value: {value} (use ISO date/time, or Nd / Nh)')
    return stamp


UPSERT = f"""INSERT INTO agent_runs (project_id, session_id, feature_id, {', '.join(ROW_FIELDS)})
VALUES (:project_id, :session_id, :feature_id, {', '.join(':' + f for f in ROW_FIELDS)})
ON CONFLICT(project_id, runtime, external_id) WHERE deleted_at IS NULL DO UPDATE SET
  session_id=excluded.session_id, feature_id=excluded.feature_id,
  {', '.join(f'{f}=excluded.{f}' for f in ROW_FIELDS if f not in ('runtime', 'external_id'))},
  updated_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"""


FILE_UPSERT = """INSERT INTO agent_usage_files (project_id, path, mtime_ns, size)
VALUES (?, ?, ?, ?)
ON CONFLICT(project_id, path) DO UPDATE SET mtime_ns=excluded.mtime_ns, size=excluded.size,
  recorded_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"""


def reattribute(conn, pid, paths, sessions):
    """Unchanged files are not re-parsed, but sessions may have opened/closed
    since: refresh session/feature attribution of their stored rows (cheap)."""
    if not paths:
        return
    updates = []
    for row in conn.execute('SELECT id, started_at, finished_at, session_id, feature_id, source_path '
                            'FROM agent_runs WHERE project_id=? AND deleted_at IS NULL', (pid,)):
        if row['source_path'] not in paths:
            continue
        session = attribute(row, sessions)
        sid, fid = (session['id'], session['feature_id']) if session else (None, None)
        if (sid, fid) != (row['session_id'], row['feature_id']):
            updates.append((sid, fid, row['id']))
    conn.executemany("UPDATE agent_runs SET session_id=?, feature_id=?, "
                     "updated_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id=?", updates)


def cmd_collect(args):
    global DEADLINE
    DEADLINE = deadline = Deadline(args.max_seconds)
    root = os.path.abspath(args.project_root)
    roots = sorted({root, os.path.realpath(root)})
    conn = None
    try:
        conn = connect(args.db, busy_seconds=deadline.busy_seconds)
        pid = project_id(conn, args.project_slug)
        sessions = load_sessions(conn, pid)
        since = parse_since(args.since) if args.since else default_since(conn, pid)
        track = has_table(conn, 'agent_usage_files')
    except (RuntimeError, ValueError, sqlite3.Error) as error:
        if args.dry_run and conn is None:
            pid, sessions, track, since = None, [], False, (parse_since(args.since) if args.since
                                                            else datetime.now(timezone.utc) - timedelta(days=30))
        else:
            warn(str(error))
            return 0
    # --dry-run always parses everything (it prints rows, it records nothing).
    known = {}
    if track and not (args.full or args.dry_run):
        known = {r['path']: (r['mtime_ns'], r['size']) for r in conn.execute(
            'SELECT path, mtime_ns, size FROM agent_usage_files WHERE project_id=?', (pid,))}
    candidates = []
    if args.transcript:
        for item in args.transcript:
            path = Path(item)
            if path.is_file():
                candidates.append(('transcript', path.resolve()))  # same key as a scan
            else:
                warn(f'{path}: transcript not found — skipped')
    else:
        if 'claude' in wanted(args.runtime):
            candidates += claude_candidates(roots)
        if 'codex' in wanted(args.runtime):
            candidates += codex_candidates()
    floor_ns = int(since.timestamp() * 1_000_000_000)
    rows, parsed, skipped, stopped = [], [], set(), False
    for kind, path in candidates:
        if deadline.expired():
            stopped = True
            break
        key = file_key(path)
        if key is None:
            continue
        if kind != 'transcript':
            if key[0] < floor_ns:
                continue
            if known.get(str(path)) == key:
                skipped.add(str(path))
                continue
        try:
            row = detect_and_parse(path, roots) if kind == 'transcript' else parse_candidate(kind, path, roots)
        except DeadlineReached:
            stopped = True
            break
        if row and row['runtime'] not in wanted(args.runtime):
            continue  # filtered out by --runtime: not recorded, so not marked as seen
        parsed.append((str(path), key))
        if row:
            rows.append(row)
    for row in rows:
        session = attribute(row, sessions)
        row['session_id'] = session['id'] if session else None
        row['feature_id'] = session['feature_id'] if session else None
        row['project_id'] = pid
    if args.dry_run:
        for row in rows:
            print(json.dumps(row, sort_keys=True))
        return 0
    try:
        with conn:
            conn.executemany(UPSERT, rows)
            if track:
                conn.executemany(FILE_UPSERT, [(pid, path, key[0], key[1]) for path, key in parsed])
                reattribute(conn, pid, skipped, sessions)
    except sqlite3.Error as error:
        warn(f'could not record agent runs: {error}')
        return 0
    warn_reopens(rows, args.reopen_warn_tokens)
    counts = {r: sum(1 for row in rows if row['runtime'] == r) for r in RUNTIMES}
    note = f', skipped {len(skipped)} unchanged file(s)' if skipped else ''
    print(f'[OK]    recorded {len(rows)} agent run(s) (claude: {counts["claude"]}, codex: {counts["codex"]}){note}')
    if stopped:
        warn(f'time limit of {deadline.max_seconds:g}s reached after parsing {len(parsed)} file(s); '
             'partial progress recorded, the next run continues (raise --max-seconds to finish in one run)')
    return 0


def wanted(runtime):
    return RUNTIMES if runtime == 'all' else (runtime,)


# ---------------------------------------------------------------- stats

def human_duration(seconds):
    if seconds is None:
        return '-'
    seconds = int(round(seconds))
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    return f'{hours}h{minutes:02d}m{secs:02d}s' if hours else f'{minutes}m{secs:02d}s'


def num(value):
    return '-' if value is None else f'{value:,}'


def union_seconds(intervals):
    total, current = 0.0, None
    for start, end in sorted(i for i in intervals if i[0] and i[1]):
        if current and start <= current[1]:
            current[1] = max(current[1], end)
            continue
        if current:
            total += (current[1] - current[0]).total_seconds()
        current = [start, end]
    if current:
        total += (current[1] - current[0]).total_seconds()
    return total


def tree_order(runs):
    """Depth-first (parent -> children) order with each run's indentation level."""
    by_key = {(r['runtime'], r['external_id']): r for r in runs}
    children = {}
    roots = []
    for run in runs:
        parent = (run['runtime'], run['parent_external_id'])
        if run['parent_external_id'] and parent in by_key and parent != (run['runtime'], run['external_id']):
            children.setdefault(parent, []).append(run)
        else:
            roots.append(run)
    key = lambda r: (r['started_at'] or '', r['id'])
    ordered, seen = [], set()

    def walk(run, level):
        ident = (run['runtime'], run['external_id'])
        if ident in seen:
            return
        seen.add(ident)
        ordered.append((run, level))
        for child in sorted(children.get(ident, []), key=key):
            walk(child, level + 1)
    for run in sorted(roots, key=key):
        # A run whose parent is outside this group still shows its spawn depth.
        if run['parent_external_id'] is None:
            level = run['spawn_depth'] or 0  # unresolved parent: indent by spawn depth
        else:
            level = max((run['spawn_depth'] or 1) - 1, 0)  # parent outside this group
        walk(run, level)
    return ordered


COLUMNS = ('agent', 'runtime', 'model', 'started_at', 'duration', 'input', 'cache_read',
           'cache_write', 'output', 'reasoning', 'total')


def run_cells(run, level):
    name = run['agent_role'] or '?'
    if run['label']:
        name += f' "{run["label"]}"'
    return ['  ' * level + ('└ ' if level else '') + name, run['runtime'], run['model'] or '-',
            (run['started_at'] or '-')[:19].replace('T', ' '), human_duration(run['duration_seconds']),
            num(run['input_tokens']), num(run['cache_read_tokens']), num(run['cache_write_tokens']),
            num(run['output_tokens']), num(run['reasoning_tokens']), num(run['total_tokens'])]


def sum_field(runs, field):
    values = [r[field] for r in runs if r[field] is not None]
    return sum(values) if values else None


def print_table(rows):
    widths = [max(len(str(r[i])) for r in rows) for i in range(len(rows[0]))]
    for index, row in enumerate(rows):
        cells = [str(c).ljust(widths[i]) if i < 4 else str(c).rjust(widths[i]) for i, c in enumerate(row)]
        print('  '.join(cells).rstrip())
        if index == 0:
            print('  '.join('-' * w for w in widths))


def print_group(title, runs, session_bounds=None):
    print(f'=== {title} ===')
    table = [list(COLUMNS)] + [run_cells(run, level) for run, level in tree_order(runs)]
    table.append(['TOTAL', '', '', '', human_duration(sum_field(runs, 'duration_seconds')),
                  *[num(sum_field(runs, f)) for f in ('input_tokens', 'cache_read_tokens',
                                                      'cache_write_tokens', 'output_tokens',
                                                      'reasoning_tokens', 'total_tokens')]])
    print_table(table)
    intervals = [(parse_ts(r['started_at']), parse_ts(r['finished_at'])) for r in runs]
    starts = [i[0] for i in intervals if i[0]]
    ends = [i[1] for i in intervals if i[1]]
    print(f'runs: {len(runs)}')
    print(f'agent effort (summed run durations, not wall time): {human_duration(sum_field(runs, "duration_seconds"))}')
    print(f'union of agent intervals (wall time with >=1 agent active): {human_duration(union_seconds(intervals))}')
    if starts and ends:
        print(f'agent span (first start -> last finish, includes gaps/waits): '
              f'{human_duration((max(ends) - min(starts)).total_seconds())}')
    if session_bounds:
        print(f'session elapsed (claim -> log-out or now): {session_bounds}')
    print()


def cmd_stats(args):
    try:
        conn = connect(args.db)
        pid = project_id(conn, args.project_slug)
    except (RuntimeError, sqlite3.Error) as error:
        print(f'[FAIL]  {error}', file=sys.stderr)
        return 1
    features = {row['id']: row for row in conn.execute(
        'SELECT id, feature_number, name FROM features WHERE project_id=? AND deleted_at IS NULL', (pid,))}
    target = None
    if args.feature:
        for row in features.values():
            if args.feature in (str(row['feature_number']), row['name']):
                target = row['id']
        if target is None:
            print(f'[FAIL]  no active feature matches: {args.feature}', file=sys.stderr)
            return 1
    runs = [dict(r) for r in conn.execute(
        'SELECT * FROM agent_runs WHERE project_id=? AND deleted_at IS NULL ORDER BY started_at, id', (pid,))]
    if target is not None:
        runs = [r for r in runs if r['feature_id'] == target]
    if not runs:
        print('no agent runs recorded (run: scripts/harness.sh record-usage)')
        return 0
    now = datetime.now(timezone.utc)
    groups = {}
    for run in runs:
        groups.setdefault(run['feature_id'], []).append(run)
    order = sorted(groups, key=lambda f: (f is None, features[f]['feature_number'] if f in features else 0))
    for fid in order:
        if fid in features:
            feature = features[fid]
            span = conn.execute('SELECT min(started_at) AS s, max(coalesce(closed_at, :now)) AS e, '
                                'sum(closed_at IS NULL) AS open FROM session_log WHERE feature_id=:f '
                                'AND deleted_at IS NULL', {'f': fid, 'now': fmt_ts(now)}).fetchone()
            bounds = None
            if span['s']:
                bounds = human_duration((parse_ts(span['e']) - parse_ts(span['s'])).total_seconds())
                if span['open']:
                    bounds += ' (session still open — not active work)'
            print_group(f'feature {feature["feature_number"]} {feature["name"]}', groups[fid], bounds)
        else:
            print_group('unattributed (outside every harness session)', groups[fid])
    if target is None and len(groups) > 1:
        print_group(f'project {args.project_slug} (all features)', runs)
    print('Summed durations are agent effort; overlapping agents count once in the union.\n'
          'See harness/instructions/timing.md for how to report elapsed vs. agent time.')
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--db', default='harness.db')
    parser.add_argument('--project-slug', required=True)
    sub = parser.add_subparsers(dest='command', required=True)
    collect = sub.add_parser('collect', help='upsert agent runs into harness.db')
    collect.add_argument('--project-root', default='.')
    collect.add_argument('--transcript', action='append', help='single transcript/rollout file (repeatable)')
    collect.add_argument('--runtime', choices=('claude', 'codex', 'all'), default='all')
    collect.add_argument('--since', help='ISO date/time or Nd/Nh (default: earliest open session start, '
                         'else the last session start, minus 1 day; else 30 days)')
    collect.add_argument('--dry-run', action='store_true', help='print rows as JSON lines, write nothing')
    collect.add_argument('--full', action='store_true',
                         help='re-parse every transcript in the window, even unchanged ones')
    collect.add_argument('--reopen-warn-tokens', type=int, default=DEFAULT_REOPEN_WARN_TOKENS,
                         help='warn when a finished subagent gets a follow-up with at least this much '
                              'context (0 disables)')
    collect.add_argument('--max-seconds', type=float, default=DEFAULT_MAX_SECONDS,
                         help=f'time budget incl. sqlite busy wait (default {DEFAULT_MAX_SECONDS:g}); '
                         'stops early and keeps partial progress')
    stats = sub.add_parser('stats', help='per-agent invocation tree, durations and tokens')
    stats.add_argument('feature', nargs='?')
    args = parser.parse_args(argv)
    if args.command == 'collect':
        try:
            return cmd_collect(args)
        except Exception as error:  # never block the caller (hook, leader, init)
            warn(f'unexpected error, nothing recorded: {error}')
            return 0
    return cmd_stats(args)


if __name__ == '__main__':
    sys.exit(main())
