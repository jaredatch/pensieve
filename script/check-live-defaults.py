#!/usr/bin/env python3
"""Fence live-state resolution to RuntimePaths and the constant definitions.

Scans app/daemon Swift source, ignoring comments and inert string contents but
checking string interpolations. Direct live constants and Keychain construction
are rejected even inside a factory or computed property: otherwise a harmless
looking constructor default can reach them indirectly. This is a lexical guard,
not data-flow analysis of aliases or a sandbox against deliberately hidden I/O.
"""
import argparse
from pathlib import Path
import re
import sys

NON_LOCATION_MEMBERS = {
    "hermesDefaultCategory", "claudeCodeProjectSkillsRel", "grokProjectSkillsRel", "codexAgentsRel",
    "defaultClaudeCodeTokenBudget", "defaultGrokTokenBudget", "defaultCursorTokenBudget",
    "defaultCodexTokenBudget", "charsPerToken",
}
RESOLVERS = {
    "Pensieve/Utilities/PathConstants.swift",  # Defines the real paths without performing I/O.
    "Pensieve/Utilities/Constants.swift",  # App re-exports the same definitions.
    "Pensieve/Utilities/RuntimePaths.swift",  # Selects the process paths and credential store.
}
# These callers explicitly select the process value; their collaborators still receive named paths.
PRODUCTION_CALLERS = {"Pensieve/AppRuntime.swift", "Pensieve/AppRuntime+Paths.swift",
                      "Pensieve/PensieveApp.swift", "PensieveDaemon/main.swift"}


def tokens(source):
    """Yield (text, offset), including executable Swift interpolation expressions."""
    pos = 0
    while pos < len(source):
        if source.startswith("//", pos):
            end = source.find("\n", pos)
            pos = len(source) if end < 0 else end
        elif source.startswith("/*", pos):
            depth = 1
            pos += 2
            while pos < len(source) and depth:
                if source.startswith("/*", pos):
                    depth += 1
                    pos += 2
                elif source.startswith("*/", pos):
                    depth -= 1
                    pos += 2
                else:
                    pos += 1
        elif (match := re.match(r'(#*)("""|")', source[pos:])):
            hashes, quote = match.groups()
            pos += len(match[0])
            closing, escape = quote + hashes, "\\" + hashes
            while pos < len(source) and not source.startswith(closing, pos):
                if source.startswith(escape + "(", pos):
                    start = pos + len(escape) + 1
                    # Tokens balance nested calls while string/comment readers own their interiors.
                    depth = 1
                    for token, offset in tokens(source[start:]):
                        if token == "(":
                            depth += 1
                        elif token == ")":
                            depth -= 1
                            if depth == 0:
                                pos = start + offset + 1
                                break
                        yield token, start + offset
                    else:
                        pos = len(source)
                elif source.startswith(escape, pos):
                    pos += len(escape) + 1
                else:
                    pos += 1
            pos += len(closing)
        elif (match := re.match(r'[A-Za-z_][A-Za-z_0-9]*', source[pos:])):
            yield match[0], pos
            pos += len(match[0])
        elif source[pos].isspace():
            pos += 1
        else:
            yield source[pos], pos
            pos += 1


def violations(source, relative):
    if relative in RESOLVERS:
        return []
    found = []
    lexed = list(tokens(source))
    for index, (token, offset) in enumerate(lexed):
        tail = [item[0] for item in lexed[index:index + 3]]
        reason = None
        if len(tail) == 3 and token in {"Constants", "PathConstants"} and tail[1] == "." and tail[2] not in NON_LOCATION_MEMBERS:
            reason = "live location must come from the runtime's paths value"
        elif token == "KeychainCredentialStore" and (tail[1:2] == ["("] or tail[1:] == [".", "init"]):
            reason = "real Keychain store must come from runtime resolution"
        elif token in {"RuntimePaths", "AppRuntimePaths"} and tail[1:] == [".", "production"] and relative not in PRODUCTION_CALLERS:
            reason = "production paths must be selected by the process runtime"
        elif tail[:2] == ["=", "."] and tail[2:] == ["production"] and relative not in PRODUCTION_CALLERS:
            reason = "a production paths default must be selected by the process runtime"
        elif token in {"NSHomeDirectory", "homeDirectoryForCurrentUser"}:
            reason = "home resolution belongs to the runtime's path definitions"
        if reason:
            line = source.count("\n", 0, offset) + 1
            found.append(f"{relative}:{line}: {reason}")
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    failures = []
    for folder in ("Pensieve", "PensieveDaemon"):
        directory = args.root / folder
        if not directory.is_dir():
            parser.error(f"missing source directory: {directory}")
        for path in sorted(directory.rglob("*.swift")):
            failures.extend(violations(path.read_text(), path.relative_to(args.root).as_posix()))
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
