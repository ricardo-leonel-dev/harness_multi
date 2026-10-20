#!/usr/bin/env python3
"""Network-free regression tests for record-usage / stats (scripts/agent_usage.py).

Builds a throwaway installed project plus synthetic Claude Code transcripts and
Codex CLI rollouts (fake CLAUDE_CONFIG_DIR / CODEX_HOME), then drives the real
scripts/harness.sh entry points. Run: python3 tests/agent_usage_test.py
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def jsonl(path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', encoding='utf-8') as handle:
        for record in records:
            handle.write(record if isinstance(record, str) else json.dumps(record))
            handle.write('\n')


def claude_line(ts, cwd, session, agent=None, kind='user', mid=None, usage=None, model='claude-test-1',
                tool_use=None):
    line = {'type': kind, 'timestamp': ts, 'cwd': cwd, 'sessionId': session,
            'message': {'role': kind, 'content': 'SECRET PROMPT TEXT'}}
    if agent:
        line['agentId'] = agent
    if mid:
        line['message'] = {'id': mid, 'model': model, 'role': 'assistant',
                           'content': [{'type': 'text', 'text': 'SECRET ANSWER TEXT'}], 'usage': usage}
        if tool_use:
            line['message']['content'].append({'type': 'tool_use', 'id': tool_use, 'name': 'Agent',
                                               'input': {'prompt': 'SECRET SPAWN PROMPT'}})
    return line


def usage(inp, write, read, out):
    return {'input_tokens': inp, 'cache_creation_input_tokens': write,
            'cache_read_input_tokens': read, 'output_tokens': out}


def codex_rollout(path, thread, cwd, start, end, role=None, parent=None, depth=None,
                  nickname=None, agent_path=None, tokens=None):
    meta = {'id': thread, 'cwd': cwd, 'timestamp': start, 'agent_role': role, 'agent_nickname': nickname,
            'parent_thread_id': parent, 'source': 'cli', 'base_instructions': 'SECRET INSTRUCTIONS'}
    if parent:
        meta['source'] = {'subagent': {'thread_spawn': {'parent_thread_id': parent, 'depth': depth,
                                                        'agent_path': agent_path, 'agent_nickname': nickname,
                                                        'agent_role': role}}}
    records = [{'type': 'session_meta', 'timestamp': start, 'payload': meta},
               {'type': 'turn_context', 'timestamp': start, 'payload': {'model': 'gpt-test-2', 'cwd': cwd}},
               {'type': 'event_msg', 'timestamp': start, 'payload': {'type': 'token_count', 'info': None}}]
    if tokens:
        half = {k: v // 2 for k, v in tokens.items()}
        records.append({'type': 'event_msg', 'timestamp': start,
                        'payload': {'type': 'token_count', 'info': {'total_token_usage': half}}})
        records.append({'type': 'event_msg', 'timestamp': end,
                        'payload': {'type': 'token_count', 'info': {'total_token_usage': tokens}}})
    records.append({'type': 'event_msg', 'timestamp': end, 'payload': {'type': 'token_count', 'info': None}})
    records.append({'type': 'response_item', 'timestamp': end,
                    'payload': {'type': 'message', 'content': 'SECRET CODEX TEXT'}})
    jsonl(path, records)


def codex_tokens(inp, cached, out, reasoning):
    return {'input_tokens': inp, 'cached_input_tokens': cached, 'cache_write_input_tokens': 0,
            'output_tokens': out, 'reasoning_output_tokens': reasoning, 'total_tokens': inp + out}


class AgentUsage(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name).resolve()
        self.project = self.work / 'my_project.app'
        (self.project / 'scripts').mkdir(parents=True)
        for script in list((ROOT / 'scripts').glob('*.sh')) + [ROOT / 'scripts/agent_usage.py']:
            shutil.copy(script, self.project / 'scripts' / script.name)
        (self.project / '.harness.json').write_text(
            '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state"}')
        self.db = self.project / 'harness.db'
        subprocess.run(['sqlite3', str(self.db)], input=(ROOT / 'db/schema.sqlite.sql').read_text(),
                       text=True, check=True)
        self.sql("""INSERT INTO projects (id, slug) VALUES ('p1', 't');
