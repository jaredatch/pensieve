#!/usr/bin/env python3
"""Reject grapheme-level slash/tilde tests on app and daemon filesystem paths.

This is a lexical architecture guard, not Swift type checking or full dataflow analysis.
It recognizes literals (including raw/multiline strings), comments, concatenation
and interpolated expressions, plus literal-bearing immutable local bindings.
Dynamically computed separators are outside its scope.
URL, ref and MIME operations are exempt only in the named owners below.
"""
import argparse
from pathlib import Path
import re
import sys

HELPER = "Pensieve/Utilities/PathSyntax.swift"
EXEMPTIONS = {
    "Pensieve/Services/SkillInstallURL.swift": {
        "SkillInstallURL.canonicalizeShorthand(_:String)",
        "SkillInstallURL.decodedPathSegments(_:String)",
        "SkillInstallURL.isValidPathSegment(_:String)"},  # GitHub URL segments.
    "Pensieve/Services/RemoteURLPolicy.swift": {"RemoteURLPolicy.parseScpStyle(_:String)"},  # URL scheme.
    "Pensieve/Services/SkillInstallService.swift": {"SkillInstallService.repositoryName(for:String)"},  # URL.
    "Pensieve/Services/SkillInstallService+Updates.swift": {"PinnedSkillUpdate.init(skill:Skill)"},  # Stored URL.
    "Pensieve/Services/ProjectIdentityService.swift": {
        "ProjectIdentityService.normalizeRemoteURL(_:String)",
        "ProjectIdentityService.parseURLForm(_:String)"},  # Origin URL.
    "Pensieve/Services/GitService.swift": {
        "GitService.remoteDefaultBranch(remote:String,credential:GitCredential?)",
        "GitService.remoteBranches(remote:String,credential:GitCredential?)"},  # Git refs.
    "Pensieve/Services/UpstreamHistoryService.swift": {"UpstreamHistoryService.isSafeRef(_:String)"},  # Git refs.
    "Pensieve/ViewModels/SyncSetupModel.swift": {"SyncSetupModel.isValidBranchName(_:String)"},  # Git refs.
    "Pensieve/Services/PreviewImageLoader.swift": {"PreviewImageLoader.embeddedData(_:URL)"},  # MIME image.
}


def lex(source, base=0):
    """Yield tokens with source offsets, retaining literals and executable interpolation."""
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
            start = pos
            hashes, quote = match.groups()
            closing, escape = quote + hashes, "\\" + hashes
            pos += len(match[0])
            content = ""
            nested = []
            while pos < len(source) and not source.startswith(closing, pos):
                if source.startswith(escape + "(", pos):
                    expr = pos + len(escape) + 1
                    depth = 1
                    for token, offset in lex(source[expr:], base + expr):
                        if token == "(":
                            depth += 1
                        elif token == ")":
                            depth -= 1
                            if not depth:
                                pos = offset - base + 1
                                break
                        nested.append((token, offset))
                    else:
                        pos = len(source)
                elif source.startswith(escape + "u{", pos):
                    end = source.find("}", pos)
                    if end < 0:
                        break
                    try:
                        content += chr(int(source[pos + len(escape) + 2:end], 16))
                    except ValueError:
                        pass
                    pos = end + 1
                elif source.startswith(escape, pos):
                    pos += len(escape)
                    content += source[pos:pos + 1]
                    pos += 1
                else:
                    content += source[pos]
                    pos += 1
            pos += len(closing)
            yield "literal:" + content, base + start
            yield from nested
        elif (match := re.match(r'`?([A-Za-z_][A-Za-z_0-9]*)`?', source[pos:])):
            yield match[1], base + pos
            pos += len(match[0])
        elif source[pos].isspace():
            pos += 1
        elif source.startswith("->", pos):
            yield "->", base + pos
            pos += 2
        else:
            yield source[pos], base + pos
            pos += 1


