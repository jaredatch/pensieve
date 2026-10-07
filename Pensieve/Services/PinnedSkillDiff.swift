import Foundation

struct PinnedSkillFileDiff: Equatable {
    let path: String
    let kind: FileTreeChange.Kind
    let content: FileTreeChange.Content
    let permissions: FileTreeChange.Permissions?
    let diff: UnifiedDiff?
    var linesAdded: Int? { if case .modeOnly = content { return 0 }; return diff?.linesAdded }
    var linesRemoved: Int? { if case .modeOnly = content { return 0 }; return diff?.linesRemoved }

    init(change: FileTreeChange, result: UnifiedDiff?, unavailableContent: FileTreeChange.Content? = nil) {
        path = change.path
        kind = change.kind
        content = unavailableContent ?? change.content
        permissions = change.permissions
        diff = unavailableContent == nil ? result : nil
    }
}

struct PinnedSkillDiff: Equatable {
    static let maximumDiffWork = 64 * 1_024 * 1_024
    static let maximumDiffOutputLines = 65_536

    let files: [PinnedSkillFileDiff]
    let unreadFileCount: Int
    let bytesRead: Int
    var isIncomplete: Bool { unreadFileCount > 0 }

    /// All files share both budgets. Unavailable files retain paths and kinds, never their text buffers.
    static func build(comparison: FileTreeComparison,
                      budget: BoundedLineDifference.WorkBudget = .init(maximumWork: maximumDiffWork),
                      checkpoint: (Int) throws -> Void = { _ in }) throws -> PinnedSkillDiff {
        try Task.checkCancellation()
        var remainingOutput = maximumDiffOutputLines
        let files = try comparison.changes.map { change -> PinnedSkillFileDiff in
            try Task.checkCancellation()
            guard case let .text(old, new) = change.content else {
                return PinnedSkillFileDiff(change: change, result: nil)
            }
            guard remainingOutput > 0 else {
                return PinnedSkillFileDiff(change: change, result: nil, unavailableContent: .diffOutputBoundReached)
            }
            guard !budget.isExhausted else {
                return PinnedSkillFileDiff(change: change, result: nil, unavailableContent: .diffBudgetExhausted)
            }
            let sharedBudgetLimitsSearch = budget.remaining < BoundedLineDifference.maximumWork
            let result = try UnifiedDiff(old: old, new: new, budget: budget, maximumOutputLines: remainingOutput) { work in
                try Task.checkCancellation()
                try checkpoint(work)
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
            if result.isOutputBoundReached {
                return PinnedSkillFileDiff(change: change, result: nil, unavailableContent:
                    result.requiredOutputLines > maximumDiffOutputLines ? .diffOutputTooLarge : .diffOutputBoundReached)
            }
            if result.isTooLarge {
                return PinnedSkillFileDiff(change: change, result: nil,
                                          unavailableContent: sharedBudgetLimitsSearch ? .diffBudgetExhausted : .tooLarge)
            }
            remainingOutput -= result.requiredOutputLines
            return PinnedSkillFileDiff(change: change, result: result)
        }
        return PinnedSkillDiff(files: files, unreadFileCount: comparison.unreadFileCount, bytesRead: comparison.bytesRead)
    }
}
