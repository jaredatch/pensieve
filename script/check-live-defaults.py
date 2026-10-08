#!/usr/bin/env python3
"""Fence live-state resolution to RuntimePaths and the constant definitions.

Scans app/daemon Swift source, ignoring comments and inert string contents but
checking string interpolations. Direct live constants and Keychain construction
are rejected even inside a factory or computed property: otherwise a harmless
looking constructor default can reach them indirectly. This is a lexical guard,
not data-flow analysis of aliases or a sandbox against deliberately hidden I/O.
"""
import argparse
import json
from pathlib import Path
import re
import sys

INVENTORY = "script/runtime-path-members.json"
CONSTANT_TYPES = {"Constants", "PathConstants"}
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
        elif (match := re.match(r'`([A-Za-z_][A-Za-z_0-9]*)`', source[pos:])):
            yield match[1], pos
            pos += len(match[0])
        elif (match := re.match(r'[A-Za-z_][A-Za-z_0-9]*', source[pos:])):
            yield match[0], pos
            pos += len(match[0])
        elif source[pos] in '!%&*+-/<=>?^|~':
            start = pos
            while pos < len(source) and source[pos] in '!%&*+-/<=>?^|~':
                if source.startswith(('//', '/*'), pos):
                    break
                pos += 1
            yield source[start:pos], start
        elif source[pos].isspace():
            pos += 1
        else:
            yield source[pos], pos
            pos += 1


def static_members(lexed):
    """Read direct static declarations in the constants types and their extensions."""
    depth, scopes, pending = 0, [], None
    for index, (token, offset) in enumerate(lexed):
        following = [item[0] for item in lexed[index + 1:index + 4]]
        if token in {'enum', 'struct', 'class', 'extension'} and following[:1] and following[0] in CONSTANT_TYPES:
            pending = following[0]
        if token == '{':
            depth += 1
            if pending:
                scopes.append((depth, pending))
                pending = None
        elif token == '}':
            if scopes and scopes[-1][0] == depth:
                scopes.pop()
            depth -= 1
        elif token == 'static' and scopes and scopes[-1][0] == depth:
            name = following[1] if len(following) >= 2 and following[0] in {'let', 'var', 'func', 'subscript'} else '<declaration>'
            yield scopes[-1][1] + '.' + name, name, offset


def permitted_production(lexed, index):
    """Allow a case pattern or a direct comparison operand, including parentheses."""
    words = [item[0] for item in lexed]
    for token in reversed(words[:index]):
        if token in {'=', ':', ';', '{', '}', 'where'}:
            break
        if token == 'case':
            return True
    start, end = index, index + 2
    while start > 0 and re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', words[start - 1]):
        start -= 1
        if start > 0 and words[start - 1] == '.':
            start -= 1
        else:
            break
    while start > 0 and end < len(words) and words[start - 1] == '(' and words[end] == ')':
        prefix = words[start - 2] if start >= 2 else ''
        if prefix in {')', ']', '>', '?', '!'} or (re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', prefix)
                                                  and prefix not in {'return', 'throw', 'if', 'guard', 'switch', 'case'}):
            break
        start -= 1
        end += 1
    following = words[end] if end < len(words) else ''
    boundary = following in {'', ')', ']', '}', ';', ',', ':', '{', '&&', '||', '?', '==', '!='}
    return (start > 0 and words[start - 1] in {'==', '!='} and boundary) or following in {'==', '!='}


def violations(source, relative, locations, neutral):
    found = []
    lexed = list(tokens(source))
    classified = locations | neutral
    for qualified, member, offset in static_members(lexed):
        if member not in classified:
            line = source.count('\n', 0, offset) + 1
            found.append(f'{relative}:{line}: unclassified static member {qualified}; classify it in {INVENTORY}')
    if relative in RESOLVERS:
        return found
    for index, (token, offset) in enumerate(lexed):
        tail = [item[0] for item in lexed[index:index + 3]]
        reason = None
        if len(tail) == 3 and token in CONSTANT_TYPES and tail[1] == '.':
            if tail[2] == 'self':
                reason = 'constants metatypes must not escape runtime resolution'
            elif tail[2] in locations:
                reason = "live location must come from the runtime's paths value"
            elif tail[2] not in neutral:
                reason = f'unclassified member {token}.{tail[2]}; classify it in {INVENTORY}'
        elif token == "KeychainCredentialStore" and (tail[1:2] == ["("] or tail[1:] == [".", "init"]):
            reason = "real Keychain store must come from runtime resolution"
        elif tail[:2] == ['.', 'production'] and relative not in PRODUCTION_CALLERS and not permitted_production(lexed, index):
            reason = 'production paths must be selected by the process runtime'
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
    inventory_path = args.root / INVENTORY
    if not inventory_path.is_file():
        inventory_path = Path(__file__).with_name('runtime-path-members.json')
    try:
        inventory = json.loads(inventory_path.read_text())
        locations, neutral = set(inventory['location']), set(inventory['nonLocation'])
        if locations & neutral or any(not isinstance(member, str) for member in locations | neutral):
            raise ValueError('members must have one classification')
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(f'{inventory_path}: {error}')
    failures = []
    for folder in ("Pensieve", "PensieveDaemon"):
        directory = args.root / folder
        if not directory.is_dir():
            parser.error(f"missing source directory: {directory}")
        for path in sorted(directory.rglob("*.swift")):
            failures.extend(violations(path.read_text(), path.relative_to(args.root).as_posix(), locations, neutral))
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
