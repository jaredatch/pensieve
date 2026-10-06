"""Host selection and local signing through fake tools; all writes stay in a temp dir."""
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('pull-dev-build.sh')

# The tool boundary records actual argv. The signature model becomes invalid
# after a nested edit and valid after the outer seal; copying the original app
# restores its state. No tool reaches SSH, a keychain, or a real app directory.
SIGNING_TOOL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['PULL_TEST_RECEIPTS'], 'a') as log:
    log.write(json.dumps([tool, args]) + '\n')
app = Path(os.environ['PENSIEVE_DEV_APP'])
state_path = app / 'signature.json'
if tool == 'security':
    print(os.environ.get('PULL_TEST_IDENTITIES', ''))
    sys.exit(int(os.environ.get('PULL_TEST_SECURITY_STATUS', '0')))
if tool == 'ssh':
    print('abc1234 fixture build\n0')
elif tool == 'rsync':
    source, destination = args[-2:]
    if source.endswith('.app/'):
        if Path(destination).exists():
            shutil.rmtree(destination)
        shutil.copytree(os.environ['PULL_TEST_SOURCE'], destination, symlinks=True)
    else:
        shutil.copy2(os.environ['PULL_TEST_DOGFOOD'], destination)
elif tool == 'pgrep':
    sys.exit(1)
elif tool == 'defaults':
    print('com.jaredatch.Pensieve.debug')
elif tool == 'codesign':
    target = Path(args[-1])
    if '-d' in args:
        framework_version = target.parent.name == 'Versions' and target.parent.parent.suffix == '.framework'
        sys.exit(0 if framework_version or target.suffix in ('.app', '.framework', '.xpc', '.bundle') else 1)
    state = json.loads(state_path.read_text())
    if '--sign' in args:
        relative = str(target.relative_to(app))
        if relative == os.environ.get('PULL_TEST_SIGN_FAIL'):
            print('errSecInternalComponent: simulated locked keychain', file=sys.stderr)
            sys.exit(1)
        identity = args[args.index('--sign') + 1]
        state['identity'] = identity
        state['dirty'] = target != app
        state_path.write_text(json.dumps(state))
    else:
        if state['dirty'] or (state['identity'] != '-' and os.environ.get('PULL_TEST_VERIFY_FAIL')):
            print('invalid outer seal', file=sys.stderr)
            sys.exit(1)
elif tool == 'dogfood-fixture':
    print('dogfood received identity: ' + json.loads(state_path.read_text())['identity'])