def owner_functions(tokens):
    """Identify nominal owner and external labels/types, distinguishing initializer overloads."""
    stack, pairs = [], {}
    for index, (word, _) in enumerate(tokens):
        if word in {"{", "("}:
            stack.append(index)
        elif word in {"}", ")"} and stack:
            pairs[stack.pop()] = index
    types = []
    for index, (word, _) in enumerate(tokens[:-1]):
        if word not in {"struct", "enum", "class", "actor", "extension", "protocol"}:
            continue
        if tokens[index + 1][0] in {"func", "var"}:
            continue
        for body in range(index + 2, len(tokens)):
            if tokens[body][0] == "{":
                if body in pairs:
                    types.append((index, pairs[body], tokens[index + 1][0]))
                break
            if tokens[body][0] in {";", "}"}:
                break
    ranges = []
    for index, (word, _) in enumerate(tokens):
        if word not in {"func", "init"}:
            continue
        if word == "init" and index > 0 and tokens[index - 1][0] == ".":
            continue
        name = tokens[index + 1][0] if word == "func" else "init"
        opening = next((i for i in range(index + 1, len(tokens)) if tokens[i][0] in {"(", "{", "}"}), None)
        if opening is None or tokens[opening][0] != "(" or opening not in pairs:
            continue
        closing = pairs[opening]
        params, current, depth = [], [], 0
        for token, _ in tokens[opening + 1:closing] + [("comma-end", 0)]:
            if (token == "," and depth == 0) or token == "comma-end":
                if ":" in current:
                    colon = current.index(":")
                    label = current[0]
                    kind = current[colon + 1:]
                    if "=" in kind:
                        kind = kind[:kind.index("=")]
                    params.append(label + ":" + "".join(kind))
                current = []
            else:
                depth += (token in {"(", "[", "<"}) - (token in {")", "]", ">"})
                current.append(token)
        enclosing = sorted((start, end, owner) for start, end, owner in types if start < index < end)
        owner = ".".join(entry[2] for entry in enclosing)
        signature = owner + "." + name + "(" + ",".join(params) + ")"
        for body in range(closing + 1, len(tokens)):
            if tokens[body][0] in {";", "}", "func", "init"}:
                break
            if tokens[body][0] == "{":
                if body in pairs:
                    ranges.append((index, pairs[body], signature))
                break
    return ranges



def separator_bindings(source, tokens):
    """Recognize simple immutable string expressions in their enclosing brace scope."""
    stack, scopes = [], {}
    for index, (word, _) in enumerate(tokens):
        if word == "{":
            stack.append(index)
        elif word == "}" and stack:
            scopes[stack.pop()] = index
    bindings = []
    for index, (word, _) in enumerate(tokens):
        if word != "let" or index + 2 >= len(tokens):
            continue
        name = tokens[index + 1][0]
        expression, depth, assigned = [], 0, False
        for cursor in range(index + 2, len(tokens)):
            token, offset = tokens[cursor]
            previous = tokens[cursor - 1][1]
            if depth == 0 and (token in {";", "}"} or "\n" in source[previous:offset]):
                break
            if not assigned:
                assigned = token == "="
                continue
            depth += (token in {"(", "["}) - (token in {")", "]"})
            expression.append(token)
        if any(token in {"Data", "UInt8", "utf8"} for token in expression):
            continue
        if any(token.startswith("literal:") and ("/" in token or "~" in token) for token in expression):
            ends = [end for start, end in scopes.items() if start < index < end]
            bindings.append((name, index, min(ends, default=len(tokens))))
    return bindings


def receiver_chain(tokens, member):
    """Walk only connected member accesses; adjacent statements cannot become receivers.

    A dot continues an expression across a newline. A bare identifier or semicolon
    before the receiver ends the walk, including statements ending in byte/scalar members.
    """
    parts, start = [], member - 2
    cursor = start
    while cursor >= 0 and re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", tokens[cursor][0]):
        parts.append(tokens[cursor][0])
        start = cursor
        cursor -= 1
        if cursor < 0 or tokens[cursor][0] != ".":
            break
        cursor -= 1
        if cursor >= 0 and tokens[cursor][0] in {"?", "!"}:
            cursor -= 1
    return parts, start


