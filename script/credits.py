#!/usr/bin/env python3
"""Render the source notices as the standard macOS About panel's Credits.rtf."""

import re
import sys
from pathlib import Path


def escape_rtf(text):
    result = []
    encoded = text.encode("utf-16-le")
    for offset in range(0, len(encoded), 2):
        unit = int.from_bytes(encoded[offset:offset + 2], "little")
        if unit in (ord("\\"), ord("{"), ord("}")):
            result.append("\\" + chr(unit))
        elif 32 <= unit < 127:
            result.append(chr(unit))
        elif unit == 9:
            result.append("\\tab ")
        else:
            result.append(f"\\u{unit if unit < 32768 else unit - 65536}?")
    return "".join(result)


def render(notices):
    # No foreground/background color: AppKit supplies the appearance's text colors.
    output = [r"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\uc1\f0\fs20"]
    in_license = False
    for line in notices.splitlines():
        if line == "```text":
            in_license = True
            continue
        if line == "```":
            in_license = False
            continue
        if in_license:
            output.append(escape_rtf(line) + r"\line")
            continue
        heading = re.match(r"^(#{1,3}) (.*)$", line)
        line = re.sub(r"\[([^]]+)\]\(([^)]+)\)", r"\1 (\2)", line)
        line = line.replace("`", "")
        if heading:
            output.append(r"\b\fs24 " + escape_rtf(heading[2]) + r"\b0\fs20\par")
        else:
            output.append(escape_rtf(line) + r"\par")
    if in_license:
        raise ValueError("Unclosed license block in notices")
    output.append("}")
    return "\n".join(output) + "\n"


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: credits.py NOTICES.md Credits.rtf")
    output = Path(sys.argv[2])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(Path(sys.argv[1]).read_text(encoding="utf-8")), encoding="ascii")


if __name__ == "__main__":
    main()
