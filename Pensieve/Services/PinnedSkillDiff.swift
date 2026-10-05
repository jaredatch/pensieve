import Foundation

struct PinnedSkillFileDiff: Equatable {
    let path: String
    let kind: FileTreeChange.Kind
    let content: FileTreeChange.Content
    let diff: UnifiedDiff?
    var linesAdded: Int? { if case .modeOnly = content { return 0 }; return diff?.linesAdded }
    var linesRemoved: Int? { if case .modeOnly = content { return 0 }; return diff?.linesRemoved }

    init(change: FileTreeChange) {
        self.init(change: change) { UnifiedDiff(old: $0, new: $1) }
    }

    init(change: FileTreeChange, makeDiff: (String, String) throws -> UnifiedDiff) rethrows {
        let result: UnifiedDiff?
        if case let .text(old, new) = change.content {
            result = try makeDiff(old, new)
        } else { result = nil }
        self.init(change: change, result: result)
    }

    init(change: FileTreeChange, result: UnifiedDiff?) {
        path = change.path
        kind = change.kind
        content = result?.isTooLarge == true ? .tooLarge : change.content
        diff = result?.isTooLarge == true ? nil : result
    }

}

struct PinnedSkillDiff: Equatable {
    static let maximumDiffWork = 64 * 1_024 * 1_024

    let files: [PinnedSkillFileDiff]
    let unreadFileCount: Int
    let bytesRead: Int
    var isIncomplete: Bool { unreadFileCount > 0 }

    init(comparison: FileTreeComparison) {
        let budget = BoundedLineDifference.WorkBudget(maximumWork: Self.maximumDiffWork)
        self.init(comparison: comparison) { change in
            PinnedSkillFileDiff(change: change) { UnifiedDiff(old: $0, new: $1, budget: budget) }
        }
    }

    /// Throwing preview builder exposes diff progress so cancellation can stop inside the work.
    static func build(comparison: FileTreeComparison,
                      budget: BoundedLineDifference.WorkBudget = .init(maximumWork: maximumDiffWork),
                      checkpoint: (Int) throws -> Void = { _ in }) throws -> PinnedSkillDiff {
        try Task.checkCancellation()
        return try PinnedSkillDiff(comparison: comparison) { change in
            try Task.checkCancellation()
            let file = try PinnedSkillFileDiff(change: change) { old, new in
                try UnifiedDiff(old: old, new: new, budget: budget) { work in
                    try Task.checkCancellation()
                    try checkpoint(work)
                    try Task.checkCancellation()
                }
            }
            try Task.checkCancellation()
            return file
        }
    }

    private init(comparison: FileTreeComparison, makeFile: (FileTreeChange) throws -> PinnedSkillFileDiff) rethrows {
        files = try comparison.changes.map(makeFile)
        unreadFileCount = comparison.unreadFileCount
        bytesRead = comparison.bytesRead
    }

    /// Compatibility for the sheet's current one-file presentation until it consumes the file list.
    init(currentSkillMarkdown: String, upstreamSkillMarkdown: String) {
        self.init(comparison: FileTreeComparison(changes: [FileTreeChange(
            path: "SKILL.md", kind: .modified, content: .text(old: currentSkillMarkdown, new: upstreamSkillMarkdown)
        )], unreadFileCount: 0, bytesRead: 0))
    }

    var currentSkillMarkdown: String {
        guard let file = files.first(where: { $0.path == "SKILL.md" }), case let .text(old, _) = file.content else { return "" }
        return old
    }

    var upstreamSkillMarkdown: String {
        guard let file = files.first(where: { $0.path == "SKILL.md" }), case let .text(_, new) = file.content else { return "" }
        return new
    }
}
