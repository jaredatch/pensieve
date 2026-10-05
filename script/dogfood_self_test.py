"""Keychain guard checks for dogfood.sh: a stubbed `security` for the real home's reads, a fake app bundle.

Calls made under the fake home (CFFIXED_USER_HOME set) reach the real `security`, so the sandbox keychain
is really created, unlocked and made the fake home's default. Reads of the real home's search list and
default go to the stub, which fails or lies on purpose. The real login keychain is only ever read.
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


class DogfoodKeychainTests(unittest.TestCase):
    def setUp(self):
        # Not under /tmp or /var: dogfood.sh refuses a fake home there.
        self.root = Path(tempfile.mkdtemp(prefix='.dogfood-selftest-', dir=Path.home()))
        self.addCleanup(self.remove_root)
        self.fake_home = self.root / 'sandbox' / 'home'
        self.fake_keychain = self.fake_home / 'Library' / 'Keychains' / 'dogfood.keychain-db'
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        stub = bin_dir / 'security'
        stub.write_text(STUB)
        stub.chmod(0o755)
        # The dogfood bundle id skips staging; the executable just stays up past the launch check.
        self.app = self.root / 'Test.app'
        (self.app / 'Contents' / 'MacOS').mkdir(parents=True)
        executable = self.app / 'Contents' / 'MacOS' / 'Pensieve'
        executable.write_text('#!/bin/sh\nexec sleep 3\n')
        executable.chmod(0o755)
        with open(self.app / 'Contents' / 'Info.plist', 'wb') as handle:
            plistlib.dump({'CFBundleIdentifier': 'com.jaredatch.Pensieve.dogfood',
                           'CFBundleShortVersionString': '0.0'}, handle)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('PENSIEVE_')}
        self.env.update(PATH=str(bin_dir) + ':' + os.environ['PATH'],
                        PENSIEVE_SANDBOX=str(self.root / 'sandbox'),
                        STUB_FAKE_KEYCHAIN=str(self.fake_keychain))

    def remove_root(self):
        if self.fake_keychain.exists():
            subprocess.run(['/usr/bin/security', 'delete-keychain', str(self.fake_keychain)],
                           env=dict(os.environ, HOME=str(self.fake_home), CFFIXED_USER_HOME=str(self.fake_home)),
                           capture_output=True, timeout=30)
        shutil.rmtree(self.root, ignore_errors=True)

    def run_script(self, mode):
        env = dict(self.env, STUB_MODE=mode)
        return subprocess.run(['/bin/bash', str(SCRIPT), str(self.app)], env=env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=60)

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


if __name__ == '__main__':
    unittest.main()
