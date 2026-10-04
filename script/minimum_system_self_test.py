#!/usr/bin/env python3
"""Check the minimum macOS of a built app and every embedded daemon slice."""
import argparse
from pathlib import Path
import unittest
from minimum_system import MINIMUM_ERRORS, check_app_minimum, check_binary_minimum, normalize_version, required_minimum

APP = None


class MinimumSystemTests(unittest.TestCase):
    def assert_app_minimum(self):
        try:
            self.assertEqual(normalize_version(check_app_minimum(APP)), normalize_version(required_minimum()))
        except MINIMUM_ERRORS as error:
            self.fail(str(error))

    def test_app_requires_macos_26(self):
        self.assert_app_minimum()

    def test_embedded_daemon_requires_macos_26(self):
        try:
            check_binary_minimum(APP / "Contents/MacOS/pensieve-daemon", required_minimum())
        except MINIMUM_ERRORS as error:
            self.fail(str(error))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    args, remaining = parser.parse_known_args()
    APP = args.app
    unittest.main(argv=[__file__, *remaining])
