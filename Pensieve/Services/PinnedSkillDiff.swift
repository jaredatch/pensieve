import Foundation

struct PinnedSkillFileDiff: Equatable {
    let path: String
    let kind: FileTreeChange.Kind
    let content: FileTreeChange.Content
    let diff: UnifiedDiff?
    var linesAdded: Int? { if case .modeOnly = content { return 0 }; return diff?.linesAdded }
    var linesRemoved: Int? { if case .modeOnly = content { return 0 }; return diff?.linesRemoved }

    init(change: FileTreeChange) {
        let result: UnifiedDiff?
        if case let .text(old, new) = change.content {
            result = UnifiedDiff(old: old, new: new)
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
    let files: [PinnedSkillFileDiff]
    let unreadFileCount: Int
    let bytesRead: Int
    var isIncomplete: Bool { unreadFileCount > 0 }

    init(comparison: FileTreeComparison) {
        files = comparison.changes.map(PinnedSkillFileDiff.init)
        unreadFileCount = comparison.unreadFileCount
        bytesRead = comparison.bytesRead
    }

    /// Throwing preview builder exposes diff progress so cancellation can stop inside the work.
    static func build(comparison: FileTreeComparison, checkpoint: (Int) throws -> Void = { _ in }) throws -> PinnedSkillDiff {
        try Task.checkCancellation()
        var files: [PinnedSkillFileDiff] = []
        for change in comparison.changes {
            try Task.checkCancellation()
            let result: UnifiedDiff?
            if case let .text(old, new) = change.content {
                result = try UnifiedDiff(old: old, new: new) { work in
                    try Task.checkCancellation()
                    try checkpoint(work)
                    try Task.checkCancellation()
                }
            } else { result = nil }
            try Task.checkCancellation()
            files.append(PinnedSkillFileDiff(change: change, result: result))
        }
        return PinnedSkillDiff(files: files, unreadFileCount: comparison.unreadFileCount, bytesRead: comparison.bytesRead)
    }

    private init(files: [PinnedSkillFileDiff], unreadFileCount: Int, bytesRead: Int) {
        self.files = files
        self.unreadFileCount = unreadFileCount
        self.bytesRead = bytesRead
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
