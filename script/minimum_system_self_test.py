#!/usr/bin/env python3
"""Check the minimum macOS of a built app and every embedded daemon slice."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import unittest
from minimum_system import check_binary_minimum

APP = None


class MinimumSystemTests(unittest.TestCase):
    def assert_binary_minimum(self, binary):
        try:
            check_binary_minimum(binary, "26.0")
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            self.fail(str(error))

    def test_app_requires_macos_26(self):
        info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
        self.assertEqual(info.get("LSMinimumSystemVersion"), "26.0", "the built app must require macOS 26.0")
        self.assert_binary_minimum(APP / "Contents/MacOS" / info["CFBundleExecutable"])

    def test_embedded_daemon_requires_macos_26(self):
        self.assert_binary_minimum(APP / "Contents/MacOS/pensieve-daemon")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    args, remaining = parser.parse_known_args()
    APP = args.app
    unittest.main(argv=[__file__, *remaining])
