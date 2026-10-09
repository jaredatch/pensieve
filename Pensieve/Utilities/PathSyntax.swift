import Foundation

/// Lexical filesystem paths: separators are Unicode scalars, never Swift Characters.
/// Comparisons normalize each component canonically, retaining APFS's NFC/NFD equivalence.
/// Returned components and relative paths keep their original spelling. No case folding, dot
/// collapse, symlink resolution or name admission belongs here; each caller retains that policy.
enum PathSyntax {
    static func components(_ path: String, omittingEmptySubsequences: Bool = true) -> [String] {
        path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: omittingEmptySubsequences)
            .map { String(String.UnicodeScalarView($0)) }
    }

    static func isAbsolute(_ path: String) -> Bool { path.unicodeScalars.first == "/" }
    static func hasSeparator(_ path: String) -> Bool { path.unicodeScalars.contains("/") }
    static func startsWithTilde(_ path: String) -> Bool { path.unicodeScalars.first == "~" }

    static func hasPrefix(_ path: String, _ prefix: String) -> Bool {
        let value = components(path, omittingEmptySubsequences: false)
        let expected = components(prefix, omittingEmptySubsequences: false)
        guard value.count >= expected.count else { return false }
        for index in expected.indices.dropLast() where !equalComponent(value[index], expected[index]) { return false }
        guard let last = expected.last else { return true }
        return normalized(value[expected.count - 1]).starts(with: normalized(last))
    }

    static func hasSuffix(_ path: String, _ suffix: String) -> Bool {
        let value = normalized(components(path, omittingEmptySubsequences: false).joined(separator: "/"))
        let expected = normalized(components(suffix, omittingEmptySubsequences: false).joined(separator: "/"))
        return value.suffix(expected.count).elementsEqual(expected)
    }

    /// A boundary-aware descendant suffix, including an empty suffix for the root itself.
    /// Trailing root separators don't create an extra component. Interior empty components stay.
    static func relativePath(_ path: String, under root: String) -> String? {
        let value = components(path, omittingEmptySubsequences: false)
        var expected = components(root, omittingEmptySubsequences: false)
        while expected.count > 1, expected.last == "" { expected.removeLast() }
        guard !root.isEmpty, value.count >= expected.count else { return nil }
        for index in expected.indices where !equalComponent(value[index], expected[index]) { return nil }
        return value.dropFirst(expected.count).joined(separator: "/")
    }

    static func isWithin(_ path: String, root: String, includingRoot: Bool = true) -> Bool {
        guard let relative = relativePath(path, under: root) else { return false }
        return includingRoot || !relative.isEmpty
    }

    private static func equalComponent(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs).elementsEqual(normalized(rhs))
    }

    private static func normalized(_ component: String) -> String.UnicodeScalarView {
        component.precomposedStringWithCanonicalMapping.unicodeScalars
    }
}
