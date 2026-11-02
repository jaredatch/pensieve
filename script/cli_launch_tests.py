"""Exercise the built CLI's LaunchServices path using apps with disposable identities and no store."""
import json
import errno
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
        cls.addClassCleanup(cls.compilation.cleanup)
        # All three compiler states share 60 s of the Swift probe's 160 s budget.
        cls.compile_deadline = time.monotonic() + 60
        cls.fixture = Path(cls.compilation.name) / 'Fixture'
        cls.compile_support('Swift launch fixture', ['xcrun', 'swiftc', str(Path(__file__).with_name('cli_launch_fixture.swift')),
                        '-o', str(cls.fixture)])
        # The fixture app has no store. Give only its CLI a disposable passwd home so the real
        # launch guard and default endpoint can run without touching the user's App Support.
        source = Path(cls.compilation.name) / 'home.c'
        source.write_text(r'''
#include <pwd.h>
#include <stdlib.h>
static struct passwd *fixture_home(uid_t uid) {
    struct passwd *entry = getpwuid(uid);
    const char *home = getenv("CLI_FIXTURE_PASSWD_HOME");
    if (!entry || !home) return entry;
    static struct passwd copy; copy = *entry; copy.pw_dir = (char *)home; return &copy;
}
__attribute__((used, section("__DATA,__interpose"))) static struct {
    const void *replacement; const void *original;
} replacement = {fixture_home, getpwuid};
''')
        cls.home_query = Path(cls.compilation.name) / 'home.dylib'
        cls.compile_support('passwd home interposer',
                            ['xcrun', 'clang', '-dynamiclib', str(source), '-o', str(cls.home_query)])

        configuration_source = Path(cls.compilation.name) / 'configuration.m'
        configuration_source.write_text(r'''
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
static void (*original)(id, SEL, NSURL *, NSWorkspaceOpenConfiguration *, void (^)(NSRunningApplication *, NSError *));
static void capture(id workspace, SEL selector, NSURL *url, NSWorkspaceOpenConfiguration *config,
                    void (^completion)(NSRunningApplication *, NSError *)) {
    const char *receipt = getenv("CLI_FIXTURE_LAUNCH_CONFIGURATION");
    if (receipt) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"activates": @(config.activates)} options:0 error:nil];
        [data writeToFile:[NSString stringWithUTF8String:receipt] atomically:YES];
    }
    original(workspace, selector, url, config, completion);
}
__attribute__((constructor)) static void install(void) {
    Method method = class_getInstanceMethod([NSWorkspace class], @selector(openApplicationAtURL:configuration:completionHandler:));
    original = (void *)method_setImplementation(method, (IMP)capture);
}
''')
        cls.configuration_probe = Path(cls.compilation.name) / 'configuration.dylib'
        cls.compile_support('launch configuration interposer',
                            ['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                             str(configuration_source), '-o', str(cls.configuration_probe)])

    @classmethod
    def compile_support(cls, state, command):
        remaining = cls.compile_deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(f'wait=compile {state}; state=not started; shared 60 s compile budget expired')
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=remaining)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f'wait=compile {state}; state=compiler still running; '
                               f'shared 60 s compile budget expired; stdout={error.stdout!r}; stderr={error.stderr!r}') from error
        if result.returncode:
            raise RuntimeError(f'wait=compile {state}; state=exit {result.returncode}; '
                               f'stdout={result.stdout}; stderr={result.stderr}')

    @classmethod
    def tearDownClass(cls):
        cls.compilation.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='c')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle_id = 'p58.' + uuid.uuid4().hex[:8]
        self.app = self.make_app('Requested', self.bundle_id)
        self.environment = {k: v for k, v in os.environ.items()
                            if k not in ('CFFIXED_USER_HOME', 'PENSIEVE_DOGFOOD', 'PENSIEVE_SOCKET_DIRECTORY',
                                         'XCTestConfigurationFilePath', 'XCTestBundlePath', 'DYLD_INSERT_LIBRARIES')}
        self.environment['HOME'] = pwd.getpwuid(os.getuid()).pw_dir
        self.environment['LLVM_PROFILE_FILE'] = str(self.root / 'launch-%p.profraw')
        home = self.root / 'h'
        for directory in (home, self.root / 'd'):
            support = directory / 'Library/Application Support/Pensieve'
            support.parent.mkdir(parents=True)
            support.symlink_to(self.root)
        self.launch_environment = dict(self.environment, HOME=str(home), CFFIXED_USER_HOME=str(home),
            CLI_FIXTURE_PASSWD_HOME=str(home), DYLD_INSERT_LIBRARIES=str(self.home_query),
            PENSIEVE_SOCKET_DIRECTORY=str(self.root))
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
            self.stop_pid(pid)

    @staticmethod
    def stop_pid(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(.02)

    def run_cli(self, *arguments, environment=None, code=0, distributed=False):
        args = [str(self.app / 'Contents/Helpers/pensieve'), *arguments, '--json']
        if distributed:
            args += ['--app-support', str(self.root)]
        result = subprocess.run(args, env=environment or (self.environment if distributed else self.launch_environment),
                                input='', text=True,
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

    def peer_after_launch(self, bundle=None, reply_delay=0, readiness=None):
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
                            'protocolVersion': 1, 'appVersion': '0.0',
                            'supportsReadiness': readiness is not None}).encode() + b'\n')
                        if line := connection.makefile('rb').readline():
                            requests.append(json.loads(line))
                            if readiness == 'starting':
                                time.sleep(3.3)
                                return
                            if readiness == 'ready':
                                connection.sendall(b'{"ready":true}\n')
                            time.sleep(reply_delay)
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
        before_detail = self.frontmost_detail()
        receipt = self.root / 'configuration.json'
        self.launch_environment['CLI_FIXTURE_LAUNCH_CONFIGURATION'] = str(receipt)
        self.launch_environment['DYLD_INSERT_LIBRARIES'] += ':' + str(self.configuration_probe)
        requests, finish = self.peer_after_launch()
        try:
            self.assertEqual(self.run_cli('skill', 'list')['data'], ['launched by path'])
        finally:
            finish()
        state = self.wait_for_state(self.app)
        self.assertEqual(Path(state['path']).resolve(), self.app.resolve())
        self.assertEqual(state['arguments'][1:], ['--background'])
        self.assertEqual(state['windows'], 0)
        current = subprocess.check_output([str(self.fixture), '--frontmost'], text=True).strip()
        detail = (f'before: {before_detail}; after: {self.frontmost_detail()}; '
                  f"the app saw frontmost {state.get('frontmost')} with policy {state.get('policy')}")
        self.assert_launch_activation(state, frontmost, current, json.loads(receipt.read_text()), detail)
        self.assertEqual([r['command'] for r in requests], ['skill list'])

    def frontmost_detail(self):
        return subprocess.check_output([str(self.fixture), '--frontmost-detail'], text=True).strip()

    # On GitHub's macOS runner the launched app comes to the front even though the launch asks it not to,
    # with Finder in front beforehand (#174). There only the request is checked; a real Mac checks both.
    OBSERVES_ACTIVATION = os.environ.get('GITHUB_ACTIONS') != 'true'

    def assert_launch_activation(self, state, frontmost, current, configuration, detail='', observe=None):
        receipt = f'frontmost pid before launch: {frontmost}; {detail}'
        self.assertFalse(configuration['activates'], receipt)
        if observe is None:
            observe = self.OBSERVES_ACTIVATION
        if observe and int(frontmost) > 0:
            self.assertFalse(state['active'], receipt)
            self.assertEqual(current, frontmost, receipt)

    def test_activation_assertions_distinguish_an_empty_desktop(self):
        self.assert_launch_activation({'active': True}, '-1', '123', {'activates': False}, observe=True)
        for state, previous, current, configuration in [
                ({'active': True}, '42', '42', {'activates': False}),
                ({'active': False}, '42', '43', {'activates': False}),
                ({'active': False}, '-1', '123', {'activates': True})]:
            with self.assertRaisesRegex(AssertionError, f'frontmost pid before launch: {previous}'):
                self.assert_launch_activation(state, previous, current, configuration, observe=True)

    def test_activation_on_the_runner_checks_only_the_request(self):
        self.assert_launch_activation({'active': True}, '42', '43', {'activates': False}, observe=False)
        with self.assertRaisesRegex(AssertionError, 'frontmost pid before launch: 42'):
            self.assert_launch_activation({'active': False}, '42', '42', {'activates': True}, observe=False)

    def test_launch_timeout_and_late_wrong_app_are_bounded(self):
        start = time.monotonic()
        error = self.run_cli('skill', 'list', code=3)['error']
        self.assertEqual(error['code'], 'app_starting')
        self.assertTrue(error['retryable'])
        endpoint = self.root / (self.bundle_id + '.sock')
        self.assertEqual(Path(error['message'].split('starting. ', 1)[1].split(': ', 1)[0]).resolve(), endpoint.resolve())
        self.assertIn(os.strerror(errno.ENOENT), error['message'])
        self.assertLess(time.monotonic() - start, 5)
        self.wait_for_state(self.app)
        stale = socket.socket(socket.AF_UNIX)
        stale.bind(str(endpoint)); stale.close()
        error = self.run_cli('skill', 'list', code=3)['error']
        self.assertEqual(error['code'], 'app_starting')
        self.assertTrue(error['retryable'])
        self.assertEqual(Path(error['message'].split('starting. ', 1)[1].split(': ', 1)[0]).resolve(), endpoint.resolve())
        self.assertIn(os.strerror(errno.ECONNREFUSED), error['message'])
        self.assertEqual(self.state()['reopens'], 0, 'an already starting app must not receive a reopen')
        requests, finish = self.peer_after_launch(bundle=self.root / 'Wrong.app')
        try:
            self.assertEqual(self.run_cli('skill', 'list', code=3)['error']['code'], 'wrong_app')
        finally:
            finish()
        self.assertEqual(requests, [])
        for readiness in (None, 'ready', 'starting'):
            with self.subTest(readiness=readiness):
                requests, finish = self.peer_after_launch(reply_delay=3.3, readiness=readiness)
                try:
                    if readiness == 'starting':
                        start = time.monotonic()
                        error = self.run_cli('skill', 'list', code=3)['error']
                        self.assertEqual(error['code'], 'app_starting')
                        self.assertTrue(error['retryable'])
                        self.assertLess(time.monotonic() - start, 5)
                    else:
                        self.assertEqual(self.run_cli('skill', 'list')['data'], ['launched by path'],
                                         'a ready command retains its own reply timeout')
                finally:
                    finish()

    def test_redirected_homes_and_dogfood_never_launch(self):
        error = self.run_cli('skill', 'list', distributed=True, code=3)['error']
        self.assertEqual(error['code'], 'app_unavailable')
        self.assertIn('isolated', error['hint'])
        self.assertIsNone(self.state(), '--app-support must never start an app against the real store')
        for key in ('HOME', 'CFFIXED_USER_HOME'):
            with self.subTest(key=key):
                env = dict(self.launch_environment, **{key: str(self.root / 'd')})
                error = self.run_cli('skill', 'list', environment=env, code=3)['error']
                self.assertEqual(error['code'], 'app_unavailable')
                self.assertIn('dogfood.sh', error['hint'])
                self.assertIsNone(self.state())
                long_home = str(self.root / ('long-home-' * 15))
                long_env = dict(env, CFFIXED_USER_HOME=long_home)
                long_env.pop('PENSIEVE_SOCKET_DIRECTORY', None)
                unavailable = self.run_cli('skill', 'list', environment=long_env, code=3)['error']
                self.assertIn('104-byte limit', unavailable['message'])
                self.assertEqual(unavailable['hint'], error['hint'], 'connect failures retain the isolated-home advice')
                self.assertIsNone(self.state())
        info_path = self.app / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes()); info['CFBundleIdentifier'] += '.dogfood'
        info_path.write_bytes(plistlib.dumps(info))
        error = self.run_cli('skill', 'list', code=3)['error']
        self.assertEqual(error['code'], 'app_unavailable')
        self.assertIsNone(self.state())

        info['CFBundleIdentifier'] = 'p58.' + ('long-' * 24) + '.dogfood'
        info_path.write_bytes(plistlib.dumps(info))
        unavailable = self.run_cli('skill', 'list', code=3)['error']
        self.assertIn('104-byte limit', unavailable['message'])
        self.assertEqual(unavailable['hint'], error['hint'], 'an overlong dogfood endpoint must still recommend the fence')
        self.assertIsNone(self.state())

    def test_production_normal_and_background_launch_present_only_the_requested_window(self):
        self.assert_production_windows(reopen=False)

    def test_background_production_reopens_from_the_dock(self):
        self.assert_production_windows(reopen=True)

    def production_command(self, wait, command, deadline, state, *, env=None, query_bound=5):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            self.fail(f'wait={wait}; state={state}; deadline expired before query')
        try:
            return subprocess.run(command, env=env, capture_output=True, text=True,
                                  timeout=min(query_bound, remaining))
        except subprocess.TimeoutExpired as error:
            self.fail(f'wait={wait}; state={state}; query exceeded {min(query_bound, remaining):.2f} s; '
                      f'stdout={error.stdout!r}; stderr={error.stderr!r}')

    def production_window_count(self, process, wait, deadline, last_count):
        state = f'pid={process.pid} exit={process.poll()} lastWindowCount={last_count}'
        result = self.production_command(wait, [str(self.fixture), '--windows', str(process.pid)],
                                         deadline, state, query_bound=3)
        if result.returncode:
            self.fail(f'wait={wait}; state={state}; query exit={result.returncode}; '
                      f'stdout={result.stdout}; stderr={result.stderr}')
        try:
            return int(result.stdout)
        except ValueError:
            self.fail(f'wait={wait}; state={state}; invalid window count={result.stdout!r}; stderr={result.stderr}')

    def clear_production_defaults(self):
        self.production_command('p58 defaults cleanup', ['/usr/bin/defaults', 'delete', 'p58'],
                                time.monotonic() + 3, 'removing the owned production test domain', query_bound=3)

    def assert_production_windows(self, reopen):
        # Shared across preparation and both launch modes: 60 s compiles + 75 s helper +
        # at most two 5 s terminate/reaps + 3 s defaults cleanup = 148 s, leaving 12 s for Python/setup.
        helper_deadline = time.monotonic() + 75
        app = self.root / 'Production.app'
        shutil.copytree(self.binary.parent.parent.parent, app, symlinks=True)
        info_path = app / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes()); info['CFBundleIdentifier'] = 'p58'
        info_path.write_bytes(plistlib.dumps(info))
        signed = self.production_command('production copy signed', ['/usr/bin/codesign', '--force', '--sign', '-', str(app)],
                                         helper_deadline, 'copied app awaiting ad-hoc signature', query_bound=10)
        if signed.returncode:
            self.fail(f'wait=production copy signed; state=exit {signed.returncode}; stderr={signed.stderr}')
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
        self.addCleanup(self.clear_production_defaults)
        env = dict(self.environment, HOME=str(home), CFFIXED_USER_HOME=str(home), PENSIEVE_DOGFOOD='1')
        support = home / 'Library/Application Support/Pensieve'
        self.assertLess(len(str(support / 'p58.sock').encode()), 104, 'TMPDIR is too long for the production socket')
        for arguments in ([['--background']] if reopen else [['--background'], []]):
            with self.subTest(arguments=arguments):
                with (self.root / 'production.log').open('w') as log:
                    process = subprocess.Popen([str(app / 'Contents/MacOS/Pensieve'), *arguments], env=env,
                                               stdout=log, stderr=log)
                    try:
                        self.wait_for_production_commands(process, app, support, env, helper_deadline)
                        wait = 'background stays window-free' if arguments else 'normal production window visible'
                        deadline = min(helper_deadline, time.monotonic() + (2 if arguments else 15))
                        if arguments and helper_deadline - time.monotonic() < 2:
                            self.fail(f'wait={wait}; state=pid={process.pid} exit={process.poll()}; '
                                      'helper budget cannot cover the full 2 s window-free observation')
                        seen_window, count = False, None
                        while time.monotonic() < deadline:
                            count = self.production_window_count(process, wait, helper_deadline, count)
                            seen_window = seen_window or count > 0
                            if seen_window:
                                break
                            time.sleep(.02)
                        self.assertEqual(seen_window, not arguments,
                                         f'production scene launch behavior; wait={wait}; pid={process.pid} '
                                         f'exit={process.poll()} lastWindowCount={count}')
                        if reopen and arguments:
                            reply = self.production_command('Dock reopen reply',
                                [str(self.fixture), '--reopen', str(process.pid)],
                                min(helper_deadline, time.monotonic() + 8),
                                f'pid={process.pid} exit={process.poll()} lastWindowCount={count}; Apple event reply bound=5 s',
                                query_bound=8)
                            if reply.returncode:
                                self.fail(f'wait=Dock reopen reply (5 s Apple event); state=exit {reply.returncode}; '
                                          f'stdout={reply.stdout}; stderr={reply.stderr}')
                            deadline = min(helper_deadline, time.monotonic() + 15)
                            while time.monotonic() < deadline:
                                count = self.production_window_count(process, 'Dock production window visible',
                                                                     helper_deadline, count)
                                if count:
                                    break
                                time.sleep(.02)
                            else:
                                self.fail(f'wait=Dock production window visible (15 s); state=pid={process.pid} '
                                          f'exit={process.poll()} lastWindowCount={count}')
                    finally:
                        process.terminate()
                        try:
                            process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            try:
                                process.wait(timeout=2)
                            except subprocess.TimeoutExpired:
                                self.fail(f'wait=production terminate/reap (3 s TERM + 2 s KILL); '
                                          f'state=pid={process.pid} not reaped after SIGKILL')
                            self.fail(f'wait=production terminate/reap (5 s); state=pid={process.pid} '
                                      f'exit={process.poll()}; required SIGKILL')

    def wait_for_production_commands(self, process, app, support, env, helper_deadline):
        deadline = min(helper_deadline, time.monotonic() + 20)
        state = 'no CLI response yet'
        while time.monotonic() < deadline:
            result = self.production_command('production commands ready (20 s)',
                [str(app / 'Contents/Helpers/pensieve'), 'skill', 'list', '--json', '--app-support', str(support)],
                deadline, f'pid={process.pid} exit={process.poll()} {state}', env=env)
            state = f'CLI exit={result.returncode} stdout={result.stdout!r} stderr={result.stderr!r}'
            try:
                if json.loads(result.stdout)['ok']:
                    return
            except (ValueError, KeyError):
                pass
            time.sleep(.02)
        self.fail(f'wait=production commands ready (20 s); state=pid={process.pid} exit={process.poll()} {state}')

    def test_dogfood_cli_reaches_the_fenced_apps_store(self):
        from dogfood_self_test import DogfoodTestCase, SCRIPT
        case = DogfoodTestCase(); case.setUp()
        self.addCleanup(case.doCleanups)
        case.env['LLVM_PROFILE_FILE'] = str(case.fake_home / 'dogfood-%p.profraw')
        shutil.rmtree(case.app)
        shutil.copytree(self.binary.parent.parent.parent, case.app, symlinks=True)
        info_path = case.app / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['CFBundleIdentifier'] = 'com.jaredatch.Pensieve.dogfood'
        info_path.write_bytes(plistlib.dumps(info))
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(case.app)], check=True, capture_output=True)
        # Use the script's default /home layout, with a path at least as long as ~/PensieveSandbox/home.
        self.assertGreaterEqual(len(str(case.fake_home)), len(str(Path.home() / 'PensieveSandbox/home')))
        seeded=case.run_script('clean', '--dry-run', '--offline')
        self.assertEqual(seeded.returncode,0,seeded.stdout+seeded.stderr)
        skill = case.fake_home / '.pensieve/skills/sandbox-only'
        skill.mkdir(parents=True)
        (skill / 'SKILL.md').write_text('---\nname: Sandbox only\ndescription: Fixture\n---\nSandbox skill\n')
        launched=case.run_script('clean', '--background', '--offline')
        self.assertEqual(launched.returncode,0,launched.stdout+launched.stderr)
        pid = int(launched.stdout.split('running: pid ')[1].split()[0])
        self.addCleanup(lambda: self.stop_pid(pid))
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            result=subprocess.run(['/bin/bash',str(SCRIPT),'--cli',str(case.app),'skill','list','--json'],
                                  env=case.env,capture_output=True,text=True,timeout=10)
            if result.returncode == 0 and 'sandbox-only' in result.stdout:
                break
            time.sleep(.05)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual([row['slug'] for row in json.loads(result.stdout)['data']], ['sandbox-only'])

    def test_other_running_copy_is_refused_before_launchservices_reopens_it(self):
        other = self.make_app('Other', self.bundle_id)
        process = subprocess.Popen([str(other / 'Contents/MacOS/Fixture'), '--background'], env=self.environment,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: process.wait(timeout=5))
        self.addCleanup(process.terminate)
        self.wait_for_state(other)
        error = self.run_cli('skill', 'list', code=3)['error']
        self.assertEqual(error['code'], 'wrong_app')
        self.assertEqual(Path(error['message'].split(': ', 1)[1]).resolve(), other.resolve())
        self.assertIsNone(self.state(self.app))
        self.assertEqual(self.state(other)['reopens'], 0)
