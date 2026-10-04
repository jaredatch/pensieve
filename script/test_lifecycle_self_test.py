"""Exercise the real test wrapper with local Xcode stubs; never launch Xcode or touch live data."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import select
import subprocess
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

import test_diagnostics as diagnostics

SCRIPTS = Path(__file__).resolve().parent


class TestLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pensieve-test-lifecycle-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / "script"
        scripts.mkdir()
        for name in ("test.sh", "test_diagnostics.py", "test_runs.py"):
            source = SCRIPTS / name
            if source.exists():
                shutil.copy2(source, scripts / name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.stub("xcodegen", "#!/bin/sh\nexit 0\n")
        self.stub("xcrun", '#!/bin/sh\necho \'{"totalTestCount":1,"testFailures":[]}\'\n')
        self.stub("xcodebuild", """#!/usr/bin/env python3
import json, os, pathlib, sys, time, uuid
bundle = pathlib.Path(sys.argv[sys.argv.index('-resultBundlePath') + 1])
bundle.mkdir()
(bundle / 'marker').write_text('preserved evidence')
pathlib.Path(os.environ['TEST_LIFECYCLE_READY']).write_text(json.dumps({'pid': os.getpid(), 'directory': str(bundle.parent)}))
if os.environ.get('TEST_LIFECYCLE_MODE') == 'diagnostics':
    directory = pathlib.Path(os.environ['TEST_RUNNER_PENSIEVE_TEST_DIAGNOSTICS_DIR'])
    directory.mkdir(parents=True, exist_ok=True)
    identifier = str(os.getpid()) + '-' + str(uuid.uuid4())
    for kind in ('state', 'threads'):
        destination = directory / (identifier + '-' + kind + '.txt')
        temporary = directory / (identifier + '-' + kind + '.tmp')
        temporary.write_text('live timeout ' + kind)
        temporary.rename(destination)
    deadline = time.monotonic() + 30
    while not pathlib.Path(os.environ['TEST_LIFECYCLE_RELEASE']).exists():
        if time.monotonic() > deadline:
            sys.exit(72)
        time.sleep(0.02)
    print('Xcode flushed host output after release', flush=True)
if os.environ.get('TEST_LIFECYCLE_MODE') == 'hang':
    while True:
        time.sleep(0.1)
