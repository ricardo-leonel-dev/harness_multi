#!/usr/bin/env python3
"""Database/network-free regression tests for migration assembly and phase timing."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ASSEMBLER = ROOT / 'profiles/postgres/assemble_migration.py'
TIMER = ROOT / 'scripts/time_phase.py'


class WorkflowTools(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.ddl = self.work / 'ddl.sql'
        self.ddl.write_text('ALTER TABLE tenant.applications ADD COLUMN extra json;\n')
        self.output = self.work / 'migration.sql'
        self.output.write_text('existing output')

    def assemble(self, *extra):
        return subprocess.run([sys.executable, str(ASSEMBLER), '--ddl', str(self.ddl),
                               '--output', str(self.output), *extra], capture_output=True, text=True)

    def test_preserves_full_multiline_owner_and_order(self):
        canonical = self.work / 'function with spaces $(touch injected).sql'
        definition = ("CREATE OR REPLACE FUNCTION tenant.test() RETURNS json LANGUAGE plpgsql AS $fn$\n"
                      "BEGIN\n RETURN json_build_object('BEGIN; COMMIT; \\i secret.sql', 'ROLLBACK');\nEND;\n$fn$;\n"
                      "ALTER FUNCTION tenant.test(\n)\n    OWNER TO rm_manager;\n")
        canonical.write_text(definition)
        result = self.assemble('--definition', str(canonical))
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = 'BEGIN;\n\n' + self.ddl.read_text() + '\n\n' + definition + '\n\nCOMMIT;\n'
        self.assertEqual(self.output.read_text(), expected)
        self.assertFalse((self.work / 'injected').exists())
        self.assertEqual(self.assemble('--definition', str(canonical)).returncode, 0)
        self.assertEqual(self.output.read_text(), expected)

    def test_quotes_and_comments_are_not_controls(self):
        self.ddl.write_text("/* BEGIN; /* nested */ COMMIT; */\n-- \\include file\n"
                            "SELECT 'COMMIT;', E'escaped\\\' \\i file', \"BEGIN\", $$ROLLBACK;$$;\n")
        self.assertEqual(self.assemble().returncode, 0)

    def test_invalid_fragments_preserve_existing_output(self):
        invalid = ['BEGIN;', 'START TRANSACTION;', 'COMMIT;', 'END;', 'ROLLBACK;',
                   'ABORT;', '\ufeffBEGIN;', 'SAVEPOINT a;', 'RELEASE SAVEPOINT a;', 'PREPARE TRANSACTION \'a\';',
                   'SET TRANSACTION READ ONLY;', 'SET LOCAL TRANSACTION READ ONLY;',
                   'SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY;', '\\i local.sql\n',
                   '\\include local.sql\n', 'SELECT 1', '', '/* comments */', '/* broken',
                   "SELECT 'broken;", 'DO $tag$ broken;']
        for content in invalid:
            with self.subTest(content=content):
                self.ddl.write_text(content)
                result = self.assemble()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.output.read_text(), 'existing output')

    def test_missing_duplicate_empty_definition_and_output_alias(self):
        alias = self.work / 'alias.sql'
        alias.symlink_to(self.ddl)
        empty = self.work / 'empty.sql'
        empty.write_text('')
        for path in [self.work / 'missing.sql', self.ddl, alias, empty]:
            self.assertNotEqual(self.assemble('--definition', str(path)).returncode, 0)
            self.assertEqual(self.output.read_text(), 'existing output')
        before = self.ddl.read_bytes()
        result = subprocess.run([sys.executable, str(ASSEMBLER), '--ddl', str(self.ddl),
                                 '--output', str(alias)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.ddl.read_bytes(), before)

    def test_timing_status_elapsed_and_no_secret_capture(self):
        log = self.work / 'timing.jsonl'
        secret = 'sensitive-command-argument'
        for status in [0, 9]:
            result = subprocess.run([sys.executable, str(TIMER), '--phase', 'evidence',
                                     '--log', str(log), '--', sys.executable, '-c',
                                     'import sys,time;print(sys.argv[1]);time.sleep(.02);sys.exit(int(sys.argv[2]))',
                                     secret, str(status)], capture_output=True, text=True)
            self.assertEqual(result.returncode, status)
            self.assertEqual(result.stdout.splitlines()[0], secret)
            event = json.loads(result.stdout.splitlines()[-1])
            self.assertEqual(set(event), {'phase', 'started_utc', 'finished_utc', 'elapsed_seconds', 'exit_status'})
            self.assertEqual(event['exit_status'], status)
            self.assertGreater(event['elapsed_seconds'], .015)
            self.assertIn('+00:00', event['started_utc'])
            self.assertNotIn(secret, json.dumps(event))
        self.assertEqual(len(log.read_text().splitlines()), 2)
        self.assertNotIn(secret, log.read_text())

    def test_timing_signal_preserves_failure(self):
        result = subprocess.run([sys.executable, str(TIMER), '--phase', 'logout', '--',
                                 sys.executable, '-c', 'import os,signal;os.kill(os.getpid(),signal.SIGTERM)'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 143)
        self.assertEqual(json.loads(result.stdout)['exit_status'], 143)

    def test_timing_missing_command_and_unopenable_log(self):
        result = subprocess.run([sys.executable, str(TIMER), '--phase', 'init', '--',
                                 str(self.work / 'missing')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 127)
        self.assertEqual(json.loads(result.stdout)['exit_status'], 127)
        marker = self.work / 'must not run'
        result = subprocess.run([sys.executable, str(TIMER), '--phase', 'init', '--log',
                                 str(self.work / 'missing dir/log'), '--', sys.executable, '-c',
                                 'from pathlib import Path;import sys;Path(sys.argv[1]).touch()', str(marker)],
                                capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(marker.exists())

    def test_installer_refreshes_excludes_and_preserves_project(self):
        project = self.work / 'installed project'
        project.mkdir()
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        command = ['bash', str(ROOT / 'install.sh'), '--slug', 'workflow-tools-test',
                   '--human-user', 'Tester', '--verify-command', 'true']
        install = subprocess.run(command, cwd=project, capture_output=True, text=True)
        self.assertEqual(install.returncode, 0, install.stdout + install.stderr)
        self.assertTrue((project / 'scripts/time_phase.py').exists())
        self.assertFalse((project / 'scripts/assemble_migration.py').exists())
        paths = ['scripts/time_phase.py', 'harness/instructions/timing.md']
        sentinel = project / 'CHECKPOINTS.md'
        sentinel.write_text('project sentinel')
        postgres_command = command + ['--profile', 'postgres']
        install = subprocess.run(postgres_command, cwd=project, input='', capture_output=True, text=True)
        self.assertEqual(install.returncode, 0, install.stdout + install.stderr)
        self.assertEqual(sentinel.read_text(), 'project sentinel')
        paths += ['scripts/assemble_migration.py', 'harness/instructions/postgres.md']
        for path in paths:
            subprocess.run(['git', 'check-ignore', '-q', path], cwd=project, check=True)
            (project / path).write_text('stale asset')
        reinstall = subprocess.run(postgres_command, cwd=project, input='', capture_output=True, text=True)
        self.assertEqual(reinstall.returncode, 0, reinstall.stdout + reinstall.stderr)
        mapping = {'scripts/time_phase.py': TIMER, 'scripts/assemble_migration.py': ASSEMBLER,
                   'harness/instructions/timing.md': ROOT / 'shared/timing.md',
                   'harness/instructions/postgres.md': ROOT / 'profiles/postgres/verification.md'}
        for path, source in mapping.items():
            self.assertEqual((project / path).read_bytes(), source.read_bytes())
        self.assertEqual(sentinel.read_text(), 'project sentinel')
        for runtime, suffix in [('.claude', 'md'), ('.codex', 'toml')]:
            instructions = (project / runtime / 'agents' / ('implementer.' + suffix)).read_text()
            self.assertIn('development iteration', instructions)
            self.assertIn('genuinely external', instructions)
            self.assertIn('reviewer gate', (project / 'AGENTS.md').read_text())


if __name__ == '__main__':
    unittest.main()