def comparison_operand(tokens, member, receiver_start):
    """Read ==/!= operands in either order, including parentheses and Character(...)."""
    words = [token for token, _ in tokens]
    operators = (["=", "="], ["!", "="])
    if words[member + 1:member + 3] in operators:
        start = member + 3
        if start >= len(tokens):
            return []
        end = start
        if words[start] == "Character" and words[start + 1:start + 2] == ["("]:
            end += 1
        if words[end] == "(":
            depth = 0
            for cursor in range(end, len(tokens)):
                depth += (words[cursor] == "(") - (words[cursor] == ")")
                if depth == 0:
                    end = cursor
                    break
            else:
                return []
        return tokens[start:end + 1]
    if receiver_start < 3 or words[receiver_start - 2:receiver_start] not in operators:
        return []
    end = receiver_start - 3
    start = end
    if words[end] == ")":
        depth = 0
        for cursor in range(end, -1, -1):
            depth += (words[cursor] == ")") - (words[cursor] == "(")
            if depth == 0:
                start = cursor
                if start > 0 and words[start - 1] == "Character":
                    start -= 1
                break
        else:
            return []
    return tokens[start:end + 1]


def violations(source, relative):
    if relative == HELPER:
        return []
    tokens = list(lex(source))
    functions = owner_functions(tokens)
    bindings = separator_bindings(source, tokens)
    failures = []
    for index, (word, offset) in enumerate(tokens):
        calls = {"hasPrefix", "hasSuffix", "contains", "split", "firstIndex", "starts"}
        if word not in calls | {"first", "last"} or index == 0 or tokens[index - 1][0] != ".":
            continue
        receiver, receiver_start = receiver_chain(tokens, index)
        if any(part in {"PathSyntax", "unicodeScalars", "utf8", "utf16"} for part in receiver):
            continue
        comparison = word in {"first", "last"}
        if comparison:
            expression = comparison_operand(tokens, index, receiver_start)
            if not expression:
                continue
        elif index + 1 >= len(tokens) or tokens[index + 1][0] != "(":
            continue
        else:
            expression = tokens[index + 1:]
        # A collection predicate may call PathSyntax inside its closure. UInt8(ascii:) is byte syntax.
        argument = [token for token, _ in tokens[index + 2:index + 10]]
        if argument[:2] in (["of", ":"], ["separator", ":"], ["with", ":"]):
            argument = argument[2:]
        if argument[:2] == ["where", ":"] or argument[:4] == ["UInt8", "(", "ascii", ":"]:
            continue
        depth, literals, identifiers = 0, [], []
        for token, _ in expression:
            if token == "(":
                depth += 1
            elif token == ")":
                depth -= 1
                if depth == 0:
                    break
            elif token.startswith("literal:"):
                literals.append(token[len("literal:"):])
            else:
                identifiers.append(token)
        bound_separator = any(name in identifiers and start < index < end for name, start, end in bindings)
        if not bound_separator and not any("/" in value or "~" in value for value in literals):
            continue
        enclosing = [entry for entry in functions if entry[0] <= index <= entry[1]]
        owner = min(enclosing, key=lambda entry: entry[1] - entry[0])[2] if enclosing else None
        if owner in EXEMPTIONS.get(relative, set()):
            continue
        line = source.count("\n", 0, offset) + 1
        failures.append(f"{relative}:{line}: use PathSyntax for scalar path separators ({word})")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    failures = []
    for folder in ("Pensieve", "PensieveDaemon"):
        for path in sorted((args.root / folder).rglob("*.swift")):
            failures.extend(violations(path.read_text(), path.relative_to(args.root).as_posix()))
    print("\n".join(failures) if failures else "Path separator guard OK")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
