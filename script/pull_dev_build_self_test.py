"""Host-selection checks with failing transport stubs; no network or app writes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('pull-dev-build.sh')


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


if __name__ == '__main__':
    unittest.main()