INSERT INTO features (project_id, feature_number, name, title) VALUES ('p1', 1, 'alpha', 'Alpha'), ('p1', 2, 'beta', 'Beta');
INSERT INTO session_log (id, project_id, feature_id, agent, started_at, closed_at)
  VALUES (1, 'p1', 1, 'implementer', '2026-01-10T10:00:00.000Z', '2026-01-10T12:00:00.000Z'),
         (2, 'p1', 2, 'implementer', '2026-01-10T13:00:00.000Z', NULL);""")
        self.claude_home = self.work / 'claude-home'
        self.codex_home = self.work / 'codex-home'
        self.env = dict(os.environ, CLAUDE_CONFIG_DIR=str(self.claude_home), CODEX_HOME=str(self.codex_home),
                        HARNESS_CONFIG='.harness.json')
        self.build_fixtures()

    def sql(self, script):
        with sqlite3.connect(self.db) as conn:
            conn.executescript(script)

    def rows(self, where='1=1'):
        conn = sqlite3.connect(self.db)
        conn.row_factory = sqlite3.Row
        try:
            return {r['external_id']: dict(r) for r in conn.execute(f'SELECT * FROM agent_runs WHERE {where}')}
        finally:
            conn.close()

    def harness(self, *args, env=None):
        return subprocess.run(['bash', 'scripts/harness.sh', *args], cwd=self.project,
                              env=env or self.env, capture_output=True, text=True)

    def build_fixtures(self):
        cwd = str(self.project)
        slug = re.sub(r'[^A-Za-z0-9]', '-', cwd)
        base = self.claude_home / 'projects' / slug
        self.leader = base / 'sess-1.jsonl'
        repeated = usage(10, 100, 1000, 5)
        jsonl(self.leader, [
            claude_line('2026-01-10T09:55:00.000Z', cwd, 'sess-1'),
            claude_line('2026-01-10T09:56:00.000Z', cwd, 'sess-1', kind='assistant', mid='m1', usage=repeated),
            claude_line('2026-01-10T09:56:00.100Z', cwd, 'sess-1', kind='assistant', mid='m1', usage=repeated),
            '{"type": "assistant", truncated',
            claude_line('2026-01-10T11:30:00.000Z', cwd, 'sess-1', kind='assistant', mid='m2',
                        usage=usage(1, 0, 2000, 7)),
        ])
        subagents = base / 'sess-1' / 'subagents'
        for agent, role, label, start, end in [
                ('impl1', 'implementer', 'Implement alpha', '10:05', '10:45'),
                ('rev1', 'reviewer', 'Review alpha', '10:50', '11:00'),
                ('rev2', 'reviewer', 'Re-review alpha', '11:05', '11:10')]:
            jsonl(subagents / f'agent-{agent}.jsonl', [
                claude_line(f'2026-01-10T{start}:00.000Z', cwd, 'sess-1', agent=agent),
                claude_line(f'2026-01-10T{end}:00.000Z', cwd, 'sess-1', agent=agent, kind='assistant',
                            mid=f'{agent}-m', usage=usage(2, 20, 200, 3)),
            ])
            (subagents / f'agent-{agent}.meta.json').write_text(json.dumps(
                {'agentType': role, 'description': label, 'spawnDepth': 1}))
        # leader -> general-purpose (gp1) -> nested child (nest1, resolved via toolUseId);
        # orphan is depth 2 with a toolUseId no transcript issued -> parent NULL.
        for agent, role, depth, tool_id, spawns, start, end in [
                ('gp1', 'general-purpose', 1, 'toolu_gp', 'toolu_nested', '11:12', '11:20'),
                ('nest1', 'Explore', 2, 'toolu_nested', None, '11:14', '11:18'),
                ('orphan', 'Explore', 2, 'toolu_missing', None, '11:21', '11:22')]:
            jsonl(subagents / f'agent-{agent}.jsonl', [
                claude_line(f'2026-01-10T{start}:00.000Z', cwd, 'sess-1', agent=agent),
                claude_line(f'2026-01-10T{end}:00.000Z', cwd, 'sess-1', agent=agent, kind='assistant',
                            mid=f'{agent}-m', usage=usage(1, 0, 0, 1), tool_use=spawns),
            ])
            (subagents / f'agent-{agent}.meta.json').write_text(json.dumps(
                {'agentType': role, 'description': f'{agent} task', 'spawnDepth': depth, 'toolUseId': tool_id}))
        jsonl(base / 'sess-0.jsonl', [  # before every harness session -> unattributed
            claude_line('2026-01-09T08:00:00.000Z', cwd, 'sess-0'),
            claude_line('2026-01-09T08:10:00.000Z', cwd, 'sess-0', kind='assistant', mid='z',
                        usage=usage(1, 1, 1, 1))])
        jsonl(self.claude_home / 'projects' / '-other-project' / 'sess-x.jsonl', [
            claude_line('2026-01-10T10:00:00.000Z', '/other/project', 'sess-x')])
        (base / 'garbage.jsonl').write_text('not json at all\n{also broken\n')

        day = self.codex_home / 'sessions' / '2026' / '01' / '10'
        codex_rollout(day / 'rollout-a-lead.jsonl', 'cx-lead', cwd, '2026-01-10T13:10:00.000Z',
                      '2026-01-10T14:00:00.000Z', tokens=codex_tokens(1000, 800, 50, 20))
        codex_rollout(day / 'rollout-b-impl.jsonl', 'cx-impl', cwd, '2026-01-10T13:15:00.000Z',
                      '2026-01-10T13:40:00.000Z', role='implementer', parent='cx-lead', depth=1,
                      nickname='Averroes', tokens=codex_tokens(400, 100, 30, 10))
        codex_rollout(day / 'rollout-c-rev.jsonl', 'cx-rev', cwd + '/sub', '2026-01-10T13:41:00.000Z',
                      '2026-01-10T13:50:00.000Z', role='reviewer', parent='cx-lead', depth=1,
                      nickname='Hypatia', tokens=codex_tokens(300, 0, 20, 5))
        codex_rollout(day / 'rollout-d-nested.jsonl', 'cx-nested', cwd, '2026-01-10T13:42:00.000Z',
                      '2026-01-10T13:45:00.000Z', role='explorer', parent='cx-rev', depth=2,
                      agent_path='reviewer/explorer')
        codex_rollout(day / 'rollout-e-other.jsonl', 'cx-other', '/elsewhere', '2026-01-10T13:10:00.000Z',
                      '2026-01-10T13:20:00.000Z', tokens=codex_tokens(1, 0, 1, 0))
        (day / 'rollout-f-broken.jsonl').write_text('{"type": "response_item"}\nnope\n')

    def test_collect_tree_tokens_attribution_and_idempotence(self):
        result = self.harness('record-usage')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('[WARN]', result.stderr)
        self.assertIn('garbage.jsonl', result.stderr)
        self.assertIn('rollout-f-broken.jsonl', result.stderr)
        self.assertIn('malformed line', result.stderr)
        rows = self.rows()
        self.assertEqual(sorted(rows), sorted(['sess-1', 'impl1', 'rev1', 'rev2', 'sess-0', 'gp1', 'nest1', 'orphan',
                                               'cx-lead', 'cx-impl', 'cx-rev', 'cx-nested']))

        leader = rows['sess-1']  # m1 repeated on two lines counts once
        self.assertEqual((leader['input_tokens'], leader['cache_write_tokens'], leader['cache_read_tokens'],
                          leader['output_tokens'], leader['total_tokens']), (11, 100, 3000, 12, 3123))
        self.assertIsNone(leader['reasoning_tokens'])
        self.assertEqual((leader['agent_role'], leader['spawn_depth'], leader['parent_external_id']),
                         ('leader', 0, None))
        self.assertEqual(leader['model'], 'claude-test-1')
        self.assertEqual(leader['duration_seconds'], 95 * 60)
        self.assertEqual(leader['session_id'], 1)  # started before claim: largest overlap
        for agent, role in [('impl1', 'implementer'), ('rev1', 'reviewer'), ('rev2', 'reviewer')]:
            self.assertEqual((rows[agent]['agent_role'], rows[agent]['parent_external_id'],
                              rows[agent]['spawn_depth'], rows[agent]['feature_id']), (role, 'sess-1', 1, 1))
        self.assertEqual(rows['rev2']['label'], 'Re-review alpha')
        self.assertIsNone(rows['sess-0']['session_id'])
        self.assertEqual((rows['gp1']['parent_external_id'], rows['gp1']['spawn_depth']), ('sess-1', 1))
        self.assertEqual((rows['nest1']['parent_external_id'], rows['nest1']['spawn_depth']), ('gp1', 2))
        self.assertEqual((rows['orphan']['parent_external_id'], rows['orphan']['spawn_depth']), (None, 2))

        lead, nested = rows['cx-lead'], rows['cx-nested']
        self.assertEqual((lead['input_tokens'], lead['cache_read_tokens'], lead['output_tokens'],
                          lead['reasoning_tokens'], lead['total_tokens']), (200, 800, 50, 20, 1050))
        self.assertEqual((lead['agent_role'], lead['spawn_depth'], lead['model']), ('leader', 0, 'gpt-test-2'))
        self.assertEqual((rows['cx-impl']['label'], rows['cx-impl']['parent_external_id']), ('Averroes', 'cx-lead'))
        self.assertEqual((nested['parent_external_id'], nested['spawn_depth'], nested['label']),
                         ('cx-rev', 2, 'reviewer/explorer'))
        self.assertIsNone(nested['total_tokens'])  # only null token_count info
        self.assertTrue(all(r['session_id'] == 2 and r['feature_id'] == 2
                            for k, r in rows.items() if k.startswith('cx-')))
        dump = '\n'.join(str(r) for r in rows.values())
        self.assertNotIn('SECRET', dump)

        ids = {k: r['id'] for k, r in rows.items()}
        again = self.harness('record-usage')
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual({k: r['id'] for k, r in self.rows().items()}, ids)

        dry = self.harness('record-usage', '--dry-run', '--runtime', 'codex')
        self.assertEqual(len(dry.stdout.strip().splitlines()), 4)
        self.assertEqual(len(self.rows()), 12)

    def test_single_transcript_update(self):
        with open(self.leader, 'a', encoding='utf-8') as handle:
            handle.write(json.dumps(claude_line('2026-01-10T11:45:00.000Z', str(self.project), 'sess-1',
                                                kind='assistant', mid='m3', usage=usage(5, 0, 0, 5))) + '\n')
        rev2 = self.leader.parent / 'sess-1/subagents/agent-rev2.jsonl'
        result = self.harness('record-usage', '--transcript', str(self.leader), '--transcript', str(rev2))
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.rows()
        self.assertEqual(sorted(rows), ['rev2', 'sess-1'])
        self.assertEqual(rows['sess-1']['total_tokens'], 3133)

    def test_no_claude_hooks_template(self):
        # Claude Code and Codex behave alike: init.sh records usage, stats refreshes it.
        self.assertFalse((ROOT / 'templates/settings.json.tmpl').exists())

    def test_reopened_subagent_warns(self):
        cwd = str(self.project)
        base = self.claude_home / 'projects' / re.sub(r'[^A-Za-z0-9]', '-', cwd) / 'sess-1' / 'subagents'
        heavy = claude_line('2026-01-10T10:40:00.000Z', cwd, 'sess-1', agent='impl9', kind='assistant',
                            mid='r2', usage=usage(10, 0, 150_000, 5))
        jsonl(base / 'agent-impl9.jsonl', [
            claude_line('2026-01-10T10:05:00.000Z', cwd, 'sess-1', agent='impl9'),
            claude_line('2026-01-10T10:30:00.000Z', cwd, 'sess-1', agent='impl9', kind='assistant',
                        mid='r1', usage=usage(10, 0, 140_000, 5)),
            claude_line('2026-01-10T10:39:00.000Z', cwd, 'sess-1', agent='impl9'),  # follow-up after it answered
            heavy])
        (base / 'agent-impl9.meta.json').write_text(json.dumps(
            {'agentType': 'implementer', 'description': 'Implement alpha again', 'spawnDepth': 1}))
        working = claude_line('2026-01-10T10:30:00.000Z', cwd, 'sess-1', agent='impl8', kind='assistant',
                              mid='w1', usage=usage(10, 0, 140_000, 5), tool_use='toolu_x')
        jsonl(base / 'agent-impl8.jsonl', [
            claude_line('2026-01-10T10:05:00.000Z', cwd, 'sess-1', agent='impl8'), working,
            claude_line('2026-01-10T10:31:00.000Z', cwd, 'sess-1', agent='impl8'),  # mid-turn message
            claude_line('2026-01-10T10:32:00.000Z', cwd, 'sess-1', agent='impl8', kind='assistant',
                        mid='w2', usage=usage(10, 0, 150_000, 5))])
        day = self.codex_home / 'sessions' / '2026' / '01' / '10'
        meta = {'id': 'cx-re', 'cwd': cwd, 'timestamp': '2026-01-10T13:15:00.000Z', 'agent_role': 'implementer',
                'agent_nickname': 'Kepler', 'agent_path': '/root/impl', 'parent_thread_id': 'cx-lead'}
        msg = lambda ts: {'type': 'response_item', 'timestamp': ts,
                          'payload': {'type': 'agent_message', 'recipient': '/root/impl', 'content': 'SECRET'}}
        count = lambda ts, n: {'type': 'event_msg', 'timestamp': ts, 'payload': {'type': 'token_count', 'info': {
            'total_token_usage': codex_tokens(n, 0, 1, 0), 'last_token_usage': codex_tokens(n, 0, 1, 0)}}}
        done = lambda ts: {'type': 'event_msg', 'timestamp': ts, 'payload': {'type': 'task_complete'}}
        jsonl(day / 'rollout-g-reopen.jsonl', [
            {'type': 'session_meta', 'timestamp': '2026-01-10T13:15:00.000Z', 'payload': meta},
            done('2026-01-10T13:15:00.000Z'),  # copied from the parent's history: not this agent's turn
            msg('2026-01-10T13:15:01.000Z'), count('2026-01-10T13:16:00.000Z', 90_000),
            done('2026-01-10T13:20:00.000Z'),
            msg('2026-01-10T13:25:00.000Z'), count('2026-01-10T13:25:05.000Z', 97_000)])
        result = self.harness('record-usage')
        self.assertEqual(result.returncode, 0, result.stderr)
        warnings = [l for l in result.stderr.splitlines() if 'reopened with' in l]
        self.assertEqual(len(warnings), 2, result.stderr)
        self.assertIn('implementer "Implement alpha again" reopened with 150k context', warnings[0] + warnings[1])
        self.assertIn('implementer "Kepler" reopened with 97k context', warnings[0] + warnings[1])
        (self.project / '.harness.json').write_text(
            '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state","reopen_warn_tokens":0}')
        quiet = self.harness('record-usage', '--full')
        self.assertNotIn('reopened with', quiet.stderr)

    def test_stats_tree_and_snapshot(self):
        self.assertEqual(self.harness('record-usage').returncode, 0)
        stats = self.harness('stats')
        self.assertEqual(stats.returncode, 0, stats.stderr)
        out = stats.stdout
        self.assertIn('=== feature 1 alpha ===', out)
        self.assertIn('=== feature 2 beta ===', out)
        self.assertIn('unattributed', out)
        self.assertIn('project t (all features)', out)
        lines = out.splitlines()
        alpha = out.split('=== feature 2 beta ===')[0]
        lead = next(i for i, l in enumerate(lines) if l.startswith('leader') and 'codex' in l)
        rev = next(i for i, l in enumerate(lines) if re.match(r'^  └ reviewer "Hypatia"', l))
        nested = next(i for i, l in enumerate(lines) if re.match(r'^    └ explorer "reviewer/explorer"', l))
        self.assertLess(lead, rev)
        self.assertEqual(nested, rev + 1)
        self.assertEqual(len(re.findall(r'(?m)^  └ reviewer "(?:Re-)?[Rr]eview alpha"', alpha)), 2)
        self.assertRegex(alpha, r'(?m)^  └ general-purpose "gp1 task".*\n    └ Explore "nest1 task"')
        self.assertRegex(alpha, r'(?m)^    └ Explore "orphan task"')  # unresolved: indented by depth
        self.assertIn('agent effort (summed run durations, not wall time): 2h43m00s', out)  # 95+40+10+5+8+4+1
        self.assertIn('union of agent intervals (wall time with >=1 agent active): 1h35m00s', out)
        self.assertIn('session elapsed (claim -> log-out or now): 2h00m00s', out)
        self.assertIn('(session still open', out)
        self.assertIn('1,050', out)

        one = self.harness('stats', 'beta')
        self.assertEqual(one.returncode, 0)
        self.assertNotIn('alpha', one.stdout)
        self.assertNotEqual(self.harness('stats', 'nope').returncode, 0)

        self.assertEqual(self.harness('snapshot').returncode, 0)
        snap = (self.project / 'state/features/001-alpha.md').read_text()
        self.assertIn('## Agent usage', snap)
        self.assertIn('Re-review alpha', snap)
        self.assertIn('| **total** |', snap)
        self.assertIn('&nbsp;&nbsp;&nbsp;&nbsp; explorer (reviewer/explorer)',
                      (self.project / 'state/features/002-beta.md').read_text())

    def test_migration_creates_table_on_old_database(self):
        self.db.unlink()
        schema = (ROOT / 'db/schema.sqlite.sql').read_text()
        old = re.sub(r'CREATE TABLE agent_runs \(.*?CREATE INDEX idx_agent_runs_session[^;]*;', '', schema,
                     flags=re.S)
        self.assertNotIn('CREATE TABLE agent_runs', old)
        subprocess.run(['sqlite3', str(self.db)], input=old, text=True, check=True)
        self.sql("INSERT INTO projects (id, slug) VALUES ('p1', 't');")
        self.assertEqual(self.harness('status').returncode, 0)
        result = self.harness('record-usage', '--since', '2026-01-01')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.rows()), 12)

    def test_unchanged_files_skipped_modified_reparsed_full_rescans(self):
        first = self.harness('record-usage')
        self.assertIn('garbage.jsonl', first.stderr)
        before = self.rows()
        # A session opened later still re-attributes unchanged files' rows (no re-parse needed).
        self.sql("INSERT INTO session_log (id, project_id, feature_id, agent, started_at, closed_at) VALUES "
                 "(3, 'p1', 1, 'implementer', '2026-01-09T07:00:00.000Z', '2026-01-09T09:00:00.000Z');")
        # Corrupt an already-recorded file without changing its size or mtime: if it were
        # parsed again it would warn; skipped, it must not.
        sess0 = self.leader.with_name('sess-0.jsonl')
        info = sess0.stat()
        sess0.write_text('x' * (info.st_size - 1) + '\n')
        os.utime(sess0, ns=(info.st_atime_ns, info.st_mtime_ns))
        second = self.harness('record-usage')
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotIn('[WARN]', second.stderr)
        self.assertIn('recorded 0 agent run(s)', second.stdout)
        self.assertIn('skipped 15 unchanged file(s)', second.stdout)
        after = self.rows()
        self.assertEqual(after['sess-0']['total_tokens'], before['sess-0']['total_tokens'])
        self.assertEqual((after['sess-0']['session_id'], after['sess-0']['feature_id']), (3, 1))

        with open(self.leader, 'a', encoding='utf-8') as handle:
            handle.write(json.dumps(claude_line('2026-01-10T11:45:00.000Z', str(self.project), 'sess-1',
                                                kind='assistant', mid='m3', usage=usage(5, 0, 0, 5))) + '\n')
        # A touched nested child is re-parsed; its spawner (gp1, unchanged and skipped)
        # is still read from disk to resolve the parent.
        nest1 = self.leader.parent / 'sess-1/subagents/agent-nest1.jsonl'
        os.utime(nest1, ns=(info.st_atime_ns, nest1.stat().st_mtime_ns + 5_000_000_000))
        third = self.harness('record-usage')
        self.assertIn('recorded 2 agent run(s) (claude: 2, codex: 0)', third.stdout)
        self.assertEqual(self.rows()['sess-1']['total_tokens'], 3133)
        self.assertEqual((self.rows()['nest1']['parent_external_id'], self.rows()['nest1']['spawn_depth']),
                         ('gp1', 2))
        self.assertGreater(self.rows()['nest1']['updated_at'], after['nest1']['updated_at'])

        full = self.harness('record-usage', '--full')
        self.assertEqual(full.returncode, 0, full.stderr)
        self.assertIn('sess-0.jsonl', full.stderr)  # the corrupted file is parsed again
        self.assertIn('garbage.jsonl', full.stderr)
        self.assertIn('recorded 11 agent run(s)', full.stdout)
        self.assertNotIn('skipped', full.stdout)

    def load_module(self):
        sys.dont_write_bytecode = True
        spec = importlib.util.spec_from_file_location('agent_usage_copy', self.project / 'scripts/agent_usage.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def collect_in_process(self, module, *extra):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {'CLAUDE_CONFIG_DIR': str(self.claude_home),
                                          'CODEX_HOME': str(self.codex_home)}), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = module.main(['--db', str(self.db), '--project-slug', 't', 'collect',
                                '--project-root', str(self.project), *extra])
        return code, out.getvalue(), err.getvalue()

    def test_deadline_keeps_partial_progress_and_next_run_continues(self):
        module = self.load_module()
        real_parse, clock, parsed = module.parse_candidate, [0.0], []

        def slow_parse(kind, path, roots):  # every file "takes" 10s on a fake clock
            parsed.append(str(path))
            clock[0] += 10
            return real_parse(kind, path, roots)
        module.parse_candidate = slow_parse
        module._now = lambda: clock[0]
        # budget 25s - 3s reserved for the sqlite busy wait/commit = scan until t=22: 3 files.
        code, out, err = self.collect_in_process(module, '--max-seconds', '25')
        self.assertEqual(code, 0)
        self.assertEqual(len(parsed), 3)
        self.assertIn('time limit of 25s reached after parsing 3 file(s)', err)
        self.assertEqual(err.count('time limit'), 1)
        partial = self.rows()
        self.assertTrue(0 < len(partial) <= 3, partial.keys())
        self.assertIn(f'recorded {len(partial)} agent run(s)', out)

        first, parsed[:] = list(parsed), []
        module._now = time.monotonic
        code, out, err = self.collect_in_process(module)
        self.assertEqual(code, 0)
        self.assertNotIn('time limit', err)
        self.assertFalse(set(first) & set(parsed))  # already-parsed files are not parsed again
        self.assertEqual(len(self.rows()), 12)
        self.assertIn('skipped 3 unchanged file(s)', out)
        second, parsed[:] = list(parsed), []
        self.collect_in_process(module, '--full')
        self.assertEqual(sorted(parsed), sorted(first + second))

    def marked(self):
        with sqlite3.connect(self.db) as conn:
            return {r[0] for r in conn.execute('SELECT path FROM agent_usage_files')}

    def test_deadline_inside_a_file_leaves_it_unmarked_and_reparsed(self):
        module = self.load_module()
        real_parse, clock, parsed = module.parse_candidate, [0.0], []

        def parse(kind, path, roots):
            parsed.append(path.name)
            if len(parsed) == 3:
                clock[0] = 1000  # the budget runs out while this file is being read
            return real_parse(kind, path, roots)
        module.parse_candidate = parse
        module._now = lambda: clock[0]
        module.poll_deadline = lambda count: module.DEADLINE.check()  # poll on every line
        code, out, err = self.collect_in_process(module)
        self.assertEqual(code, 0)
        self.assertEqual(len(parsed), 3)
        interrupted, first_two = parsed[2], parsed[:2]
        self.assertIn('after parsing 2 file(s)', err)
        self.assertEqual({Path(p).name for p in self.marked()}, set(parsed[:2]))
        self.assertEqual(len(self.rows()), 1)  # garbage.jsonl yields no row
        module = self.load_module()
        parsed[:] = []
        module.parse_candidate = lambda kind, path, roots: (parsed.append(path.name), real_parse(kind, path, roots))[1]
        self.collect_in_process(module)
        self.assertIn(interrupted, parsed)
        self.assertFalse(set(parsed) & set(first_two))
        self.assertEqual(len(self.rows()), 12)

    def test_runtime_filtered_transcript_not_marked_and_paths_resolved(self):
        link = self.work / 'link.jsonl'
        link.symlink_to(self.leader)
        skipped = self.harness('record-usage', '--transcript', str(link), '--runtime', 'codex')
        self.assertIn('recorded 0 agent run(s)', skipped.stdout)
        self.assertEqual(self.marked(), set())
        hooked = self.harness('record-usage', '--transcript', str(link))
        self.assertIn('recorded 1 agent run(s)', hooked.stdout)
        self.assertEqual(self.marked(), {str(self.leader.resolve())})
        self.assertEqual(self.rows()['sess-1']['source_path'], str(self.leader.resolve()))
        scan = self.harness('record-usage')
        self.assertIn('skipped 1 unchanged file(s)', scan.stdout)  # the hook's mark matches the scan path

    def test_failed_upsert_and_dry_run_leave_no_file_marks(self):
        dry = self.harness('record-usage', '--dry-run')
        self.assertEqual(len(dry.stdout.strip().splitlines()), 12)
        self.assertEqual(self.marked(), set())
        self.sql("CREATE TRIGGER no_runs BEFORE INSERT ON agent_runs BEGIN SELECT RAISE(ABORT, 'boom'); END;")
        failed = self.harness('record-usage')
        self.assertEqual(failed.returncode, 0, failed.stderr)
        self.assertIn('could not record agent runs: boom', failed.stderr)
        self.assertEqual((self.marked(), self.rows()), (set(), {}))

    def test_tight_deadline_records_nothing_but_exits_cleanly(self):
        result = self.harness('record-usage', '--max-seconds', '0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('recorded 0 agent run(s)', result.stdout)
        self.assertEqual(result.stderr.count('time limit of 0s reached after parsing 0 file(s)'), 1)

    def test_migration_adds_usage_files_table_to_old_database(self):
        self.db.unlink()
        schema = (ROOT / 'db/schema.sqlite.sql').read_text()
        old = re.sub(r'CREATE TABLE agent_usage_files \(.*?\);', '', schema, flags=re.S)
        self.assertNotIn('agent_usage_files (', old)
        subprocess.run(['sqlite3', str(self.db)], input=old, text=True, check=True)
        self.sql("INSERT INTO projects (id, slug) VALUES ('p1', 't');")
        self.assertEqual(self.harness('status').returncode, 0)
        with sqlite3.connect(self.db) as conn:
            columns = [r[1] for r in conn.execute('PRAGMA table_info(agent_usage_files)')]
        self.assertEqual(columns, ['project_id', 'path', 'mtime_ns', 'size', 'recorded_at'])
        self.harness('record-usage', '--since', '2026-01-01')
        again = self.harness('record-usage', '--since', '2026-01-01')
        self.assertIn('recorded 0 agent run(s)', again.stdout)

    def test_long_running_codex_thread_in_old_day_directory(self):
        # Started two days before the default --since floor, still written to now (mtime).
        codex_rollout(self.codex_home / 'sessions/2026/01/07/rollout-long.jsonl', 'cx-long', str(self.project),
                      '2026-01-07T09:00:00.000Z', '2026-01-10T13:30:00.000Z', tokens=codex_tokens(10, 0, 1, 0))
        dry = self.harness('record-usage', '--dry-run', '--runtime', 'codex')
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn('"external_id": "cx-long"', dry.stdout)

    def test_missing_homes_are_quiet_noops(self):
        env = dict(self.env, CLAUDE_CONFIG_DIR=str(self.work / 'none'), CODEX_HOME=str(self.work / 'none'))
        result = self.harness('record-usage', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('recorded 0 agent run(s)', result.stdout)

    def init(self):
        """Run init.sh with a sync stub that reports how many agent_runs exist when it runs."""
        shutil.copy(ROOT / 'init.sh', self.project / 'init.sh')
        for doc in ('docs/architecture.md', 'docs/conventions.md', 'docs/verification.md', 'CHECKPOINTS.md'):
            (self.project / doc).parent.mkdir(parents=True, exist_ok=True)
            (self.project / doc).write_text('# doc\n')
        (self.project / 'scripts/sync_postgres.sh').write_text(
            '#!/usr/bin/env bash\ncd "$(dirname "$0")/.." && echo "SYNC_SAW_RUNS=$(sqlite3 harness.db '
            '"SELECT count(*) FROM agent_runs" 2>/dev/null || echo none)"\n')
        return subprocess.run(['bash', 'init.sh'], cwd=self.project, env=self.env, capture_output=True, text=True)

    def usage_lines(self, output):
        return [line for line in output.splitlines() if not line.startswith('──')
                and ('agent usage' in line or 'record_agent_usage' in line)]

    def test_init_records_usage_before_mirror_sync(self):
        result = self.init()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('SYNC_SAW_RUNS=12', result.stdout)
        lines = self.usage_lines(result.stdout)
        self.assertEqual(len(lines), 1, result.stdout)
        self.assertIn('recorded 12 agent run(s)', lines[0])
        self.assertIn('[WARN]', lines[0])  # the broken fixtures collapse into one counted warning
        self.assertNotIn('garbage.jsonl', result.stdout + result.stderr)

    def test_init_exit_status_unaffected_when_record_usage_fails_or_is_missing(self):
        script = self.project / 'scripts/agent_usage.py'
        script.write_text('import sys\nsys.stderr.write("Traceback: boom\\n")\nsys.exit(3)\n')
        failed = self.init()
        self.assertEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        self.assertEqual(len(self.usage_lines(failed.stdout)), 1, failed.stdout)
        self.assertIn('agent usage not recorded', failed.stdout)
        self.assertNotIn('boom', failed.stdout + failed.stderr)
        script.unlink()
        missing = self.init()
        self.assertEqual(missing.returncode, 0, missing.stdout + missing.stderr)
        self.assertIn('agent usage not recorded', missing.stdout)
        self.assertIn('SYNC_SAW_RUNS=0', missing.stdout)

    def test_init_opt_out_skips_record_usage(self):
        (self.project / '.harness.json').write_text(
            '{"project_slug":"t","db_path":"harness.db","snapshot_path":"state","record_agent_usage":false}')
        result = self.init()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('record_agent_usage is false', result.stdout)
        self.assertIn('SYNC_SAW_RUNS=0', result.stdout)


if __name__ == '__main__':
    unittest.main()
