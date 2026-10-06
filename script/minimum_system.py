#!/usr/bin/env python3
"""Validate the macOS minimum of an app and its embedded daemon."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from xml.parsers.expat import ExpatError
from release_state import normalize_version


# Tests set this seam directly; the release never reads tool paths from its environment.
MACHO_TOOLS = ("/usr/bin/lipo", "/usr/bin/otool")
MINIMUM_ERRORS = (ValueError, OSError, ExpatError, subprocess.SubprocessError)
# Homebrew 7.0.7-86-g2170a64, MacOSVersion::SYMBOLS (active releases):
# https://github.com/Homebrew/brew/blob/2170a64c0ff9549d78a9b48b26217d9fd17f6a2d/Library/Homebrew/macos_version.rb
HOMEBREW_SYMBOL_SOURCE = "Homebrew 7.0.7-86-g2170a64 / MacOSVersion::SYMBOLS"
HOMEBREW_MINIMUMS = {"big_sur": "11", "monterey": "12", "ventura": "13", "sonoma": "14",
                     "sequoia": "15", "tahoe": "26", "golden_gate": "27"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def required_minimum():
    minimum = (Path(__file__).resolve().parent.parent / "release/minimum-macos.txt").read_text().strip()
    require(re.fullmatch(r"\d+\.\d+", minimum), "malformed release minimum policy (expected X.Y)")
    return minimum


def check_cask_minimum(cask):
    requirements = re.findall(r"(?m)^\s*depends_on\s+macos:\s*:(\w+)\s*$", cask.read_text())
    require(len(requirements) == 1, "cask minimum must have one named macOS requirement")
    symbol = requirements[0]
    require(symbol in HOMEBREW_MINIMUMS, f"cask minimum has unknown macOS requirement :{symbol}")
    expected = required_minimum()
    require(normalize_version(HOMEBREW_MINIMUMS[symbol]) == normalize_version(expected),
            f"cask minimum :{symbol} differs from release policy macOS {expected}")


def check_binary_minimum(binary, expected):
    architectures = subprocess.run([MACHO_TOOLS[0], "-archs", str(binary)], capture_output=True,
                                   text=True, timeout=30, check=True).stdout.split()
    require(architectures and len(architectures) == len(set(architectures)),
            f"{binary.name}: missing or duplicated architectures")
    output = subprocess.run([MACHO_TOOLS[1], "-arch", "all", "-l", str(binary)], capture_output=True,
                            text=True, timeout=30, check=True).stdout
    headers = list(re.finditer(r"(?m)^.+ \(architecture ([^)]+)\):$", output))
    if headers:
        require(len(headers) == len(architectures) and {h.group(1) for h in headers} == set(architectures),
                f"{binary.name}: architecture/load-command output differs")
        slices = [(h.group(1), output[h.end():headers[i + 1].start() if i + 1 < len(headers) else len(output)])
                  for i, h in enumerate(headers)]
    else:
        require(len(architectures) == 1, f"{binary.name}: missing architecture load-command output")
        slices = [(architectures[0], output)]
    minimums = []
    for architecture, content in slices:
        name = f"{binary.name} [{architecture}]"
        commands = re.findall(r"^\s*cmd LC_(BUILD_VERSION|VERSION_MIN_MACOSX)\n(.*?)(?=^Load command|\Z)",
                              content, re.MULTILINE | re.DOTALL)
        require(len(commands) == 1, f"{name}: missing or duplicated minimum load command")
        command, fields = commands[0]
        key = "minos" if command == "BUILD_VERSION" else "version"
        if command == "BUILD_VERSION":
            platform = re.search(r"^\s*platform\s+(\S+)\s*$", fields, re.MULTILINE)
            require(platform is not None and platform.group(1) in ("1", "MACOS"),
                    f"{name}: platform must be macOS")
        minimum = re.search(rf"^\s*{key}\s+(\d+(?:\.\d+){{1,2}})\s*$", fields, re.MULTILINE)
        require(minimum is not None, f"{name}: missing or malformed {key}")
        minimums.append(minimum.group(1))
        require(normalize_version(minimums[-1]) == normalize_version(expected),
                f"{name} must require macOS {expected}; found {minimums[-1]}")
    require(len(minimums) == len(architectures), f"{binary.name}: minimum count differs from architecture count")


def check_app_binary_minimum(app, version=None, context="built DMG"):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if version is not None:
        require(info.get("CFBundleShortVersionString") == version, f"{context} app version differs from VERSION")
    minimum = info.get("LSMinimumSystemVersion")
    require(isinstance(minimum, str) and re.fullmatch(r"\d+(?:\.\d+){1,2}", minimum),
            f"{context} app has no minimum system version or it is malformed")
    expected = required_minimum()
    require(normalize_version(minimum) == normalize_version(expected), f"release policy requires macOS {expected}; found {minimum}")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and executable and Path(executable).name == executable,
            f"{context} app has no valid executable name")
    check_binary_minimum(app / "Contents/MacOS" / executable, minimum)
    return minimum


def check_app_minimum(app, version=None, context="built DMG"):
    minimum = check_app_binary_minimum(app, version, context)
    check_binary_minimum(app / "Contents/MacOS/pensieve-daemon", minimum)
    return minimum


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--app", type=Path)
    target.add_argument("--cask", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--context", default="built DMG")
    args = parser.parse_args()
    try:
        if args.cask:
            check_cask_minimum(args.cask)
        else:
            print(check_app_minimum(args.app, args.version, args.context))
    except MINIMUM_ERRORS as error:
        context = "cask" if args.cask else args.context
        sys.exit(f"release: invalid {context} minimum: " + ascii(str(error))[1:-1])
