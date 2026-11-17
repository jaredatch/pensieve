"""Shard planning and the real wrapper's selection, admission and self-test contracts."""
from collections import Counter, defaultdict
import fcntl
import importlib
import json
import os
from pathlib import Path
import random
import shutil
import signal
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
FIXTURE = 'PensieveTests/A/one 9\nPensieveTests/A/two 1\nPensieveTests/B/one 8\nPensieveTests/C/one 6\nPensieveTests/D/one 4\nPensieveTests/E/one 2\nPensieveTests/F/one 2\nPensieveTests/Zero/one 0\n'
TESTS = ['PensieveTests/A/one', 'PensieveTests/A/two', 'PensieveTests/B/one',
         'PensieveTests/C/one', 'PensieveTests/D/one', 'PensieveTests/E/one',
         'PensieveTests/F/one', 'PensieveTests/Zero/one',
         'PensieveTests/New/one', 'PensieveTests/New/two']


class ShardPlanTests(unittest.TestCase):
    def test_complete_balanced_deterministic_class_partition(self):
        planner = importlib.import_module('test_shards')
        for text in (FIXTURE, (SCRIPTS.parent / '.slipway/timings').read_text()):
            weights = defaultdict(float)
            for line in text.splitlines():
                identifier, seconds = line.split()
                weights[identifier.rsplit('/', 1)[0]] += float(seconds)
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'timings'
                for count in (1, 2, 3, 5):
                    path.write_text(text)
                    shares = planner.plan(path, count)
                    self.assertEqual(len(shares), count)
                    self.assertEqual(Counter(c for share in shares for c in share), Counter(weights.keys()))
                    totals = [sum(weights[c] for c in share) for share in shares]
                    self.assertLessEqual(max(totals) - min(totals), max(weights.values()) + 1e-8)
                    lines = text.splitlines()
                    random.Random(185).shuffle(lines)
                    path.write_text('\n'.join(lines) + '\n')
                    self.assertEqual(planner.plan(path, count), shares)

    def test_invalid_timings_are_diagnostics_not_plans(self):
        planner = importlib.import_module('test_shards')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'timings'
            for text in (None, '', 'garbage\n', 'T/C/t 1 extra\n', 'T//t 1\n', 'T/C/t/extra 1\n',
                         'T/C/t -1\n', 'T/C/t -inf\n', 'T/C/t inf\n', 'T/C/t nan\n', 'T/C/t nope\n',
                         'T/C/t 1\nT/C/t 2\n'):
                with self.subTest(text=text):
                    if text is not None:
                        path.write_text(text)
                    with self.assertRaisesRegex(ValueError, str(path)):
                        planner.plan(path, 3)


class WrapperFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='pensieve-shards-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scripts = self.root / 'script'
        scripts.mkdir()
        for name in ('test.sh', 'test_shards.py', 'test_runs.py', 'test_diagnostics.py', 'test_temp_cleanup.py'):
            if (SCRIPTS / name).exists():
                shutil.copy2(SCRIPTS / name, scripts / name)
        for name in ('generate.sh', 'check-live-defaults.py', 'check-path-syntax.py'):
            if name.endswith('.sh'):
                code = '#!/bin/sh\nprintf "generate\\n" >> "$FIXTURE_CALLS"\n'
            else:
                code = ('import os\nfrom pathlib import Path\n'
                        f'with Path(os.environ["FIXTURE_CALLS"]).open("a") as calls: calls.write({name!r} + "\\n")\n')
            (scripts / name).write_text(code)
            (scripts / name).chmod(0o755)
        (self.root / '.slipway').mkdir()
        self.timings = self.root / '.slipway/timings'
        self.timings.write_text(FIXTURE)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.record = self.root / 'selected.json'
        self.calls = self.root / 'calls'
        self.stub('xcodebuild', '''import json, os, pathlib, sys
args = sys.argv[1:]
tests = json.loads(os.environ['FIXTURE_TESTS'])
def matches(test, identifier):
    return test == identifier or test.startswith(identifier + '/')
only, skip = [], []
for i, arg in enumerate(args):
    if arg in ('-only-testing', '-skip-testing'):
        (only if arg == '-only-testing' else skip).append(args[i + 1])
    elif arg.startswith(('-only-testing:', '-skip-testing:')):
        (only if arg.startswith('-only-testing:') else skip).append(arg.split(':', 1)[1])
selected = [test for test in tests if (not only or any(matches(test, item) for item in only))
            and not any(matches(test, item) for item in skip)]
pathlib.Path(os.environ['FIXTURE_RECORD']).write_text(json.dumps({'args': args, 'tests': selected}))
pathlib.Path(args[args.index('-resultBundlePath') + 1]).mkdir()
sys.exit(65 if os.environ.get('FIXTURE_FAIL') in selected else 0)
''')
        self.stub('xcrun', '''import json, os, pathlib
selected = json.loads(pathlib.Path(os.environ['FIXTURE_RECORD']).read_text())['tests']
print(json.dumps({'totalTestCount': len(selected), 'testFailures': []}))
''')
        self.stub('getconf', 'print("/nonexistent-pensieve-fixture")\n')
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        HOME=str(self.root / 'home'), XP_TEST_LOCK_HELD='1',
                        FIXTURE_TESTS=json.dumps(TESTS), FIXTURE_RECORD=str(self.record), FIXTURE_CALLS=str(self.calls))
        for key in ('XP_TEST_T0', 'XP_TEST_FULL_HELD', 'TEST_RUNNER_PENSIEVE_TEST_WINDOW_SAMPLE_DIR',
                    'TEST_RUNNER_PENSIEVE_TEST_DIAGNOSTICS_DIR'):
            self.env.pop(key, None)

    def stub(self, name, code):
        path = self.bin / name
        path.write_text('#!/usr/bin/env python3\nimport os, pathlib\n'
                        'with pathlib.Path(os.environ["FIXTURE_CALLS"]).open("a") as calls: calls.write("' + name + '\\n")\n' + code)
        path.chmod(0o755)

    def run_wrapper(self, *args, env=None):
        command = ['/bin/bash', str(self.root / 'script/test.sh'), *args]
        with subprocess.Popen(command, env=env or self.env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, start_new_session=True) as process:
            try:
                stdout, stderr = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                self.fail(f'wrapper did not return within 5 seconds: {args}')
            return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


