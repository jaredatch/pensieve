"""Exercise the built CLI's LaunchServices path using apps with disposable identities and no store."""
import json
import string
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import uuid


class CLILaunchTests(unittest.TestCase):
    binary = None

    @classmethod
    def setUpClass(cls):
        cls.compilation = tempfile.TemporaryDirectory(prefix='launch-')
        cls.fixture = Path(cls.compilation.name) / 'Fixture'
        subprocess.run(['xcrun', 'swiftc', str(Path(__file__).with_name('cli_launch_fixture.swift')),
                        '-o', str(cls.fixture)], check=True, capture_output=True, timeout=60)

    @classmethod
    def tearDownClass(cls):
        cls.compilation.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='c')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle_id = 'p58.' + uuid.uuid4().hex[:8]
        self.app = self.make_app('Requested', self.bundle_id)
        self.environment = {k: v for k, v in os.environ.items() if k not in ('CFFIXED_USER_HOME', 'PENSIEVE_DOGFOOD')}
        self.environment['HOME'] = pwd.getpwuid(os.getuid()).pw_dir
        self.pids = set()
        self.addCleanup(self.stop_apps)

    def make_app(self, name, bundle_id):
        app = self.root / (name + '.app')
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Helpers').mkdir()
        shutil.copy2(self.fixture, app / 'Contents/MacOS/Fixture')
        shutil.copy2(self.binary, app / 'Contents/Helpers/pensieve')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'Fixture',
            'CFBundleShortVersionString': '0.0', 'CFBundlePackageType': 'APPL'}))
        return app

    def state(self, app=None):
        app = app or self.app
        path = app.with_name(app.name + '.json')
        return json.loads(path.read_text()) if path.exists() else None

    def stop_apps(self):
        for app in self.root.glob('*.app'):
            if state := self.state(app):
                self.pids.add(state['pid'])
        for pid in self.pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    def run_cli(self, *arguments, environment=None, code=0):
        args = [str(self.app / 'Contents/Helpers/pensieve'), *arguments, '--json', '--app-support', str(self.root)]
        result = subprocess.run(args, env=environment or self.environment, input='', text=True,
                                capture_output=True, timeout=12)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def wait_for_state(self, app):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if state := self.state(app):
                self.pids.add(state['pid'])
                return state
            time.sleep(.01)
        self.fail('Fixture app did not report startup')

    def peer_after_launch(self, bundle=None):
        failures, requests = [], []
        def serve():
            try:
                self.wait_for_state(self.app)
                with socket.socket(socket.AF_UNIX) as listener:
                    endpoint = self.root / (self.bundle_id + '.sock')
                    endpoint.unlink(missing_ok=True)
                    listener.bind(str(endpoint)); listener.listen(1); listener.settimeout(5)
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(5)
                        connection.sendall(json.dumps({'bundlePath': str(bundle or self.app),
                            'protocolVersion': 1, 'appVersion': '0.0'}).encode() + b'\n')
                        if line := connection.makefile('rb').readline():
                            requests.append(json.loads(line))
                            connection.sendall(json.dumps({'envelope': {'schema': 1, 'ok': True,
                                'data': ['launched by path']}, 'exitCode': 0}).encode() + b'\n')
            except BaseException as error:
                failures.append(error)
        worker = threading.Thread(target=serve, daemon=True); worker.start()
        def finish():
            worker.join(8)
            self.assertFalse(worker.is_alive(), 'post-launch peer never finished')
            self.assertEqual(failures, [])
        return requests, finish

    def test_launch_by_path_is_background_and_reaches_the_new_socket(self):
        stale = socket.socket(socket.AF_UNIX)
        stale.bind(str(self.root / (self.bundle_id + '.sock'))); stale.close()
        frontmost = subprocess.check_output([str(self.fixture), '--frontmost'], text=True).strip()
        requests, finish = self.peer_after_launch()
        try:
            self.assertEqual(self.run_cli('skill', 'list')['data'], ['launched by path'])
        finally:
            finish()
        state = self.wait_for_state(self.app)
        self.assertEqual(state['path'], str(self.app))
        self.assertEqual(state['arguments'][1:], ['--background'])
        self.assertEqual(state['windows'], 0)
        self.assertFalse(state['active'])
        self.assertEqual(subprocess.check_output([str(self.fixture), '--frontmost'], text=True).strip(), frontmost)
        self.assertEqual([r['command'] for r in requests], ['skill list'])

    def test_launch_timeout_and_late_wrong_app_are_bounded(self):
        start = time.monotonic()
        error = self.run_cli('skill', 'list', code=3)['error']
        self.assertEqual(error['code'], 'app_starting')
        self.assertTrue(error['retryable'])
        self.assertLess(time.monotonic() - start, 5)
        self.wait_for_state(self.app)
        self.assertEqual(self.run_cli('skill', 'list', code=3)['error']['code'], 'app_starting')
        self.assertEqual(self.state()['reopens'], 0, 'an already starting app must not receive a reopen')
        requests, finish = self.peer_after_launch(bundle=self.root / 'Wrong.app')
        try:
            self.assertEqual(self.run_cli('skill', 'list', code=3)['error']['code'], 'wrong_app')
        finally:
            finish()
        self.assertEqual(requests, [])

    def test_redirected_homes_and_dogfood_never_launch(self):
        for key in ('HOME', 'CFFIXED_USER_HOME'):
            with self.subTest(key=key):
                env = dict(self.environment, **{key: str(self.root)})
                error = self.run_cli('skill', 'list', environment=env, code=3)['error']
                self.assertEqual(error['code'], 'app_unavailable')
                self.assertIn('dogfood.sh', error['hint'])
                self.assertIsNone(self.state())
        info_path = self.app / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes()); info['CFBundleIdentifier'] += '.dogfood'
        info_path.write_bytes(plistlib.dumps(info))
        error = self.run_cli('skill', 'list', code=3)['error']
        self.assertEqual(error['code'], 'app_unavailable')
        self.assertIsNone(self.state())

    def test_production_normal_and_background_launch_present_only_the_requested_window(self):
        app = self.root / 'Production.app'
        shutil.copytree(self.binary.parent.parent.parent, app, symlinks=True)
        info_path = app / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes()); info['CFBundleIdentifier'] = 'p58'
        info_path.write_bytes(plistlib.dumps(info))
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        # One component under TMPDIR keeps the real app's home-derived socket within Darwin's bound.
        # Each candidate is exclusively created and owned by this test; no fixed /tmp path is used.
        home = None
        for name in string.ascii_letters:
            candidate = Path(os.environ.get('TMPDIR', tempfile.gettempdir())) / name
            try:
                candidate.mkdir(); home = candidate; break
            except FileExistsError:
                continue
        self.assertIsNotNone(home, 'no isolated home slot is available')
        self.addCleanup(lambda: shutil.rmtree(home, ignore_errors=True))
        self.addCleanup(lambda: subprocess.run(['/usr/bin/defaults', 'delete', 'p58'], capture_output=True))
        env = dict(self.environment, HOME=str(home), CFFIXED_USER_HOME=str(home), PENSIEVE_DOGFOOD='1')
        support = home / 'Library/Application Support/Pensieve'
        self.assertLess(len(str(support / 'p58.sock').encode()), 104, 'TMPDIR is too long for the production socket')
        for arguments in (['--background'], []):
            with self.subTest(arguments=arguments):
                with (self.root / 'production.log').open('w') as log:
                    process = subprocess.Popen([str(app / 'Contents/MacOS/Pensieve'), *arguments], env=env,
                                               stdout=log, stderr=log)
                    try:
                        deadline = time.monotonic() + 8
                        while time.monotonic() < deadline:
                            result = subprocess.run([str(app / 'Contents/Helpers/pensieve'), 'skill', 'list', '--json',
                                '--app-support', str(support)], env=env, capture_output=True, text=True, timeout=5)
                            if json.loads(result.stdout)['ok']:
                                break
                            time.sleep(.02)
                        else:
                            self.fail('isolated production app did not become ready: ' + result.stdout)
                        deadline = time.monotonic() + 2
                        seen_window = False
                        while time.monotonic() < deadline:
                            count = int(subprocess.check_output([str(self.fixture), '--windows', str(process.pid)], text=True))
                            seen_window = seen_window or count > 0
                            if seen_window:
                                break
                            time.sleep(.02)
                        self.assertEqual(seen_window, not arguments, 'production scene launch behavior')
                    finally:
                        process.terminate(); process.wait(timeout=5)

    def test_dogfood_cli_reaches_the_fenced_apps_store(self):
        from dogfood_self_test import DogfoodTestCase, SCRIPT
        case = DogfoodTestCase(); case.setUp()
        self.addCleanup(case.doCleanups)
        executable = case.app / 'Contents/MacOS/Pensieve'
        executable.write_text("""#!/usr/bin/python3
import json, os, pathlib, socket
home=pathlib.Path(os.environ['HOME'])
app=pathlib.Path(__file__).resolve().parents[2]
with socket.socket(socket.AF_UNIX) as listener:
    listener.bind(str(home/'com.jaredatch.Pensieve.dogfood.sock'))
    listener.listen(1); listener.settimeout(12)
    client,_=listener.accept()
    with client:
        client.settimeout(5)
        client.sendall(json.dumps({'bundlePath':str(app),'protocolVersion':1,'appVersion':'0.0'}).encode()+b'\\n')
        json.loads(client.makefile('rb').readline())
        client.sendall(json.dumps({'envelope':{'schema':1,'ok':True,'data':(home/'library.txt').read_text()},
            'exitCode':0}).encode()+b'\\n')
""")
        helpers=case.app/'Contents/Helpers'; helpers.mkdir()
        shutil.copy2(self.binary,helpers/'pensieve')
        launched=case.run_script('clean')
        self.assertEqual(launched.returncode,0,launched.stdout+launched.stderr)
        (case.fake_home / 'library.txt').write_text('sandbox library')
        result=subprocess.run(['/bin/bash',str(SCRIPT),'--cli',str(case.app),'skill','list','--json',
            '--app-support',str(case.fake_home)],env=case.env,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(json.loads(result.stdout)['data'],'sandbox library')

    def test_other_running_copy_is_refused_before_launchservices_reopens_it(self):
        other = self.make_app('Other', self.bundle_id)
        process = subprocess.Popen([str(other / 'Contents/MacOS/Fixture'), '--background'], env=self.environment,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: process.wait(timeout=5))
        self.addCleanup(process.terminate)
        self.wait_for_state(other)
        error = self.run_cli('skill', 'list', code=3)['error']
        self.assertEqual(error['code'], 'wrong_app')
        self.assertIn(str(other), error['message'])
        self.assertIsNone(self.state(self.app))
        self.assertEqual(self.state(other)['reopens'], 0)
