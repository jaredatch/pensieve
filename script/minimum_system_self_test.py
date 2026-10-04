#!/usr/bin/env python3
"""Check the minimum macOS of a built app and every embedded daemon slice."""
import argparse
from pathlib import Path
import subprocess
import unittest
from xml.parsers.expat import ExpatError
from minimum_system import check_app_minimum, required_minimum

APP = None


class MinimumSystemTests(unittest.TestCase):
    def assert_app_minimum(self):
        try:
            self.assertEqual(check_app_minimum(APP), required_minimum())
        except (ValueError, OSError, ExpatError, subprocess.SubprocessError) as error:
            self.fail(str(error))

    def test_app_requires_macos_26(self):
        self.assert_app_minimum()

    def test_embedded_daemon_requires_macos_26(self):
        self.assert_app_minimum()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    args, remaining = parser.parse_known_args()
    APP = args.app
    unittest.main(argv=[__file__, *remaining])