'''


class PullDevBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pull-dev-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / 'transport.log'
        for name in ('ssh', 'scp'):
            stub = self.root / name
            stub.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$PULL_TEST_LOG"\nexit 73\n')
            stub.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('PENSIEVE_')}
        self.env.update(PATH=str(self.root) + ':' + os.environ['PATH'],
                        PULL_TEST_LOG=str(self.log),
                        PENSIEVE_DEV_APP=str(self.root / 'Test.app'))

    def run_script(self, *args, host=None):
        self.log.unlink(missing_ok=True)
        env = dict(self.env)
        if host is not None:
            env['PENSIEVE_DEV_HOST'] = host
        return subprocess.run(['/bin/bash', str(SCRIPT), '--yes', *args], env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)

    def test_missing_host_fails_before_transport(self):
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--host', result.stderr)
        self.assertIn('PENSIEVE_DEV_HOST', result.stderr)
        self.assertFalse(self.log.exists())

    def test_each_run_discards_prior_transport_log(self):
        result = self.run_script(host='first-host')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text().splitlines()[0], 'first-host')
        result = self.run_script('--help')
        self.assertEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_empty_host_fails_before_transport(self):
        for args, host in (((), ''), (('--host', ''), 'env-host')):
            with self.subTest(args=args, host=host):
                result = self.run_script(*args, host=host)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('--host', result.stderr)
                self.assertIn('PENSIEVE_DEV_HOST', result.stderr)
                self.assertFalse(self.log.exists())

    def test_explicit_and_environment_hosts_reach_ssh(self):
        for args, env_host, expected in ((('--host', 'flag-host'), None, 'flag-host'),
                                         ((), 'env-host', 'env-host'),
                                         (('--host', 'flag-host'), 'env-host', 'flag-host')):
            for mode in ((), ('--no-build',)):
                with self.subTest(args=args, env_host=env_host, mode=mode):
                    result = self.run_script(*args, *mode, host=env_host)
                    self.assertNotEqual(result.returncode, 0)  # The transport stub refuses work.
                    self.assertTrue(self.log.is_file(), 'this run did not reach the transport stub')
                    self.assertEqual(self.log.read_text().splitlines()[0], expected)

    def test_update_requires_host_and_targets_it(self):
        result = self.run_script('--update')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PENSIEVE_DEV_HOST', result.stderr)
        self.assertFalse(self.log.exists())
        for args, env_host, expected in ((('--host', 'flag-host'), None, 'flag-host'),
                                         ((), 'env-host', 'env-host')):
            with self.subTest(args=args):
                result = self.run_script('--update', *args, host=env_host)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(self.log.is_file(), 'this run did not reach the transport stub')
                self.assertEqual(self.log.read_text().splitlines()[1],
                                 expected + ':Projects/pensieve/script/pull-dev-build.sh')

    def test_help_needs_no_host(self):
        result = self.run_script('--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('PENSIEVE_DEV_HOST', result.stdout)
        self.assertFalse(self.log.exists())


class PullDevSigningTests(unittest.TestCase):
    APPLE_FIRST = 'A' * 40
    APPLE_SECOND = 'B' * 40
    DEVELOPER_ID = 'D' * 40
    IDENTITIES = (f'  1) {DEVELOPER_ID} "Developer ID Application: Fixture (TEAM)"\n'
                  f'  2) {APPLE_FIRST} "Apple Development: First (TEAM)"\n'
                  f'  3) {APPLE_SECOND} "Apple Development: Second (TEAM)"\n'
                  '     3 valid identities found')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pull-dev-sign-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.receipts = self.root / 'receipts.jsonl'
        self.source = self.root / 'source.app'
        self.app = self.root / 'Applications' / 'Dev Build.app'
        # A real Mach-O header lets production use the real file(1) classifier.
        macho = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 0, 0, 0, 0)
        self.nested = [
            'Contents/MacOS/Pensieve',
            'Contents/MacOS/pensieve-daemon',
            'Contents/Frameworks/Fixture.framework/Versions/A/Fixture',
            'Contents/Frameworks/Fixture.framework/Versions/A/XPCServices/Worker.xpc/Contents/MacOS/Worker',
            'Contents/Helpers/Updater.app/Contents/MacOS/Updater',
            'Contents/PlugIns/Plugin.bundle/Contents/MacOS/Plugin',
        ]
        for name in self.nested:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(macho)
        framework = self.source / 'Contents/Frameworks/Fixture.framework'
        (framework / 'Versions/Current').symlink_to('A')
        (framework / 'Fixture').symlink_to('Versions/Current/Fixture')
        resource = self.source / 'Contents/Resources/Ordinary.txt'
        resource.parent.mkdir()
        resource.write_text('not executable code')
        (self.source / 'signature.json').write_text(json.dumps({'identity': '-', 'dirty': False}))
        self.dogfood = self.root / 'dogfood-fixture'
        self.dogfood.write_text(SIGNING_TOOL.replace("tool = Path(sys.argv[0]).name", "tool = 'dogfood-fixture'"))
        self.dogfood.chmod(0o755)
        for name in ('ssh', 'rsync', 'security', 'codesign', 'xattr', 'defaults', 'pgrep', 'open'):
            path = self.tools / name
            path.write_text(SIGNING_TOOL)
            path.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('PENSIEVE_')}
        self.env.update(PATH=str(self.tools) + ':' + os.environ['PATH'],
                        PENSIEVE_DEV_HOST='fixture-host', PENSIEVE_DEV_APP=str(self.app),
                        PULL_TEST_RECEIPTS=str(self.receipts), PULL_TEST_SOURCE=str(self.source),
                        PULL_TEST_DOGFOOD=str(self.dogfood), PULL_TEST_IDENTITIES=self.IDENTITIES)

    def run_script(self, *args, **environment):
        self.receipts.unlink(missing_ok=True)
        env = dict(self.env, **environment)
        result = subprocess.run(['/bin/bash', str(SCRIPT), '--yes', '--no-build', *args],
                                env=env, stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def calls(self, tool):
        return [args for name, args in map(json.loads, self.receipts.read_text().splitlines())
                if name == tool]

    def signatures(self):
        return [args for args in self.calls('codesign') if '--sign' in args]

    def test_identity_choice(self):
        for label, environment, expected in (
                ('environment wins', {'PENSIEVE_DEV_SIGN_IDENTITY': 'Explicit Local Identity'},
                 'Explicit Local Identity'),
                ('first Apple Development', {}, self.APPLE_FIRST),
                ('explicit Developer ID', {'PENSIEVE_DEV_SIGN_IDENTITY': self.DEVELOPER_ID},
                 self.DEVELOPER_ID)):
            with self.subTest(label=label):
                self.run_script('--no-open', **environment)
                signatures = self.signatures()
                self.assertTrue(signatures, 'the copied app must be signed')
                self.assertEqual({args[args.index('--sign') + 1] for args in signatures}, {expected})
                if 'PENSIEVE_DEV_SIGN_IDENTITY' in environment:
                    self.assertEqual(self.calls('security'), [], 'explicit identity must bypass discovery')
                else:
                    self.assertEqual(self.calls('security'), [['find-identity', '-v', '-p', 'codesigning']])

    def test_developer_id_is_never_auto_selected(self):
        result = self.run_script('--no-open', PULL_TEST_IDENTITIES=
                                 f'  1) {self.DEVELOPER_ID} "Developer ID Application: Fixture (TEAM)"')
        self.assertEqual(self.signatures(), [], 'Developer ID must never be picked automatically')
        self.assertIn('warning: no Apple Development', result.stdout)
        self.assertIn('PENSIEVE_DEV_SIGN_IDENTITY', result.stdout)

    def test_missing_or_unreadable_identity_warns_and_keeps_app(self):
        for environment in ({'PULL_TEST_IDENTITIES': '0 valid identities found'},
                            {'PULL_TEST_SECURITY_STATUS': '73'}):
            with self.subTest(environment=environment):
                result = self.run_script('--no-open', **environment)
                self.assertEqual(self.signatures(), [])
                self.assertIn('warning: no Apple Development', result.stdout)
                self.assertEqual(json.loads((self.app / 'signature.json').read_text())['identity'], '-')

    def test_nested_code_is_signed_before_containers_with_entitlements_preserved(self):
        self.run_script('--no-open')
        signatures = self.signatures()
        signed = [str(Path(args[-1]).relative_to(self.app)) for args in signatures]
        expected = set(self.nested) | {
            'Contents/Frameworks/Fixture.framework',
            'Contents/Frameworks/Fixture.framework/Versions/A',
            'Contents/Frameworks/Fixture.framework/Versions/A/XPCServices/Worker.xpc',
            'Contents/Helpers/Updater.app', 'Contents/PlugIns/Plugin.bundle', '.'}
        self.assertEqual(set(signed), expected)
        self.assertEqual(len(signed), len(expected), 'framework symlinks must not cause duplicate signing')
        self.assertEqual(signed[-1], '.')
        for child in signed:
            for container in signed:
                if container != '.' and child.startswith(container + '/'):
                    self.assertLess(signed.index(child), signed.index(container))
        for args in signatures:
            self.assertIn('--force', args)
            metadata = next(arg.split('=', 1)[1].split(',') for arg in args
                            if arg.startswith('--preserve-metadata='))
            self.assertIn('entitlements', metadata)
            self.assertNotIn('requirements', metadata, 'ad-hoc cdhash requirements must be regenerated')
            self.assertIn('--force-library-entitlements', args)
        self.assertIn(['--verify', '--deep', '--strict', str(self.app)], self.calls('codesign'))

    def test_failed_signing_restores_a_bundle_that_verifies(self):
        for label, environment in (
                ('nested failure', {'PULL_TEST_SIGN_FAIL': 'Contents/Helpers/Updater.app'}),
                ('outer failure', {'PULL_TEST_SIGN_FAIL': '.'}),
                ('verification failure', {'PULL_TEST_VERIFY_FAIL': '1'})):
            with self.subTest(label=label):
                result = self.run_script('--no-open', **environment)
                self.assertIn('local signing failed', result.stdout)
                self.assertIn('Unlock the login keychain', result.stdout)
                self.assertTrue(self.signatures(), 'failure must reach signing')
                verified = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(self.app)],
                                          env=self.env, capture_output=True, text=True, timeout=5)
                self.assertEqual(verified.returncode, 0,
                                 'failed signing must leave an app that verifies: ' + verified.stderr)
                self.assertEqual(json.loads((self.app / 'signature.json').read_text()),
                                 {'identity': '-', 'dirty': False}, 'failed signing must restore original seals')
                self.assertEqual(sorted(p.relative_to(self.app) for p in self.app.rglob('*')),
                                 sorted(p.relative_to(self.source) for p in self.source.rglob('*')))
                for original in self.source.rglob('*'):
                    copied = self.app / original.relative_to(self.source)
                    if original.is_symlink():
                        self.assertEqual(os.readlink(copied), os.readlink(original))
                    elif original.is_file():
                        self.assertEqual(copied.read_bytes(), original.read_bytes())
                self.assertEqual(list(self.app.parent.glob('.pensieve-dev-sign.*')), [])

    def test_sandbox_receives_the_signed_app(self):
        result = self.run_script('--sandbox', '--offline')
        self.assertIn('dogfood received identity: ' + self.APPLE_FIRST, result.stdout)
        receipts = list(map(json.loads, self.receipts.read_text().splitlines()))
        self.assertEqual(receipts[-1], ['dogfood-fixture', ['--offline', str(self.app)]])
        self.assertEqual(self.calls('open'), [])


if __name__ == '__main__':
    unittest.main()
