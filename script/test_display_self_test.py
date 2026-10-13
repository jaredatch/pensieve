"""Run test.sh with real temporary locks and fake display/Xcode commands."""
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


class DisplayLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pensieve-test-display-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.groups = {}
        scripts = self.root / "script"
        scripts.mkdir()
        source = Path(__file__).resolve().parent
        for name in ("test.sh", "test_runs.py", "test_temp_cleanup.py", "check-live-defaults.py",
                     "runtime-path-members.json", "check-path-syntax.py"):
            shutil.copy2(source / name, scripts / name)
        for name in ("Pensieve", "PensieveDaemon", "bin"):
            (self.root / name).mkdir()
        self.events = self.root / "events.jsonl"
        self.lock = self.root / ".local/state/execplan/test.lock"
        self.lock.parent.mkdir(parents=True)
        self.env = dict(os.environ, HOME=str(self.root), PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                        DISPLAY_TEST_ROOT=str(self.root))
        for name in ("XP_TEST_LOCK_HELD", "XP_TEST_FULL_HELD", "XP_TEST_T0",
                     "TEST_RUNNER_PENSIEVE_TEST_WINDOW_SAMPLE_DIR", "TEST_RUNNER_PENSIEVE_TEST_DIAGNOSTICS_DIR"):
            self.env.pop(name, None)
        self.stub("xcodegen", "#!/bin/sh\nexit 0\n")
        self.stub("getconf", "#!/bin/sh\nexit 1\n")
        self.stub("xcrun", '#!/bin/sh\necho \'{"totalTestCount":1,"testFailures":[]}\'\n')
        recorder = '''import fcntl, json, os, pathlib, sys, time
root = pathlib.Path(os.environ['DISPLAY_TEST_ROOT'])
def record(name):
    with (root / '.local/state/execplan/test.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            held = False
        except BlockingIOError:
            held = True
    with (root / 'events.jsonl').open('a') as events:
        events.write(json.dumps({'name': name, 'locked': held}) + '\\n')
'''
        self.stub("pmset", "#!/usr/bin/env python3\n" + recorder + '''
assert sys.argv[1:] == ['displaysleepnow'], sys.argv
record('sleep')
sys.exit(23 if os.environ.get('DISPLAY_TEST_SLEEP_FAIL') else 0)
''')
        self.stub("caffeinate", "#!/usr/bin/env python3\n" + recorder + '''
assert sys.argv[1:] == ['-u', '-t', '5'], sys.argv
record('wake')
''')
        self.stub("xcodebuild", "#!/usr/bin/env python3\n" + recorder + '''
bundle = pathlib.Path(sys.argv[sys.argv.index('-resultBundlePath') + 1])
bundle.mkdir()
record('tests')
if os.environ['DISPLAY_TEST_MODE'] == 'hold':
    while True:
        time.sleep(0.02)
sys.exit(65 if os.environ['DISPLAY_TEST_MODE'] == 'fail' else 0)
''')
        (scripts / "test_diagnostics.py").write_text('''import os, pathlib, sys, time
if '--prune' in sys.argv:
    sys.exit(0)
root = pathlib.Path(os.environ['DISPLAY_TEST_ROOT'])
(root / 'relay.pid').write_text(str(os.getpid()))
pathlib.Path(sys.argv[sys.argv.index('--ready') + 1]).touch()
while True:
    time.sleep(0.02)
''')

    def stub(self, name, content):
        path = self.root / "bin" / name
        path.write_text(content)
        path.chmod(0o755)

    def launch(self, mode="pass", sample="samples", filtered=False):
        env = dict(self.env, DISPLAY_TEST_MODE=mode)
        if sample is not None:
            env["TEST_RUNNER_PENSIEVE_TEST_WINDOW_SAMPLE_DIR"] = sample
        args = [str(self.root / "script/test.sh")]
        if filtered:
            args += ["--filter", "RuntimePathGuardTests"]
        process = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        self.groups[process] = mode
        self.addCleanup(process.stdout.close)
        self.addCleanup(lambda: process.wait(timeout=5))
        self.addCleanup(self.stop_group, process)
        return process

    def stop_group(self, process):
        mode = self.groups.pop(process, None)
        if mode is None or (mode != "hold" and process.poll() is not None):
            return
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def observed(self):
        return [json.loads(line) for line in self.events.read_text().splitlines()] if self.events.exists() else []

    def wait_for(self, predicate, message):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail(message)

    def assert_lifecycle(self):
        events = self.observed()
        self.assertEqual([event["name"] for event in events], ["sleep", "tests", "wake"],
                         "sampled run must sleep before tests and wake when it ends")
        self.assertTrue(all(event["locked"] for event in events), "display ownership must stay inside the test lock")
        pid = int((self.root / "relay.pid").read_text())
        with self.assertRaises(ProcessLookupError, msg="run cleanup left its diagnostic relay alive"):
            os.kill(pid, 0)

    def test_sampled_pass_and_failure_sleep_then_wake(self):
        for mode, status in (("pass", 0), ("fail", 65)):
            with self.subTest(mode=mode):
                self.events.unlink(missing_ok=True)
                process = self.launch(mode=mode)
                output = process.communicate(timeout=10)[0].decode()
                self.assert_lifecycle()
                self.assertEqual(process.returncode, status, output)

    def test_sampled_interrupts_wake_and_stop_relay(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=sig.name):
                self.events.unlink(missing_ok=True)
                process = self.launch(mode="hold")
                try:
                    self.wait_for(lambda: any(event["name"] == "tests" for event in self.observed()), "tests never started")
                    process.send_signal(sig)
                    process.wait(timeout=5)
                    self.assert_lifecycle()
                    self.assertEqual(process.returncode, 128 + sig)
                finally:
                    self.stop_group(process)
                    process.communicate(timeout=5)

    def test_unsampled_runs_never_touch_display(self):
        for sample in (None, ""):
            with self.subTest(sample=sample):
                self.events.unlink(missing_ok=True)
                process = self.launch(sample=sample)
                output = process.communicate(timeout=10)[0].decode()
                self.assertEqual(process.returncode, 0, output)
                self.assertEqual([event["name"] for event in self.observed()], ["tests"],
                                 "an unsampled run must never sleep or wake the display")

    def test_sleep_failure_refuses_tests_and_still_wakes(self):
        self.env["DISPLAY_TEST_SLEEP_FAIL"] = "1"
        process = self.launch()
        output = process.communicate(timeout=10)[0].decode()
        self.assertNotEqual(process.returncode, 0, output)
        self.assertIn("test.sh: could not sleep the display for window sampling", output)
        events = self.observed()
        self.assertEqual([event["name"] for event in events], ["sleep", "wake"], "sleep failure must refuse sampled tests")
        self.assertTrue(all(event["locked"] for event in events))

    def test_queued_sampled_run_leaves_display_alone_until_lock_acquired(self):
        for filtered, lock_name in ((False, "test-full.lock"), (False, "test.lock"), (True, "test.lock")):
            with self.subTest(filtered=filtered, lock=lock_name):
                self.events.unlink(missing_ok=True)
                process = None
                try:
                    with (self.lock.parent / lock_name).open("a") as lock:
                        fcntl.flock(lock, fcntl.LOCK_EX)
                        process = self.launch(filtered=filtered)
                        def queued():
                            if select.select([process.stdout], [], [], 0)[0]:
                                expected = b"waiting behind another full suite" if lock_name == "test-full.lock" else \
                                    b"waiting for this machine's test lock"
                                return expected in process.stdout.readline()
                            return False
                        self.wait_for(queued, "wrapper never queued for its lock")
                        self.assertEqual(self.observed(), [], "queued sampled run touched the display before owning the lock")
                    output = process.communicate(timeout=10)[0].decode()
                    self.assertEqual(process.returncode, 0, output)
                    self.assert_lifecycle()
                finally:
                    if process is not None:
                        self.stop_group(process)
                        process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
