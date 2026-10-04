#!/usr/bin/env python3
"""Validate the macOS minimum of an app and its embedded daemon."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from xml.parsers.expat import ExpatError


# Tests set this seam directly; the release never reads tool paths from its environment.
MACHO_TOOLS = ("/usr/bin/lipo", "/usr/bin/otool")
MINIMUM_ERRORS = (ValueError, OSError, ExpatError, subprocess.SubprocessError)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def required_minimum():
    minimum = (Path(__file__).resolve().parent.parent / "release/minimum-macos.txt").read_text().strip()
    require(re.fullmatch(r"\d+\.\d+", minimum), "malformed release minimum policy (expected X.Y)")
    return minimum


def normalize_version(value):
    require(isinstance(value, str) and re.fullmatch(r"\d+(?:\.\d+){0,2}", value),
            f"malformed macOS version: {value}")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


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


def check_app_minimum(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    minimum = info.get("LSMinimumSystemVersion")
    require(isinstance(minimum, str) and re.fullmatch(r"\d+(?:\.\d+){1,2}", minimum),
            "built app has no minimum system version or it is malformed")
    expected = required_minimum()
    require(normalize_version(minimum) == normalize_version(expected), f"release policy requires macOS {expected}; found {minimum}")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and executable and Path(executable).name == executable,
            "built app has no valid executable name")
    check_binary_minimum(app / "Contents/MacOS" / executable, minimum)
    check_binary_minimum(app / "Contents/MacOS/pensieve-daemon", minimum)
    return minimum


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    args = parser.parse_args()
    try:
        print(check_app_minimum(args.app))
    except MINIMUM_ERRORS as error:
        sys.exit("release: invalid built minimum: " + ascii(str(error))[1:-1])