class WrapperShardTests(WrapperFixture):
    def selected(self, *args, failing=None):
        env = dict(self.env, FIXTURE_FAIL=failing or '')
        result = self.run_wrapper(*args, env=env)
        self.assertTrue(self.record.exists(), result.stdout + result.stderr)
        record = json.loads(self.record.read_text())
        self.assertIn(f"PENSIEVE_TEST_COUNT={len(record['tests'])}\n", result.stdout)
        self.assertEqual(result.returncode, 65 if failing in record['tests'] else 0, result.stderr)
        self.assertNotIn('-parallel-testing-worker-count', record['args'])
        self.assertNotIn('-maximum-parallel-testing-workers', record['args'])
        return record

    def test_shares_cover_actual_tests_and_new_classes_without_other_restrictions(self):
        for count in (1, 2, 3):
            occurrences = Counter()
            records = [self.selected('--shard', f'{index}/{count}') for index in range(1, count + 1)]
            class_sets = [{test.rsplit('/', 1)[0] for test in record['tests'] if '/New/' not in test} for record in records]
            for index, record in enumerate(records):
                occurrences.update(record['tests'])
                selection = [arg for arg in record['args'] if arg.startswith(('-only-testing', '-skip-testing'))]
                self.assertTrue(all(arg == '-skip-testing' for arg in selection), record)
                skips = {record['args'][i + 1] for i, arg in enumerate(record['args']) if arg == '-skip-testing'}
                self.assertEqual(skips, set().union(*(classes for j, classes in enumerate(class_sets) if j != index)))
            self.assertEqual(occurrences, Counter({test: count if '/New/' in test else 1 for test in TESTS}))
        full = self.selected()
        self.assertEqual(full['tests'], TESTS)
        self.assertFalse(any(arg.startswith(('-skip-testing', '-only-testing')) for arg in full['args']))
        self.assertEqual(self.selected('--filter', 'A')['tests'], TESTS[:2])

    def test_selected_failure_fails_only_its_share_and_zero_count_is_refused(self):
        failing = TESTS[0]
        runs = [self.selected('--shard', f'{index}/3', failing=failing) for index in (1, 2, 3)]
        self.assertEqual(sum(failing in run['tests'] for run in runs), 1)
        env = dict(self.env, FIXTURE_TESTS='[]')
        for args in (('--shard', '1/3'), ('--filter', 'Missing')):
            result = self.run_wrapper(*args, env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('zero tests', result.stderr)

    def test_invalid_options_and_timings_refuse_before_held_locks_or_tools(self):
        directory = Path(self.env['HOME']) / '.local/state/execplan'
        directory.mkdir(parents=True)
        holder = directory / 'test.lock.holder'
        holder.write_bytes(b'fixture holder\n')
        # Real kernel locks held by a separate process (this test), with neither inherited bypass.
        env = dict(self.env)
        env.pop('XP_TEST_LOCK_HELD', None)
        with (directory / 'test.lock').open('w') as lock, (directory / 'test-full.lock').open('w') as full:
            fcntl.flock(lock, fcntl.LOCK_EX)
            fcntl.flock(full, fcntl.LOCK_EX)
            cases = [('--shard',), *[('--shard', value) for value in
                     ('0/3', '4/3', '1/0', '-1/3', 'x', '1/x', '1/3/5')],
                     ('--shard', '1/3', '--filter', 'A'), ('--filter', 'A', '--shard', '1/3'),
                     ('--typo',), ('--self-test', 'extra')]
            for args in cases:
                with self.subTest(args=args):
                    result = self.run_wrapper(*args, env=env)
                    self.assertEqual(result.returncode, 64, result.stderr)
                    self.assertIn('usage:', result.stderr)
            for content in (None, '', 'broken\n'):
                with self.subTest(timings=content):
                    if content is None:
                        self.timings.unlink()
                    else:
                        self.timings.write_text(content)
                    result = self.run_wrapper('--shard', '1/3', env=env)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(str(self.timings), result.stderr)
            self.assertEqual(holder.read_bytes(), b'fixture holder\n')
            self.assertFalse(self.calls.exists())


class SelfTestWiringTests(WrapperFixture):
    def test_shard_self_test_failure_reaches_wrapper(self):
        scripts = self.root / 'script'
        for name in ('test_lifecycle_self_test.py', 'test_display_self_test.py'):
            (scripts / name).write_text('pass\n')
        marker = self.root / 'shards-ran'
        (scripts / 'test_shards_self_test.py').write_text(
            f'from pathlib import Path\nPath({str(marker)!r}).touch()\nraise SystemExit(7)\n')
        result = subprocess.run(['/bin/bash', str(scripts / 'test.sh'), '--self-test'],
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertTrue(marker.exists(), result.stdout + result.stderr)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('test.sh --self-test: OK', result.stdout)


if __name__ == '__main__':
    unittest.main()
