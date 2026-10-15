#!/usr/bin/env python3
"""Network-free regression tests for record-usage / stats (scripts/agent_usage.py).

Builds a throwaway installed project plus synthetic Claude Code transcripts and
Codex CLI rollouts (fake CLAUDE_CONFIG_DIR / CODEX_HOME), then drives the real
scripts/harness.sh entry points. Run: python3 tests/agent_usage_test.py
"""
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

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

    def test_single_transcript_update_and_hook(self):
        with open(self.leader, 'a', encoding='utf-8') as handle:
            handle.write(json.dumps(claude_line('2026-01-10T11:45:00.000Z', str(self.project), 'sess-1',
                                                kind='assistant', mid='m3', usage=usage(5, 0, 0, 5))) + '\n')
        settings = json.loads((ROOT / 'templates/settings.json.tmpl').read_text())
        command = settings['hooks']['SubagentStop'][0]['hooks'][0]['command']
        payload = json.dumps({'session_id': 'sess-1', 'transcript_path': str(self.leader),
                              'agent_transcript_path': str(self.leader.parent / 'sess-1/subagents/agent-rev2.jsonl')})
        hook = subprocess.run(['bash', '-c', command], input=payload, cwd=self.work, capture_output=True,
                              text=True, env=dict(self.env, CLAUDE_PROJECT_DIR=str(self.project)))
        self.assertEqual((hook.returncode, hook.stdout, hook.stderr), (0, '', ''))
        rows = self.rows()
        self.assertEqual(sorted(rows), ['rev2', 'sess-1'])
        self.assertEqual(rows['sess-1']['total_tokens'], 3133)
        broken = subprocess.run(['bash', '-c', command], input='not json', cwd=self.work, capture_output=True,
                                text=True, env=dict(self.env, CLAUDE_PROJECT_DIR=str(self.work / 'missing')))
        self.assertEqual(broken.returncode, 0)

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


if __name__ == '__main__':
    unittest.main()
