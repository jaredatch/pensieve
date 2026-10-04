import Foundation
import Yams

extension SkillParser {
    static func preservedFrontmatter(
        source: String,
        root: Node,
        rootIsFlowMapping: Bool
    ) -> PreservedFrontmatter {
        let lines = sourceLines(in: source)
        let entries = scanTopLevelEntries(in: source, lines: lines)
        let positionsAgree = root.mapping.map { mapping in
            mapping.count == entries.count && Set(entries.map(\.key)).count == entries.count
                && zip(mapping, entries).allSatisfy { pair, entry in
                guard let mark = pair.key.mark, mark.line > 0, mark.line <= lines.count else { return false }
                return pair.key.string == entry.key && mark.column == 1
                    && lines[mark.line - 1].sourceRange.lowerBound == entry.sourceRange.lowerBound
            }
        } ?? false
        let trustworthy = positionsAgree
            && !rootIsFlowMapping && !hasOddLineBreak(in: source)
            && !source.contains("\t") && !source.contains("---") && !containsAnchorOrAlias(in: source)
        return PreservedFrontmatter(
            source: source,
            entries: entries,
            entriesAreTrustworthy: trustworthy
        )
    }

    private static func scanTopLevelEntries(in source: String, lines: [SourceLine]) -> [PreservedFrontmatter.Entry] {
        var starts: [(key: String, index: String.Index)] = []
        for sourceLine in lines {
            let line = String(source[sourceLine.contentRange])
            if let key = topLevelKey(in: line) {
                starts.append((key, sourceLine.sourceRange.lowerBound))
            }
        }

        return starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1].index : source.endIndex
            return PreservedFrontmatter.Entry(
                key: starts[index].key,
                sourceRange: starts[index].index..<end
            )
        }
    }

    private static func topLevelKey(in line: String) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "#",
              let colon = line.firstIndex(of: ":") else {
            return nil
        }
        let afterColon = line.index(after: colon)
        guard afterColon == line.endIndex || line[afterColon].isWhitespace else { return nil }
        let key = line[..<colon]
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else { return nil }
        return String(key)
    }

    /// Agent fences are at column zero, with only trailing ASCII spaces, tabs or CR.
    static func isFrontmatterFence(_ line: Substring) -> Bool {
        line.hasPrefix("---") && line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    static func containsAnchorOrAlias(in source: String) -> Bool {
        let pattern = #"(^|[\s,\[\{])[&*][^\s,\[\]\{\}]+"#
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    static func trailingLineBreaks(in content: String) -> String {
        let scalars = content.unicodeScalars
        var start = scalars.endIndex
        while start > scalars.startIndex {
            let previous = scalars.index(before: start)
            guard isYAMLLineBreak(scalars[previous]) else { break }
            start = previous
        }
        return String(scalars[start...])
    }

    static func terminalLineEnding(in content: String) -> String {
        let scalars = content.unicodeScalars
        guard let last = scalars.last, isYAMLLineBreak(last) else { return "" }
        // A lone CR on an empty closing fence completes its separator, not a body suffix.
        guard last != "\r" else { return "" }
        return content.hasSuffix("\r\n") ? "\r\n" : String(last)
    }

    static func preferredLineEnding(in content: String) -> String {
        content.contains("\r\n") ? "\r\n" : "\n"
    }

    struct SourceLine {
        let contentRange: Range<String.Index>
        let sourceRange: Range<String.Index>
    }

    /// Matches libyaml's line counting, with CRLF treated as a single break, without changing bytes.
    static func sourceLines(in source: String, yamlBreaks: Bool = true) -> [SourceLine] {
        let scalars = source.unicodeScalars
        var lines: [SourceLine] = []
        var start = scalars.startIndex
        while let newline = scalars[start...].firstIndex(where: { yamlBreaks ? isYAMLLineBreak($0) : $0 == "\n" }) {
            var contentEnd = newline
            if !yamlBreaks, newline > start, scalars[scalars.index(before: newline)] == "\r" {
                contentEnd = scalars.index(before: newline)
            }
            var next = scalars.index(after: newline)
            if scalars[newline] == "\r", next < scalars.endIndex, scalars[next] == "\n" {
                next = scalars.index(after: next)
            }
            lines.append(SourceLine(contentRange: start..<contentEnd, sourceRange: start..<next))
            start = next
        }
        lines.append(SourceLine(contentRange: start..<scalars.endIndex, sourceRange: start..<scalars.endIndex))
        return lines
    }

    static func isYAMLLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\n", "\r", "\u{85}", "\u{2028}", "\u{2029}": return true
        default: return false
        }
    }

    private static func hasOddLineBreak(in source: String) -> Bool {
        let scalars = source.unicodeScalars
        return scalars.indices.contains { index in
            switch scalars[index] {
            case "\u{85}", "\u{2028}", "\u{2029}": return true
            case "\r":
                let next = scalars.index(after: index)
                return next == scalars.endIndex || scalars[next] != "\n"
            default: return false
            }
        }
    }
}
