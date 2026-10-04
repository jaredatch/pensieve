import Foundation

struct UnifiedDiffLine: Equatable {
    enum Kind { case context, added, removed }
    let kind: Kind
    /// Exact line bytes decoded as UTF-8, including LF when present. A CR is never normalized away.
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

struct UnifiedDiffHunk: Equatable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [UnifiedDiffLine]
    var header: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }
}

struct UnifiedDiff: Equatable {
    let hunks: [UnifiedDiffHunk]
    let linesAdded: Int
    let linesRemoved: Int

    init(old: String, new: String) {
        let before = Self.lines(old)
        let after = Self.lines(new)
        let difference = after.difference(from: before) { $0.utf8.elementsEqual($1.utf8) }
        var removed = Set<Int>()
        var added = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): added.insert(offset)
            }
        }
        linesAdded = added.count
        linesRemoved = removed.count
        let rows = Self.rows(before: before, after: after, removed: removed, added: added)
        hunks = Self.hunks(rows)
    }

    /// Git counts LF-terminated records, with one last record for an unterminated final line.
    /// Splitting UTF-8 bytes also avoids Swift treating CRLF as one Character or normalizing Unicode.
    static func lines(_ text: String) -> [String] {
        let bytes = Array(text.utf8)
        var result: [String] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 10 {
            result.append(String(bytes: bytes[start...index], encoding: .utf8) ?? "")
            start = index + 1
        }
        if start < bytes.count { result.append(String(bytes: bytes[start...], encoding: .utf8) ?? "") }
        return result
    }

    private static func rows(before: [String], after: [String], removed: Set<Int>, added: Set<Int>) -> [UnifiedDiffLine] {
        var result: [UnifiedDiffLine] = []
        var old = 0
        var new = 0
        while old < before.count || new < after.count {
            if old < before.count, removed.contains(old) {
                result.append(UnifiedDiffLine(kind: .removed, text: before[old], oldLineNumber: old + 1, newLineNumber: nil))
                old += 1
            } else if new < after.count, added.contains(new) {
                result.append(UnifiedDiffLine(kind: .added, text: after[new], oldLineNumber: nil, newLineNumber: new + 1))
                new += 1
            } else {
                result.append(UnifiedDiffLine(kind: .context, text: before[old], oldLineNumber: old + 1, newLineNumber: new + 1))
                old += 1
                new += 1
            }
        }
        return result
    }

    private static func hunks(_ rows: [UnifiedDiffLine]) -> [UnifiedDiffHunk] {
        var ranges: [Range<Int>] = []
        for index in rows.indices where rows[index].kind != .context {
            let range = max(0, index - 3)..<min(rows.count, index + 4)
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        var oldPosition = 0
        var newPosition = 0
        var positions: [(Int, Int)] = []
        for row in rows {
            positions.append((oldPosition, newPosition))
            if row.kind != .added { oldPosition += 1 }
            if row.kind != .removed { newPosition += 1 }
        }
        return ranges.map { range in
            let lines = Array(rows[range])
            let oldCount = lines.filter { $0.kind != .added }.count
            let newCount = lines.filter { $0.kind != .removed }.count
            let (old, new) = positions[range.lowerBound]
            return UnifiedDiffHunk(oldStart: old + (oldCount == 0 ? 0 : 1), oldCount: oldCount,
                                   newStart: new + (newCount == 0 ? 0 : 1), newCount: newCount, lines: lines)
        }
    }
}