sys.exit(65)
""")
        self.env = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"], XP_TEST_LOCK_HELD="1")
        self.env.pop("TEST_RUNNER_PENSIEVE_TEST_DIAGNOSTICS_DIR", None)
        self.runs = self.root / "DerivedData/TestRuns"
        self.children = []
        self.addCleanup(self.stop_children)

    def stub(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def stop_children(self):
        for pid in self.children:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def launch(self, mode="fail", label="run"):
        ready = self.root / (label + ".json")
        env = dict(self.env, TEST_LIFECYCLE_MODE=mode, TEST_LIFECYCLE_READY=str(ready),
                   TEST_LIFECYCLE_RELEASE=str(self.root / (label + ".release")))
        process = subprocess.Popen(["/bin/bash", str(self.root / "script/test.sh")],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.children.append(process.pid)
        self.addCleanup(process.stdout.close)
        self.addCleanup(lambda: process.poll())
        return process, ready

    def wait_ready(self, ready):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                value = json.loads(ready.read_text())
                self.children.append(value["pid"])
                return value
            except (FileNotFoundError, json.JSONDecodeError):
                time.sleep(0.02)
        self.fail("stub xcodebuild never started")

    def relay_pid(self, parent):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            listing = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,command="], text=True)
            for line in listing.splitlines():
                fields = line.strip().split(None, 2)
                if len(fields) == 3 and int(fields[1]) == parent and "test_diagnostics.py" in fields[2]:
                    pid = int(fields[0])
                    self.children.append(pid)
                    return pid
            time.sleep(0.02)
        self.fail("wrapper never started its relay")

    def failed_run(self, label="failed"):
        process, _ = self.launch(label=label)
        output = process.communicate(timeout=10)[0].decode()
        self.assertEqual(process.returncode, 65, output)
        self.assertIn("PENSIEVE_TEST_COUNT=1", output)
        return output

    def test_failed_run_removes_emptied_directory(self):
        self.failed_run()
        bundles = list((self.root / "DerivedData/FailedRuns").glob("*.xcresult"))
        self.assertEqual(len(bundles), 1)
        self.assertEqual((bundles[0] / "marker").read_text(), "preserved evidence")
        self.assertEqual(list(self.runs.iterdir()), [], "failed run left an empty TestRuns directory")

    def abandoned_runs(self):
        self.runs.mkdir(parents=True, exist_ok=True)
        paths = []
        for index in range(8):
            path = self.runs / f"run.abandoned-{index}"
            (path / "run.xcresult").mkdir(parents=True)
            (path / "run.xcresult/marker").write_text("interrupted evidence")
            os.utime(path, (100 + index, 100 + index))
            paths.append(path)
        return paths

    def test_prunes_to_five_newest_interrupted_runs(self):
        abandoned = self.abandoned_runs()
        empty = self.runs / "run.old-empty"
        empty.mkdir()
        self.failed_run()
        self.assertEqual(set(self.runs.iterdir()), set(abandoned[-5:]))
        self.assertTrue(all((path / "run.xcresult/marker").exists() for path in abandoned[-5:]))

    def test_pruning_preserves_a_locked_run_and_symlink_targets(self):
        abandoned = self.abandoned_runs()
        protected = abandoned[0]
        lock = (protected / ".active.lock").open("w")
        self.addCleanup(lock.close)
        fcntl.flock(lock, fcntl.LOCK_EX)
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "marker").write_text("do not delete")
        link = self.runs / "run.link"
        link.symlink_to(outside, target_is_directory=True)
        self.failed_run()
        self.assertEqual(set(self.runs.iterdir()), {protected, link, *abandoned[-5:]})
        self.assertEqual((outside / "marker").read_text(), "do not delete")

    def test_builder_lock_survives_wrapper_death_and_then_becomes_prunable(self):
        process, ready = self.launch(mode="hang", label="active")
        child = self.wait_ready(ready)
        self.relay_pid(process.pid)
        active = Path(child["directory"])
        process.kill()
        process.wait(timeout=3)
        held = subprocess.run(["/usr/bin/lockf", "-k", "-t", "0", str(active / ".active.lock"),
                               "/usr/bin/true"], capture_output=True)
        self.assertNotEqual(held.returncode, 0, "a killed wrapper released its live builder's lock")
        os.utime(active, (1, 1))
        abandoned = self.abandoned_runs()
        self.failed_run(label="during-live-builder")
        self.assertEqual(set(self.runs.iterdir()), {active, *abandoned[-5:]})
        os.kill(child["pid"], signal.SIGTERM)
        process.communicate(timeout=3)
        self.failed_run(label="after-builder-exits")
        self.assertEqual(set(self.runs.iterdir()), set(abandoned[-5:]))

    def test_legacy_live_run_without_lock_is_preserved(self):
        abandoned = self.abandoned_runs()
        active = abandoned[0]
        process = subprocess.Popen(["python3", "-c", "import time; time.sleep(30)", str(active)])
        self.children.append(process.pid)
        self.addCleanup(lambda: process.wait(timeout=3))
        self.addCleanup(process.kill)
        self.failed_run()
        self.assertEqual(set(self.runs.iterdir()), {active, *abandoned[-5:]})

    def report_pair(self, directory, index, pid=99999999):
        directory.mkdir(parents=True, exist_ok=True)
        identifier = f"{pid}-{uuid.UUID(int=index)}"
        paths = set()
        for kind in ('state', 'threads'):
            path = directory / (identifier + '-' + kind + '.txt')
            path.write_text(kind + ' retained evidence')
            os.utime(path, (100 + index, 100 + index))
            paths.add(path)
        return paths

    def test_diagnostics_prune_keeps_newest_complete_inactive_pairs(self):
        directory = self.root / 'DerivedData/TestDiagnostics'
        pairs = [self.report_pair(directory, index) for index in range(8)]
        live = self.report_pair(directory, 10, os.getpid())
        for path in live:
            os.utime(path, (1, 1))
        unrelated = directory / 'notes.txt'
        unrelated.write_text('not a report')
        invalid = directory / '99999999-not-a-uuid-state.txt'
        invalid.write_text('not a report name')
        orphan = directory / f'99999999-{uuid.UUID(int=20)}-state.txt'
        orphan.write_text('incomplete pair')
        target = self.root / 'outside.txt'
        target.write_text('do not delete')
        linked = directory / f'99999999-{uuid.UUID(int=21)}-state.txt'
        linked.symlink_to(target)
        half = directory / f'99999999-{uuid.UUID(int=21)}-threads.txt'
        half.write_text('symlink pair is not eligible')
        self.failed_run()
        expected = set().union(*pairs[-5:], live, {unrelated, invalid, orphan, linked, half})
        self.assertEqual(set(directory.iterdir()), expected)
        self.assertEqual(target.read_text(), 'do not delete')
        self.failed_run(label='prune-repeat')
        self.assertEqual(set(directory.iterdir()), expected)

    def test_diagnostics_prune_preserves_unknown_liveness(self):
        directory = self.root / 'reports'
        pairs = [self.report_pair(directory, index) for index in range(8)]
        with patch.object(diagnostics.os, 'kill', side_effect=PermissionError('unknown')):
            diagnostics.prune(directory)
        self.assertEqual(set(directory.iterdir()), set().union(*pairs))

    def test_live_diagnostics_are_delivered_once_before_xcode_flush(self):
        process, ready = self.launch(mode='diagnostics', label='live-reports')
        self.wait_ready(ready)
        observed = b''
        deadline = time.monotonic() + 10
        while observed.count(b'END TIMEOUT DIAGNOSTIC') < 2 and time.monotonic() < deadline:
            if select.select([process.stdout], [], [], 0.1)[0]:
                chunk = os.read(process.stdout.fileno(), 8192)
                if not chunk:
                    break
                observed += chunk
        self.assertEqual(observed.count(b'END TIMEOUT DIAGNOSTIC'), 2, observed.decode())
        self.assertIsNone(process.poll(), 'reports were buffered until Xcode exited')
        self.assertNotIn(b'Xcode flushed', observed)
        (self.root / 'live-reports.release').touch()
        observed += process.communicate(timeout=10)[0]
        self.assertEqual(process.returncode, 65, observed.decode())
        self.assertIn(b'Xcode flushed host output', observed)
        self.assertEqual(observed.count(b'BEGIN TIMEOUT DIAGNOSTIC'), 2, observed.decode())
        self.assertEqual(observed.count(b'END TIMEOUT DIAGNOSTIC'), 2, observed.decode())
        self.assertEqual(observed.count(b'live timeout state'), 1)
        self.assertEqual(observed.count(b'live timeout threads'), 1)

    def test_relay_closed_reader_exits_without_traceback(self):
        directory = self.root / 'reports'
        directory.mkdir()
        ready = self.root / 'relay-ready'
        process = subprocess.Popen(['python3', '-u', str(SCRIPTS / 'test_diagnostics.py'),
                                    str(directory), str(os.getpid()), '--ready', str(ready)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.children.append(process.pid)
        self.addCleanup(process.stdout.close)
        self.addCleanup(process.stderr.close)
        deadline = time.monotonic() + 5
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists(), 'relay startup did not finish')
        process.stdout.close()
        self.report_pair(directory, 1)
        process.wait(timeout=5)
        error = process.stderr.read()
        self.assertEqual(process.returncode, 0, error.decode())
        self.assertEqual(error, b'', 'relay printed a traceback or shutdown exception')

    def test_sigkilled_wrapper_does_not_leave_relay_holding_stdout(self):
        process, ready = self.launch(mode="hang")
        child = self.wait_ready(ready)
        self.relay_pid(process.pid)
        process.kill()
        process.wait(timeout=3)
        # The fake builder is independent of the relay; stop it so only a leaked relay can hold stdout.
        os.kill(child["pid"], signal.SIGTERM)
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            self.fail("relay kept stdout open after its wrapper was SIGKILLed")


if __name__ == "__main__":
    unittest.main()
