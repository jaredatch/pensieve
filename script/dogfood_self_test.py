"""Guard checks for dogfood.sh: a stubbed `security` for the real home's reads, a fake app bundle.

Calls made under the fake home (CFFIXED_USER_HOME set) reach the real `security`, so the sandbox keychain
is really created, unlocked and made the fake home's default. Reads of the real home's search list and
default go to the stub, which fails or lies on purpose. The real login keychain is only ever read.

`lsregister` and `lsappinfo` are always stubbed, so this Mac's own registrations never decide a result:
by default LaunchServices knows only the test app and nothing of it is running.
"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('dogfood.sh')
STUB = r'''#!/bin/bash
if [ -n "${CFFIXED_USER_HOME:-}" ]; then exec /usr/bin/security "$@"; fi
case "$STUB_MODE:$1" in
  list-fails:list-keychains) exit 1 ;;
  list-names-fake:list-keychains)
    printf '    "%s"\n' "$STUB_FAKE_KEYCHAIN"
    i=0; while [ "$i" -lt 20000 ]; do printf '    "/Users/x/Library/Keychains/k%s.keychain-db"\n' "$i"; i=$((i + 1)); done ;;
  default-fails:default-keychain) exit 1 ;;
  default-is-fake:default-keychain) printf '    "%s"\n' "$STUB_FAKE_KEYCHAIN" ;;
  *) exec /usr/bin/security "$@" ;;
esac
'''
LSREGISTER_STUB = r'''#!/bin/bash
[ "${STUB_LSREGISTER:-}" != fail ] || { echo 'lsregister: cannot open the database' >&2; exit 1; }
[ "$1" = -dump ] || exit 64
cat "$STUB_LSREGISTER_DUMP"
'''
LSAPPINFO_STUB = r'''#!/bin/bash
[ "${STUB_LSAPPINFO:-}" != fail ] || { echo 'lsappinfo: cannot reach the server' >&2; exit 1; }
[ "$1" = list ] || exit 64
cat "$STUB_LSAPPINFO_LIST"
'''
DOGFOOD_ID = 'com.jaredatch.Pensieve.dogfood'
SEPARATOR = '-' * 80


def lsregister_dump(paths):
    """The shape of `lsregister -dump` on macOS 26: a header, then records split by dashes."""
    lines = ['Checking data integrity...', '...done.',
             'Path:                       /var/folders/xx/0/com.apple.LaunchServices.dv/x.csstore',
             SEPARATOR, 'bundle id:                  Finder (0x1a0)',
             'path:                       /System/Library/CoreServices/Finder.app (0x1b4)',
             'identifier:                 com.apple.finder']
    for path in paths:
        lines += [SEPARATOR, 'bundle id:                  Pensieve (0x1f6a8)',
                  f'path:                       {path} (0x2120c)', 'directory:                  ~',
                  f'identifier:                 {DOGFOOD_ID}', f'codeInfoID:                 {DOGFOOD_ID}']
    return '\n'.join(lines + [SEPARATOR, ''])


def lsappinfo_list(running):
    """The shape of `lsappinfo list`: numbered records; `running` is [(pid, bundle path)]."""
    lines = [' 1) "loginwindow" ASN:0x0-0x2002: ', '    bundleID="com.apple.loginwindow"',
             '    bundle path="/System/Library/CoreServices/loginwindow.app"',
             '    pid = 606 type="UIElement" flavor=3 Version="3085.6.3" fileType="APPL" creator="lgnw" Arch=ARM64 ']
    for n, (pid, path) in enumerate(running, start=2):
        lines += [f' {n}) "Pensieve" ASN:0x0-0x{n}a0a: ', f'    bundleID="{DOGFOOD_ID}"',
                  f'    bundle path="{path}"', f'    executable path="{path}/Contents/MacOS/Pensieve"',
                  f'    pid = {pid} type="Foreground" flavor=3 Version="1.0" fileType="APPL" creator="????" Arch=ARM64 ']
    return '\n'.join(lines + [''])


def make_app(app, bundle_id):
    """A bundle whose executable just stays up past the launch check."""
    (app / 'Contents' / 'MacOS').mkdir(parents=True)
    executable = app / 'Contents' / 'MacOS' / 'Pensieve'
    executable.write_text('#!/bin/sh\nexec sleep 3\n')
    executable.chmod(0o755)
    with open(app / 'Contents' / 'Info.plist', 'wb') as handle:
        plistlib.dump({'CFBundleIdentifier': bundle_id, 'CFBundleShortVersionString': '0.0'}, handle)


class DogfoodTestCase(unittest.TestCase):
    def setUp(self):
        # Not under /tmp or /var: dogfood.sh refuses a fake home there.
        self.root = Path(tempfile.mkdtemp(prefix='.dogfood-selftest-', dir=Path.home()))
        self.addCleanup(self.remove_root)
        self.fake_home = self.root / 'sandbox' / 'home'
        self.fake_keychain = self.fake_home / 'Library' / 'Keychains' / 'dogfood.keychain-db'
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        for name, text in (('security', STUB), ('lsregister', LSREGISTER_STUB), ('lsappinfo', LSAPPINFO_STUB)):
            stub = bin_dir / name
            stub.write_text(text)
            stub.chmod(0o755)
        # The dogfood bundle id skips staging: the app is its own staged copy.
        self.app = self.root / 'Test.app'
        make_app(self.app, DOGFOOD_ID)
        self.dump_file = self.root / 'lsregister.dump'
        self.apps_file = self.root / 'lsappinfo.list'
        self.set_launchservices([self.app], [])
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('PENSIEVE_')}
        self.env.update(PATH=str(bin_dir) + ':' + os.environ['PATH'],
                        PENSIEVE_SANDBOX=str(self.root / 'sandbox'),
                        STUB_FAKE_KEYCHAIN=str(self.fake_keychain),
                        STUB_LSREGISTER_DUMP=str(self.dump_file),
                        STUB_LSAPPINFO_LIST=str(self.apps_file))

    def set_launchservices(self, registered, running):
        self.dump_file.write_text(lsregister_dump(registered))
        self.apps_file.write_text(lsappinfo_list(running))

    def remove_root(self):
        if self.fake_keychain.exists():
            subprocess.run(['/usr/bin/security', 'delete-keychain', str(self.fake_keychain)],
                           env=dict(os.environ, HOME=str(self.fake_home), CFFIXED_USER_HOME=str(self.fake_home)),
                           capture_output=True, timeout=30)
        shutil.rmtree(self.root, ignore_errors=True)

    def run_script(self, mode, *args, app=None, **stub_env):
        env = dict(self.env, STUB_MODE=mode, **stub_env)
        return subprocess.run(['/bin/bash', str(SCRIPT), *args, str(app or self.app)], env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)


class DogfoodKeychainTests(DogfoodTestCase):

    def real_search_list(self):
        return subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user'],
                              capture_output=True, text=True, check=True, timeout=30).stdout

    def assert_refused(self, mode, message):
        result = self.run_script(mode)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertNotIn('running: pid', result.stdout)

    def test_failed_search_list_read_refuses_launch(self):
        self.assert_refused('list-fails', 'could not read the real keychain search list')

    def test_long_search_list_naming_the_sandbox_refuses_launch(self):
        # 20,000 lines with the match first: a `grep -q` pipe would SIGPIPE its producer under pipefail.
        self.assert_refused('list-names-fake', 'the real keychain search list names a keychain in')

    def test_failed_default_read_refuses_launch(self):
        self.assert_refused('default-fails', 'could not read the real default keychain')

    def test_real_default_inside_the_fake_home_refuses_launch(self):
        self.assert_refused('default-is-fake', 'the real default keychain is ' + str(self.fake_keychain))

    def test_clean_run_launches_with_the_sandbox_keychain_as_default(self):
        before = self.real_search_list()
        result = self.run_script('clean')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'keychain: {self.fake_keychain} (sandbox only)', result.stdout)
        self.assertIn('running: pid', result.stdout)
        fake_default = subprocess.run(['/usr/bin/security', 'default-keychain', '-d', 'user'],
                                      env=dict(os.environ, HOME=str(self.fake_home),
                                               CFFIXED_USER_HOME=str(self.fake_home)),
                                      capture_output=True, text=True, check=True, timeout=30).stdout
        self.assertEqual(fake_default.strip().strip('"'), str(self.fake_keychain))
        self.assertEqual(self.real_search_list(), before)


class DogfoodOtherCopyTests(DogfoodTestCase):
    """Any other copy LaunchServices could start as the dogfood id refuses the run, before staging."""

    def dry_run(self, **kwargs):
        return self.run_script('clean', '--dry-run', **kwargs)

    def assert_refused(self, result, *messages):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for message in messages:
            self.assertIn(message, result.stderr)
        self.assertNotIn('fence holds', result.stdout)

    def assert_passed(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('/usr/bin/sandbox-exec -f', result.stdout)

    def test_registered_copy_outside_the_staging_folder_refuses_before_staging(self):
        debug_app = self.root / 'Debug' / 'Pensieve.app'
        make_app(debug_app, 'com.jaredatch.Pensieve.debug')
        stale = self.root / '.Trash' / 'PensieveSandbox-old' / 'Pensieve.app'
        stale.mkdir(parents=True)
        self.set_launchservices([self.root / 'sandbox' / 'Pensieve.app', stale], [])
        result = self.dry_run(app=debug_app)
        self.assert_refused(result, f'installed: {stale}', f'lsregister -u \'{stale}\'')
        self.assertFalse((self.root / 'sandbox' / 'Pensieve.app').exists(), 'the app was staged before the refusal')

    def test_only_the_staged_copy_registered_and_running_passes(self):
        # Through a symlinked parent too: the staged copy matches by canonical path.
        alias = self.root / 'alias'
        alias.symlink_to(self.root)
        self.set_launchservices([self.app, alias / 'Test.app'], [(4242, alias / 'Test.app')])
        self.assert_passed(self.dry_run())

    def test_registration_whose_bundle_is_gone_is_ignored(self):
        self.set_launchservices([self.app, self.root / 'gone' / 'Pensieve.app'], [])
        self.assert_passed(self.dry_run())

    def test_running_copy_elsewhere_refuses(self):
        elsewhere = self.root / 'Elsewhere' / 'Pensieve.app'
        self.set_launchservices([self.app], [(4242, elsewhere)])
        self.assert_refused(self.dry_run(), f'running:   pid 4242, {elsewhere}', 'kill 4242')

    def test_failed_or_empty_lsregister_refuses(self):
        with self.subTest('exit 1'):
            self.assert_refused(self.dry_run(STUB_LSREGISTER='fail'), 'could not read the LaunchServices database')
        with self.subTest('empty dump'):
            self.dump_file.write_text('')
            self.assert_refused(self.dry_run(), 'the LaunchServices dump lists no bundles')

    def test_failed_or_empty_lsappinfo_refuses(self):
        with self.subTest('exit 1'):
            self.assert_refused(self.dry_run(STUB_LSAPPINFO='fail'), 'could not list running apps')
        with self.subTest('empty list, exit 0'):
            self.apps_file.write_text('')
            self.assert_refused(self.dry_run(), 'lsappinfo lists no running apps')


if __name__ == '__main__':
    unittest.main()
