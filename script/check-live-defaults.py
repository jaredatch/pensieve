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
PATHS_TYPES = {"RuntimePaths", "AppRuntimePaths"}
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


# Swift keywords distinguish an expression receiver/callee from syntax such as `while (` or `in (`.
# This is lexical recognition, not type or data-flow inference.
KEYWORDS = set("""associatedtype class deinit enum extension fileprivate func import init inout internal
let open operator private precedencegroup protocol public rethrows static struct subscript typealias var
break case continue default defer do else fallthrough for guard if in repeat return switch where while
as Any catch false is nil super self Self throw throws true try async await some any""".split())


def ends_expression(word):
    return (bool(re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', word)) and word not in KEYWORDS) or word in {')', ']', '!', '?', 'self', 'super', 'Self'}


def brace_pairs(words):
    """An unbalanced token stream cannot establish a safe local shadow."""
    stack, pairs, balanced = [], {}, True
    for index, word in enumerate(words):
        if word == '{':
            stack.append(index)
        elif word == '}':
            if stack:
                pairs[stack.pop()] = index
            else:
                balanced = False
    return pairs, balanced and not stack


def constant_shadows(words, pairs, balanced):
    """Nested constants names shadow the global type throughout their enclosing lexical scope."""
    if not balanced:
        return []
    stack, shadows = [], []
    for index, word in enumerate(words):
        if word == '{':
            stack.append(index)
        elif word == '}' and stack:
            stack.pop()
        elif word in {'enum', 'struct', 'class'} and words[index + 1:index + 2] and words[index + 1] in CONSTANT_TYPES and stack:
            shadows.append((words[index + 1], stack[-1], pairs.get(stack[-1], len(words))))
    return shadows


def static_members(words, lexed, balanced):
    """Read direct static declarations in top-level constants types and unqualified extensions."""
    depth, scopes, pending = 0, [], None
    for index, token in enumerate(words):
        if (depth == 0 or not balanced) and token in {'enum', 'struct', 'class', 'extension'} and words[index + 1:index + 2] and words[index + 1] in CONSTANT_TYPES:
            pending = words[index + 1]
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
            # Access modifiers may contain parentheses, e.g. `static private(set) var foo`.
            cursor, parentheses, name = index + 1, 0, None
            while cursor < len(words):
                word = words[cursor]
                if parentheses == 0 and word in {'let', 'var', 'func', 'subscript'}:
                    name = word if word == 'subscript' else words[cursor + 1]
                    break
                if parentheses == 0 and word in {'{', '}', ';', '='}:
                    break
                parentheses += (word == '(') - (word == ')')
                cursor += 1
            # An unparsed declaration can never be excused by listing its diagnostic placeholder.
            yield scopes[-1][1] + '.' + (name or '<unparsed static declaration>'), name, lexed[index][1]


def paths_type_scopes(words, pairs):
    """Within a paths type, even lower-case `self` can name the metatype in a static member."""
    scopes = []
    for index, word in enumerate(words[:-1]):
        if word in {'enum', 'struct', 'class', 'extension'} and words[index + 1] in PATHS_TYPES:
            opening = next((cursor for cursor in range(index + 2, len(words)) if words[cursor] == '{'), None)
            if opening is not None:
                scopes.append((opening, pairs.get(opening, len(words))))
    return scopes


def opening_parenthesis(words, closing):
    depth = 1
    for index in range(closing - 1, -1, -1):
        depth += (words[index] == ')') - (words[index] == '(')
        if depth == 0:
            return index
    return None


def ends_callee(word):
    # Generic closing brackets end a callee, including nested generic arguments (`>>`).
    return ends_expression(word) or word == 'init' or bool(re.fullmatch(r'>+', word))


def paths_receiver_start(words, index, scopes):
    """Recognize known paths metatypes rather than exempting every expression receiver."""
    previous = words[index - 1] if index else ''
    if previous in PATHS_TYPES or previous == 'Self':
        return index - 1
    if previous == 'self':
        if index >= 2 and words[index - 2] == '.':
            return paths_receiver_start(words, index - 2, scopes)
        if any(start < index < end for start, end in scopes):
            return index - 1
    if previous == ')':
        opening = opening_parenthesis(words, index - 1)
        if opening is not None:
            if opening > 0 and words[opening - 1] == 'type' and words[opening + 1:opening + 3] == ['of', ':']:
                return opening - 1
            if opening == 0 or not ends_callee(words[opening - 1]):
                inner = paths_receiver_start(words, index - 1, scopes)
                if inner == opening + 1:
                    return opening
    return None


def paths_production(words, lexed, index, scopes):
    """Return the paths operand's start, or None for an ordinary value's property."""
    start = paths_receiver_start(words, index, scopes)
    if start is not None:
        while start >= 2 and words[start - 1] == '.' and ends_expression(words[start - 2]):
            start -= 2
        return start
    previous = words[index - 1] if index else ''
    if previous in {'?', '!'}:
        # Optional chaining is adjacent; the separated `? .production` is a ternary operand.
        return index if lexed[index - 1][1] + len(previous) != lexed[index][1] else None
    return None if ends_expression(previous) else index


def permitted_production(words, index, start):
    """Allow a case pattern or a direct comparison operand, including grouping parentheses."""
    for cursor in range(index - 1, -1, -1):
        token = words[cursor]
        if token in {'in', '=', ':', ';', '{', '}', 'where'}:
            break
        if token == 'case':
            return True
    end = index + 2
    while start > 0 and end < len(words) and words[start - 1] == '(' and words[end] == ')':
        # Grouping is one operand. A call's argument is not the call's comparison result.
        if start >= 2 and ends_callee(words[start - 2]):
            break
        start -= 1
        end += 1
    following = words[end] if end < len(words) else ''
    boundary = following in {'', ')', ']', '}', ';', ',', ':', '{', '&&', '||', '?', '==', '!=', 'else'}
    return (start > 0 and words[start - 1] in {'==', '!='} and boundary) or following in {'==', '!='}


def violations(source, relative, locations, neutral):
    found = []
    lexed = list(tokens(source))
    words = [item[0] for item in lexed]
    pairs, balanced = brace_pairs(words)
    shadows = constant_shadows(words, pairs, balanced)
    scopes = paths_type_scopes(words, pairs)
    classified = locations | neutral
    for qualified, member, offset in static_members(words, lexed, balanced):
        if member not in classified:
            line = source.count('\n', 0, offset) + 1
            found.append(f'{relative}:{line}: unclassified static member {qualified}; classify it in {INVENTORY}')
    if relative in RESOLVERS:
        return found
    for index, (token, offset) in enumerate(lexed):
        tail = [item[0] for item in lexed[index:index + 3]]
        reason = None
        if len(tail) == 3 and token in CONSTANT_TYPES and tail[1] == '.' and not any(
                name == token and start < index < end for name, start, end in shadows):
            if tail[2] == 'self':
                reason = 'constants metatypes must not escape runtime resolution'
            elif tail[2] in locations:
                reason = "live location must come from the runtime's paths value"
            elif tail[2] not in neutral:
                reason = f'unclassified member {token}.{tail[2]}; classify it in {INVENTORY}'
        elif token == "KeychainCredentialStore" and (tail[1:2] == ["("] or tail[1:] == [".", "init"] or words[index + 1:index + 5] == [".", "self", ".", "init"]):
            reason = "real Keychain store must come from runtime resolution"
        elif tail[:2] == ['.', 'production'] and relative not in PRODUCTION_CALLERS and (start := paths_production(words, lexed, index, scopes)) is not None and not permitted_production(words, index, start):
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
