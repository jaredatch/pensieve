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
    let isOutputBoundReached: Bool
    /// Exact emitted count, including context, also available when output admission refuses the diff.
    let requiredOutputLines: Int

    init(old: String, new: String, budget: BoundedLineDifference.WorkBudget = .init(), maximumOutputLines: Int = .max) {
        self = (try? Self.compute(old: old, new: new, budget: budget,
                                 maximumOutputLines: maximumOutputLines, checkpoint: { _ in })) ?? Self.exceeded
    }

    init(old: String, new: String, budget: BoundedLineDifference.WorkBudget = .init(),
         maximumOutputLines: Int = .max, checkpoint: (Int) throws -> Void) throws {
        self = try Self.compute(old: old, new: new, budget: budget,
                                maximumOutputLines: maximumOutputLines, checkpoint: checkpoint)
    }

    private init(hunks: [UnifiedDiffHunk], linesAdded: Int, linesRemoved: Int,
                 isTooLarge: Bool, isOutputBoundReached: Bool = false, requiredOutputLines: Int = 0) {
        self.hunks = hunks
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.isTooLarge = isTooLarge
        self.isOutputBoundReached = isOutputBoundReached
        self.requiredOutputLines = requiredOutputLines
    }

    private static var exceeded: UnifiedDiff {
        UnifiedDiff(hunks: [], linesAdded: 0, linesRemoved: 0, isTooLarge: true)
    }

    private static func outputExceeded(lines: Int) -> UnifiedDiff {
        UnifiedDiff(hunks: [], linesAdded: 0, linesRemoved: 0, isTooLarge: false,
                    isOutputBoundReached: true, requiredOutputLines: lines)
    }

    private static func compute(old: String, new: String, budget: BoundedLineDifference.WorkBudget,
                                maximumOutputLines: Int, checkpoint: (Int) throws -> Void) throws -> UnifiedDiff {
        try checkpoint(0)
        guard !budget.isExhausted else { return exceeded }
        let before = Self.lines(old)
        let after = Self.lines(new)
        try checkpoint(0)
        guard let difference = try BoundedLineDifference.compute(before: before, after: after,
                                                                  budget: budget, checkpoint: checkpoint) else {
            return exceeded
        }
        let ranges = Self.hunkRanges(beforeCount: before.count, afterCount: after.count,
                                     removed: difference.removed, added: difference.added)
        let emitted = ranges.reduce(0) { $0 + $1.count }
        guard emitted <= maximumOutputLines else { return outputExceeded(lines: emitted) }
        // Row construction, hunk scanning and position tracking share the preview's work budget too.
        let rowCount = before.count + difference.added.count
        guard rowCount <= budget.remaining / 3 else {
            budget.spend(budget.remaining)
            return exceeded
        }
        budget.spend(rowCount * 3)
        let rows = Self.rows(before: before, after: after, removed: difference.removed, added: difference.added)
        try checkpoint(0)
        let hunks = Self.hunks(rows, ranges: ranges)
        guard emitted <= budget.remaining / 3 else {
            budget.spend(budget.remaining)
            return exceeded
        }
        budget.spend(emitted * 3)
        return UnifiedDiff(hunks: hunks, linesAdded: difference.added.count,
                           linesRemoved: difference.removed.count, isTooLarge: false, requiredOutputLines: emitted)
    }

    /// Git counts LF-terminated records, with one last record for an unterminated final line.
    /// Splitting UTF-8 bytes also avoids Swift treating CRLF as one Character or normalizing Unicode.
    static func lines(_ text: String) -> [String] {
        let bytes = Array(text.utf8)
        var result: [String] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 10 {
            result.append(String(validating: bytes[start...index], as: UTF8.self) ?? "")
            start = index + 1
        }
        if start < bytes.count { result.append(String(validating: bytes[start...], as: UTF8.self) ?? "") }
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

    /// Locate the same three-line-context ranges before constructing any line rows.
    private static func hunkRanges(beforeCount: Int, afterCount: Int,
                                   removed: Set<Int>, added: Set<Int>) -> [Range<Int>] {
        let rowCount = beforeCount + added.count
        if removed.count == beforeCount, added.count == afterCount {
            return rowCount == 0 ? [] : [0..<rowCount]
        }
        var ranges: [Range<Int>] = []
        var old = 0, new = 0, index = 0
        while old < beforeCount || new < afterCount {
            let changed: Bool
            if old < beforeCount, removed.contains(old) {
                old += 1; changed = true
            } else if new < afterCount, added.contains(new) {
                new += 1; changed = true
            } else {
                old += 1; new += 1; changed = false
            }
            if changed {
                let range = max(0, index - 3)..<min(rowCount, index + 4)
                if let last = ranges.last, range.lowerBound <= last.upperBound {
                    ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else { ranges.append(range) }
            }
            index += 1
        }
        return ranges
    }

    private static func hunks(_ rows: [UnifiedDiffLine], ranges: [Range<Int>]) -> [UnifiedDiffHunk] {
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
