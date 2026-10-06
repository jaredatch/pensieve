#!/usr/bin/python3
"""Render notices as Credits.rtf, or export the exact license blocks it renders."""

import sys

import json
import re
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


def parse(notices):
    """One fence state machine supplies both rendered lines and exported blocks."""
    tokens = []
    license_block = None
    lines = notices.split("\n")
    if not lines[-1]:
        lines.pop()
    for number, line in enumerate(lines):
        if line.endswith("\r"):
            line = line[:-1]
        if line == "```text":
            if license_block is None:
                license_block = {"kind": "license", "startLine": number, "lines": []}
            continue
        if line == "```":
            if license_block is not None:
                license_block["endLine"] = number
                tokens.append(license_block)
                license_block = None
            continue
        if license_block is not None:
            license_block["lines"].append(line)
        else:
            tokens.append({"kind": "text", "text": line})
    if license_block is not None:
        raise ValueError("Unclosed license block in notices")
    return tokens


def license_blocks(notices):
    return [{"startLine": token["startLine"], "endLine": token["endLine"],
             "text": "\n".join(token["lines"])}
            for token in parse(notices) if token["kind"] == "license"]


def plain_markdown(text):
    return re.sub(r"\[([^]]+)\]\(([^)]+)\)", r"\1 (\2)", text).replace("`", "")


def render(notices):
    # No foreground/background color: AppKit supplies the appearance's text colors.
    output = [r"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\uc1\f0\fs20"]
    for token in parse(notices):
        if token["kind"] == "license":
            for line in token["lines"]:
                output.append(escape_rtf(line) + r"\line")
            continue
        raw = token["text"]
        heading = re.match(r"^(#{1,6}) (.*)$", raw)
        text = plain_markdown(heading[2] if heading else raw)
        if heading:
            output.append(r"\b\fs24 " + escape_rtf(text) + r"\b0\fs20\par")
        else:
            output.append(escape_rtf(text) + r"\par")
    output.append("}")
    return "\n".join(output) + "\n"


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: credits.py NOTICES.md Credits.rtf | credits.py --license-blocks NOTICES.md")
    exporting = sys.argv[1] == "--license-blocks"
    source_path = sys.argv[2] if exporting else sys.argv[1]
    with Path(source_path).open(encoding="utf-8", newline="") as source:
        notices = source.read()
    if exporting:
        print(json.dumps(license_blocks(notices)))
    else:
        output = Path(sys.argv[2])
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(render(notices), encoding="ascii")


if __name__ == "__main__":
    main()
