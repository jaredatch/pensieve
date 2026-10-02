"""Exercise the real test wrapper with local Xcode stubs; never launch Xcode or touch live data."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

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
import json, os, pathlib, sys, time
bundle = pathlib.Path(sys.argv[sys.argv.index('-resultBundlePath') + 1])
bundle.mkdir()
(bundle / 'marker').write_text('preserved evidence')
pathlib.Path(os.environ['TEST_LIFECYCLE_READY']).write_text(json.dumps({'pid': os.getpid(), 'directory': str(bundle.parent)}))
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
        env = dict(self.env, TEST_LIFECYCLE_MODE=mode, TEST_LIFECYCLE_READY=str(ready))
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
