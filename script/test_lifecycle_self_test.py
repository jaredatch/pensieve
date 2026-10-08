"""Exercise the real test wrapper with local Xcode stubs; never launch Xcode or touch live data."""
import contextlib
import fcntl
import io
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
        for name in ("test.sh", "test_diagnostics.py", "test_runs.py", "test_temp_cleanup.py"):
            source = SCRIPTS / name
            if source.exists():
                shutil.copy2(source, scripts / name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.stub("xcodegen", "#!/bin/sh\nexit 0\n")
        self.stub("xcrun", '#!/bin/sh\necho \'{"totalTestCount":1,"testFailures":[]}\'\n')
        self.stub("getconf", '#!/bin/sh\nprintf "%s\\n" "$TEST_LIFECYCLE_SYSTEM_TEMP"\n')
        self.stub("xcodebuild", """#!/usr/bin/env python3
import json, os, pathlib, sys, time, uuid
bundle = pathlib.Path(sys.argv[sys.argv.index('-resultBundlePath') + 1])
bundle.mkdir()
(bundle / 'marker').write_text('preserved evidence')
root = os.environ.get('TEST_RUNNER_PENSIEVE_TEST_TEMP_ROOT')
exists = bool(root and pathlib.Path(root).is_dir())
if exists:
    (pathlib.Path(root) / 'leftover-sync.lock').touch()
    if os.environ.get('TEST_LIFECYCLE_UNREADABLE_FIXTURE') == '1':
        blocked = pathlib.Path(root) / 'unreadable' / 'nested'
        blocked.mkdir(parents=True)
        (blocked / 'marker').write_text('left by a crashed test host')
        blocked.chmod(0)
        blocked.parent.chmod(0)
pathlib.Path(os.environ['TEST_LIFECYCLE_READY']).write_text(json.dumps({
    'pid': os.getpid(), 'directory': str(bundle.parent), 'fixture_root': root, 'fixture_root_exists': exists,
    'git_ceiling': os.environ.get('TEST_RUNNER_GIT_CEILING_DIRECTORIES')}))
if os.environ.get('TEST_LIFECYCLE_MODE') == 'cascade':
    directory = pathlib.Path(os.environ['TEST_RUNNER_PENSIEVE_TEST_DIAGNOSTICS_DIR'])
    directory.mkdir(parents=True, exist_ok=True)
    for index in range(7):
        identifier = str(os.getpid()) + '-' + str(uuid.UUID(int=index))
        for kind in ('state', 'threads'):
            path = directory / (identifier + '-' + kind + '.txt')
            path.write_text('cascade root cause ' + str(index))
            os.utime(path, (200 + index, 200 + index))
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
sys.exit(0 if os.environ.get('TEST_LIFECYCLE_MODE') == 'pass' else 65)
""")
        self.env = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"], XP_TEST_LOCK_HELD="1")
        self.env.pop("TEST_RUNNER_PENSIEVE_TEST_DIAGNOSTICS_DIR", None)
        self.env.pop("TEST_RUNNER_PENSIEVE_TEST_TEMP_ROOT", None)
        self.system_temp = self.root / "system-temp"
        self.system_temp.mkdir()
        self.env["TEST_LIFECYCLE_SYSTEM_TEMP"] = str(self.system_temp)
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

    def failed_run(self, label="failed", mode="fail"):
        process, _ = self.launch(label=label, mode=mode)
        output = process.communicate(timeout=10)[0].decode()
        self.assertEqual(process.returncode, 65, output)
        self.assertIn("PENSIEVE_TEST_COUNT=1", output)
        return output

    def test_failed_run_removes_emptied_directory(self):
        self.env['TEST_LIFECYCLE_UNREADABLE_FIXTURE'] = '1'
        self.stub('xcrun', '#!/bin/sh\necho \'{"totalTestCount":1,"testFailures":[{"testName":"FixtureCrash","failureText":"host crashed"}]}\'\n')
        output = self.failed_run()
        self.assertIn('test.sh: failed FixtureCrash: host crashed', output)
        bundles = list((self.root / "DerivedData/FailedRuns").glob("*.xcresult"))
        self.assertEqual(len(bundles), 1)
        self.assertEqual((bundles[0] / "marker").read_text(), "preserved evidence")
        self.assertEqual(list(self.runs.iterdir()), [], "failed run left an empty TestRuns directory")

    def test_pass_creates_forwards_and_removes_fixture_root(self):
        roots = []
        for index in range(2):
            self.env['TEST_LIFECYCLE_UNREADABLE_FIXTURE'] = str(index)
            process, ready = self.launch(mode="pass", label=f"pass-{index}")
            output = process.communicate(timeout=10)[0].decode()
            self.assertEqual(process.returncode, 0, output)
            self.assertIn("PENSIEVE_TEST_COUNT=1", output)
            observed = json.loads(ready.read_text())
            self.assertTrue(observed["fixture_root_exists"], "builder did not receive an existing fixture root")
            root = Path(observed["fixture_root"])
            self.assertEqual(observed["git_ceiling"], str(root), "Git discovery can escape into the checkout")
            self.assertEqual(root.parent, Path(observed["directory"]))
            self.assertFalse(root.exists(), "passing run kept its fixtures and sibling lock files")
            self.assertEqual(list(self.runs.iterdir()), [])
            roots.append(root)
        self.assertNotEqual(*roots, "two runs reused a fixture root")

    def test_fixture_cleanup_errors_preserve_count_bundle_and_exit_status(self):
        self.stub('chmod', '#!/bin/sh\nexit 23\n')
        self.stub('rm', '#!/bin/sh\ncase "$2" in */.diagnostics-ready) exec /bin/rm "$@";; esac\nexit 23\n')
        for mode, status in (('fail', 65), ('pass', 0)):
            with self.subTest(mode=mode):
                process, ready = self.launch(mode=mode, label='cleanup-error-' + mode)
                output = process.communicate(timeout=10)[0].decode()
                self.assertEqual(process.returncode, status, output)
                self.assertIn('PENSIEVE_TEST_COUNT=1', output)
                root = Path(json.loads(ready.read_text())['fixture_root'])
                self.assertTrue(root.is_dir(), 'failed cleanup must leave its fixtures for later pruning')
                if mode == 'fail':
                    self.assertIn('the failed run\'s result bundle is kept at', output)
                    bundles = list((self.root / 'DerivedData/FailedRuns').glob('*.xcresult'))
                    self.assertEqual(len(bundles), 1)
                    self.assertEqual((bundles[0] / 'marker').read_text(), 'preserved evidence')

    def test_sweep_removes_only_old_matching_temp_artifacts(self):
        old_empty, nonempty, young = [self.system_temp / str(uuid.UUID(int=index)).upper() for index in (10, 11, 12)]
        unrelated = self.system_temp / "ordinary-folder"
        lowercase = self.system_temp / "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        target = self.root / "outside-sweep"
        target.mkdir()
        linked = self.system_temp / str(uuid.UUID(int=13)).upper()
        linked.symlink_to(target, target_is_directory=True)
        regular = self.system_temp / str(uuid.UUID(int=14)).upper()
        regular.touch()
        for path in (old_empty, nonempty, young, unrelated, lowercase):
            path.mkdir()
        (nonempty / "marker").write_text("keep data")
        for path in (old_empty, nonempty, unrelated, lowercase, regular):
            os.utime(path, (1, 1))

        debug_temp = self.system_temp / "com.jaredatch.Pensieve.debug"
        debug_temp.mkdir()
        process_uuid = "ABCDEFAB-1234-5678-9ABC-DEF012345678"
        process_name = process_uuid + "-12345-aBc09F"
        process_old = debug_temp / process_name
        process_nonempty = debug_temp / (process_uuid + "-23456-abc123")
        process_young = debug_temp / (process_uuid + "-34567-ABC123")
        process_regular = debug_temp / (process_uuid + "-45678-abc123")
        process_regular.touch()
        process_linked = debug_temp / (process_uuid + "-56789-abc123")
        process_linked.symlink_to(target, target_is_directory=True)
        invalid_process_names = {
            process_uuid, process_uuid.lower() + "-12345-abc123",
            process_uuid + "-pid-abc123", process_uuid + "-12345-ghijk",
            process_uuid + "-12345-", process_uuid + "--abc123",
            process_name + "-extra", "ordinary-folder",
        }
        invalid_process_paths = {debug_temp / name for name in invalid_process_names}
        misplaced = self.system_temp / process_name
        other_app = self.system_temp / "com.jaredatch.Pensieve"
        other_app.mkdir()
        other_process = other_app / process_name
        nested_process = debug_temp / "ordinary-folder" / process_name
        for path in (process_old, process_nonempty, process_young, misplaced, other_process, *invalid_process_paths):
            path.mkdir()
        nested_process.mkdir()
        (process_nonempty / "marker").write_text("keep Foundation data")
        for path in (process_old, process_nonempty, process_regular, misplaced, other_process,
                     nested_process, *invalid_process_paths):
            os.utime(path, (1, 1))

        # Reap a real child, then prove its PID is dead. The live control is this test's PID.
        exited = subprocess.run(["python3", "-c", "import os; print(os.getpid())"],
                                capture_output=True, text=True, check=True)
        dead_pid = int(exited.stdout)
        with self.assertRaises(ProcessLookupError):
            os.kill(dead_pid, 0)
        icon_name = f"Pensieve1024x1024_NSAppearanceNameSystem_{process_uuid}-{dead_pid}-aBc09F.png"
        live_icon = icon_name.replace(f"-{dead_pid}-", f"-{os.getpid()}-")
        outside_file = self.root / "outside-file"
        outside_file.touch()
        (target / icon_name).write_text("keep outside icon")
        linked_targets = {target}
        cases = []

        def artifact(kind, label, remove=False, content=None, leaf_kind="file", extra=False,
                     young=False, leaf_name=None, directory_name=None, root_kind="directory"):
            index = 100 + len(cases)
            name = directory_name or (f"TemporaryDirectory.{index:06d}" if kind == "temporary"
                                      else str(uuid.UUID(int=index)).upper() if kind == "icon"
                                      else f"{process_uuid}-{20000 + index}-aBc09F")
            path = self.system_temp / name
            leaf_name = leaf_name or (".keep-directory" if kind == "temporary"
                                     else icon_name if kind == "icon" else "marker")
            if root_kind == "link":
                linked_target = target / f"{kind}-{index}"
                linked_target.mkdir()
                if kind in ("temporary", "icon"):
                    (linked_target / leaf_name).touch()
                os.utime(linked_target, (1, 1))
                linked_targets.add(linked_target)
                path.symlink_to(linked_target, target_is_directory=True)
            elif root_kind == "file":
                path.touch()
            else:
                path.mkdir()
                if content is not None:
                    leaf = path / leaf_name
                    if leaf_kind == "link":
                        leaf.symlink_to(outside_file)
                    elif leaf_kind == "directory":
                        leaf.mkdir()
                    elif leaf_kind == "fifo":
                        os.mkfifo(leaf)
                    else:
                        leaf.write_text(content)
                if extra:
                    (path / "other-entry").write_text("keep extra data")
            if not young:
                os.utime(path, (1, 1), follow_symlinks=False)
            cases.append((label, path, remove, root_kind))
            return path

        artifact("process", "populated process folder", content="keep process data")
        artifact("process", "young process folder", young=True)
        artifact("process", "process root file", root_kind="file")
        artifact("process", "process root symlink", root_kind="link")
        for name in invalid_process_names - {process_uuid, "ordinary-folder"}:
            artifact("process", "invalid process name " + name, directory_name=name)

        artifact("temporary", "empty replacement folder", remove=True)
        artifact("temporary", "empty replacement marker", remove=True, content="")
        artifact("temporary", "replacement marker beside another entry", content="", extra=True)
        artifact("temporary", "nonempty replacement marker", content="keep marker data")
        artifact("temporary", "replacement marker directory", content="", leaf_kind="directory")
        artifact("temporary", "replacement marker symlink", content="", leaf_kind="link")
        artifact("temporary", "replacement marker FIFO", content="", leaf_kind="fifo")
        artifact("temporary", "different replacement file", content="", leaf_name="keep-directory")
        artifact("temporary", "young empty replacement folder", young=True)
        artifact("temporary", "young replacement marker", content="", young=True)
        artifact("temporary", "replacement root symlink", root_kind="link")
        artifact("temporary", "replacement root file", root_kind="file")
        for suffix in ("", "abc12", "abc1234", "abc_12", "abc123-extra"):
            artifact("temporary", "invalid replacement suffix " + suffix,
                     directory_name="TemporaryDirectory." + suffix)

        artifact("icon", "dead process icon", remove=True, content="rendered icon")
        artifact("icon", "other appearance icon", remove=True, content="rendered dark icon",
                 leaf_name=icon_name.replace("NSAppearanceNameSystem", "NSAppearanceNameDarkAqua"))
        artifact("icon", "icon beside another entry", content="rendered icon", extra=True)
        artifact("icon", "icon directory", content="", leaf_kind="directory")
        artifact("icon", "icon symlink", content="", leaf_kind="link")
        artifact("icon", "icon FIFO", content="", leaf_kind="fifo")
        artifact("icon", "live process icon", content="live icon", leaf_name=live_icon)
        artifact("icon", "young icon", content="young icon", young=True)
        artifact("icon", "icon root symlink", root_kind="link")
        artifact("icon", "icon root file", root_kind="file")
        for name in ("Other1024x1024" + icon_name[len("Pensieve1024x1024"):],
                     icon_name.replace("NSAppearanceNameSystem", ""),
                     icon_name.replace(process_uuid, process_uuid.lower()),
                     icon_name.replace(f"-{dead_pid}-", "-pid-"),
                     icon_name.replace("-aBc09F.png", "-xyz.png"),
                     icon_name + ".extra"):
            artifact("icon", "invalid icon name " + name, content="keep foreign image", leaf_name=name)
        artifact("process", "icon inside a process folder", content="keep misplaced image", leaf_name=icon_name)

        def inventory(path):
            if path.is_symlink():
                return ("link", os.readlink(path))
            if path.is_file():
                return ("file", path.read_bytes())
            if path.is_dir():
                return {child.name: inventory(child) for child in path.iterdir()}
            return ("special", path.lstat().st_mode)

        preserved = {path: inventory(path) for _, path, remove, _ in cases if not remove}
        outside_before = {path: inventory(path) for path in linked_targets}
        self.failed_run()
        self.assertFalse(old_empty.exists())
        self.assertFalse(process_old.exists(), "old empty Foundation process folder survived")
        with self.subTest(kind="root process"):
            self.assertFalse(misplaced.exists(), "old empty root process folder survived")
        for label, path, remove, _ in cases:
            with self.subTest(kind=label):
                if remove:
                    self.assertFalse(path.exists(), label + " survived")
                else:
                    self.assertEqual(inventory(path), preserved[path], label + " changed")
        self.assertEqual(set(self.system_temp.iterdir()),
                         {nonempty, young, unrelated, lowercase, linked, regular, debug_temp, other_app, *preserved})
        self.assertEqual(set(debug_temp.iterdir()),
                         {process_nonempty, process_young, process_regular, process_linked, *invalid_process_paths})
        self.assertEqual((nonempty / "marker").read_text(), "keep data")
        self.assertEqual((process_nonempty / "marker").read_text(), "keep Foundation data")
        self.assertEqual(set(other_app.iterdir()), {other_process})
        self.assertTrue(nested_process.is_dir())
        self.assertTrue(target.is_dir())
        self.assertEqual(outside_file.read_bytes(), b"", "sweep changed a linked file target")
        for path, before in outside_before.items():
            self.assertEqual(inventory(path), before, "sweep followed a root symlink")

        # Inject an arriving entry at the last removal boundary, using only this fake temp root.
        import test_temp_cleanup as cleanup
        race_root = self.root / "race-temp"
        race_root.mkdir()
        raced = {race_root / str(uuid.UUID(int=300)).upper(), race_root / process_name,
                 race_root / "TemporaryDirectory.aBc123", race_root / str(uuid.UUID(int=301)).upper()}
        for path in raced:
            path.mkdir()
        (race_root / "TemporaryDirectory.aBc123" / ".keep-directory").touch()
        (race_root / str(uuid.UUID(int=301)).upper() / icon_name).write_text("raced icon")
        for path in raced:
            os.utime(path, (1, 1))
        rmdir = os.rmdir

        def add_entry_before_rmdir(name, *, dir_fd):
            path = race_root / name
            if path in raced:
                (path / "arrived").write_text("keep racing data")
            rmdir(name, dir_fd=dir_fd)

        with patch.object(cleanup.os, "rmdir", side_effect=add_entry_before_rmdir):
            cleanup.sweep(str(race_root))
        self.assertEqual(set(race_root.iterdir()), raced)
        for path in raced:
            self.assertEqual((path / "arrived").read_text(), "keep racing data")

        # A symlink at the debug folder itself must not send the sweep outside its scope.
        linked_temp = self.root / "linked-system-temp"
        linked_temp.mkdir()
        linked_target = target / "Foundation-items"
        linked_target.mkdir()
        linked_old = linked_target / process_name
        linked_old.mkdir()
        os.utime(linked_old, (1, 1))
        (linked_temp / debug_temp.name).symlink_to(linked_target, target_is_directory=True)
        self.env["TEST_LIFECYCLE_SYSTEM_TEMP"] = str(linked_temp)
        self.failed_run(label="linked-debug-temp")
        self.assertTrue(linked_old.is_dir(), "sweep followed the debug folder symlink")

    def abandoned_runs(self):
        self.runs.mkdir(parents=True, exist_ok=True)
        paths = []
        for index in range(8):
            path = self.runs / f"run.abandoned-{index}"
            (path / "run.xcresult").mkdir(parents=True)
            (path / "run.xcresult/marker").write_text("interrupted evidence")
            (path / "tmp").mkdir()
            (path / "tmp" / "leftover-sync.lock").touch()
            os.utime(path, (100 + index, 100 + index))
            paths.append(path)
        return paths

    def test_prunes_to_five_newest_interrupted_runs(self):
        abandoned = self.abandoned_runs()
        for path in abandoned:
            blocked = path / 'tmp' / 'unreadable' / 'nested'
            blocked.mkdir(parents=True)
            (blocked / 'marker').write_text('interrupted fixture')
            blocked.chmod(0)
            blocked.parent.chmod(0)
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
        outside.chmod(0o500)
        (outside / "marker").chmod(0o400)
        (abandoned[1] / 'tmp' / 'linked-outside').symlink_to(outside, target_is_directory=True)
        link = self.runs / "run.link"
        link.symlink_to(outside, target_is_directory=True)
        self.failed_run()
        self.assertEqual(set(self.runs.iterdir()), {protected, link, *abandoned[-5:]})
        self.assertEqual((outside / "marker").read_text(), "do not delete")
        self.assertEqual(outside.stat().st_mode & 0o777, 0o500, 'pruning changed a linked target directory mode')
        self.assertEqual((outside / 'marker').stat().st_mode & 0o777, 0o400, 'pruning changed a linked target file mode')

    def test_builder_lock_survives_wrapper_death_and_then_becomes_prunable(self):
        process, ready = self.launch(mode="hang", label="active")
        child = self.wait_ready(ready)
        self.relay_pid(process.pid)
        active = Path(child["directory"])
        fixture_root = Path(child["fixture_root"])
        self.assertTrue((fixture_root / "leftover-sync.lock").exists())
        process.kill()
        process.wait(timeout=3)
        held = subprocess.run(["/usr/bin/lockf", "-k", "-t", "0", str(active / ".active.lock"),
                               "/usr/bin/true"], capture_output=True)
        self.assertNotEqual(held.returncode, 0, "a killed wrapper released its live builder's lock")
        os.utime(active, (1, 1))
        abandoned = self.abandoned_runs()
        self.failed_run(label="during-live-builder")
        self.assertEqual(set(self.runs.iterdir()), {active, *abandoned[-5:]})
        self.assertTrue(fixture_root.exists(), "pruning deleted a live builder's fixtures")
        os.kill(child["pid"], signal.SIGTERM)
        process.communicate(timeout=3)
        self.failed_run(label="after-builder-exits")
        self.assertEqual(set(self.runs.iterdir()), set(abandoned[-5:]))
        self.assertFalse(fixture_root.exists(), "interrupted fixtures escaped TestRuns pruning")

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

    def assert_current_run_reports_are_retained(self):
        directory = self.root / 'DerivedData/TestDiagnostics'
        directory.mkdir(parents=True, exist_ok=True)
        before = set(directory.iterdir())
        self.failed_run(label='cascade', mode='cascade')
        current = set(directory.iterdir()) - before
        self.assertEqual(len(current), 14, 'the current cascade must retain all seven report pairs')
        self.assertEqual(sum(path.read_text() == 'cascade root cause 0' for path in current), 2,
                         'the first timeout is evidence of the root cause')

    def test_current_run_keeps_all_seven_timeout_pairs(self):
        self.assert_current_run_reports_are_retained()

    def test_prune_failure_is_a_warning_and_preserves_run_status(self):
        script = self.root / 'script/test_diagnostics.py'
        script.write_text("import sys\nif '--prune' in sys.argv:\n    print('prune inspection denied', file=sys.stderr)\n    sys.exit(23)\n" + script.read_text())
        output = self.failed_run()
        self.assertIn('prune inspection denied', output)
        self.assertIn('test.sh: warning: timeout diagnostics pruning failed; continuing the test run', output)
        self.assertEqual(list(self.runs.iterdir()), [], 'prune failure must not skip failed-run cleanup')
        self.assertEqual(len(list((self.root / 'DerivedData/FailedRuns').glob('*.xcresult'))), 1)

    def test_prune_inspection_errors_preserve_evidence_and_warn(self):
        directory = self.root / 'reports'
        pair = self.report_pair(directory, 1)
        error = None
        output = io.StringIO()
        with contextlib.redirect_stderr(output), patch.object(Path, 'is_file', side_effect=PermissionError('inspection denied')):
            try:
                diagnostics.prune(directory)
            except OSError as caught:
                error = caught
        self.assertIsNone(error, 'report inspection errors must only warn')
        self.assertEqual(set(directory.iterdir()), pair)
        self.assertIn('inspection denied', output.getvalue())

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

    def test_relay_warns_once_and_never_relays_initially_uninspectable_reports(self):
        directory = self.root / 'reports'
        old = sorted(self.report_pair(directory, 1))[0]
        is_file = Path.is_file
        for failed_inspections in (1, 3):
            with self.subTest(failed_inspections=failed_inspections):
                output, errors = io.StringIO(), io.StringIO()
                polls, inspections = 0, 0

                def inspect(path):
                    nonlocal inspections
                    if path == old:
                        inspections += 1
                        if inspections <= failed_inspections:
                            raise PermissionError('inspection denied')
                    return is_file(path)

                def poll(_delay):
                    nonlocal polls
                    polls += 1

                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors), \
                     patch.object(Path, 'is_file', inspect), patch.object(diagnostics.signal, 'signal'), \
                     patch.object(diagnostics.os, 'getppid', side_effect=lambda: 123 if polls < 3 else 0), \
                     patch.object(diagnostics.time, 'sleep', side_effect=poll):
                    diagnostics.relay(directory, 123)
                self.assertEqual(errors.getvalue().count('inspection denied'), 1,
                                 'inspect failures must warn only once per path')
                self.assertEqual(output.getvalue(), '', 'an old report must not be relayed after inspection recovers')

    def test_relay_retries_new_uninspectable_reports_and_warns_once(self):
        directory = self.root / 'reports'; directory.mkdir()
        for method in ('is_file', 'is_symlink'):
            for failed_inspections in (1, 3):
                with self.subTest(method=method, failures=failed_inspections):
                    for path in directory.iterdir(): path.unlink()
                    output, errors = io.StringIO(), io.StringIO()
                    polls, inspections = 0, 0
                    original = getattr(Path, method)
                    def inspect(path):
                        nonlocal inspections
                        if path.name.endswith('-state.txt'):
                            inspections += 1
                            if inspections <= failed_inspections: raise PermissionError('new inspection denied')
                        return original(path)
                    def poll(_delay):
                        nonlocal polls
                        polls += 1
                        if polls == 1: self.report_pair(directory, 1)
                    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors), \
                         patch.object(Path, method, inspect), patch.object(diagnostics.signal, 'signal'), \
                         patch.object(diagnostics.os, 'getppid', side_effect=lambda: 123 if polls < 6 else 0), \
                         patch.object(diagnostics.time, 'sleep', side_effect=poll):
                        diagnostics.relay(directory, 123)
                    self.assertEqual(errors.getvalue().count('new inspection denied'), 1)
                    self.assertEqual(output.getvalue().count('BEGIN TIMEOUT DIAGNOSTIC '), 2,
                                     'a newly arrived report must survive transient inspection failures')
                    self.assertEqual(output.getvalue().count('END TIMEOUT DIAGNOSTIC '), 2)

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
