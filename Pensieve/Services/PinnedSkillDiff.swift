import Foundation

struct PinnedSkillFileDiff: Equatable {
    let path: String
    let kind: FileTreeChange.Kind
    let content: FileTreeChange.Content
    let diff: UnifiedDiff?
    var linesAdded: Int? { diff?.linesAdded }
    var linesRemoved: Int? { diff?.linesRemoved }

    init(change: FileTreeChange) {
        path = change.path
        kind = change.kind
        content = change.content
        if case let .text(old, new) = change.content {
            diff = UnifiedDiff(old: old, new: new)
        } else {
            diff = nil
        }
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
