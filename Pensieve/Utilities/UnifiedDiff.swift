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

    let isTooLarge: Bool

    init(old: String, new: String, budget: BoundedLineDifference.WorkBudget = .init()) {
        self = (try? Self.compute(old: old, new: new, budget: budget, checkpoint: { _ in })) ?? Self.exceeded
    }

    init(old: String, new: String, budget: BoundedLineDifference.WorkBudget = .init(), checkpoint: (Int) throws -> Void) throws {
        self = try Self.compute(old: old, new: new, budget: budget, checkpoint: checkpoint)
    }

    private init(hunks: [UnifiedDiffHunk], linesAdded: Int, linesRemoved: Int, isTooLarge: Bool) {
        self.hunks = hunks
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.isTooLarge = isTooLarge
    }

    private static var exceeded: UnifiedDiff {
        UnifiedDiff(hunks: [], linesAdded: 0, linesRemoved: 0, isTooLarge: true)
    }

    private static func compute(old: String, new: String, budget: BoundedLineDifference.WorkBudget,
                                checkpoint: (Int) throws -> Void) throws -> UnifiedDiff {
        try checkpoint(0)
        guard !budget.isExhausted else { return exceeded }
        let before = Self.lines(old)
        let after = Self.lines(new)
        try checkpoint(0)
        guard let difference = try BoundedLineDifference.compute(before: before, after: after,
                                                                  budget: budget, checkpoint: checkpoint) else {
            return exceeded
        }
        let rows = Self.rows(before: before, after: after, removed: difference.removed, added: difference.added)
        try checkpoint(0)
        return UnifiedDiff(hunks: Self.hunks(rows), linesAdded: difference.added.count,
                           linesRemoved: difference.removed.count, isTooLarge: false)
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
