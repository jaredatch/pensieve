#!/usr/bin/env python3
"""Check the minimum macOS of a built app and every embedded daemon slice."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import unittest

APP = None


class MinimumSystemTests(unittest.TestCase):
    def assert_binary_minimum(self, binary):
        result = subprocess.run(["/usr/bin/otool", "-arch", "all", "-l", str(binary)],
                                capture_output=True, text=True, timeout=30, check=True)
        # Limit legacy 'version' matches to LC_VERSION_MIN_MACOSX, rather than dylib versions.
        commands = re.findall(r"cmd LC_(?:BUILD_VERSION|VERSION_MIN_MACOSX)\n(.*?)(?=Load command|\Z)", result.stdout, re.DOTALL)
        versions = [re.search(r"^\s*(?:minos|version)\s+(\S+)", command, re.MULTILINE).group(1) for command in commands]
        self.assertTrue(versions, f"{binary.name} has no macOS minimum load command")
        self.assertEqual(set(versions), {"26.0"}, f"{binary.name} must require macOS 26.0 in every architecture")

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
