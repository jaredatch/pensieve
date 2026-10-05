import Foundation

struct PinnedSkillFileDiff: Equatable {
    let path: String
    let kind: FileTreeChange.Kind
    let content: FileTreeChange.Content
    let diff: UnifiedDiff?
    var linesAdded: Int? { if case .modeOnly = content { return 0 }; return diff?.linesAdded }
    var linesRemoved: Int? { if case .modeOnly = content { return 0 }; return diff?.linesRemoved }

    init(change: FileTreeChange) {
        let budget = BoundedLineDifference.WorkBudget(maximumWork: PinnedSkillDiff.maximumDiffWork)
        self.init(change: change, budget: budget) { UnifiedDiff(old: $0, new: $1, budget: budget) }
    }

    init(change: FileTreeChange,
         budget: BoundedLineDifference.WorkBudget = .init(maximumWork: PinnedSkillDiff.maximumDiffWork),
         makeDiff: (String, String) throws -> UnifiedDiff) rethrows {
        let sharedBudgetLimitsSearch = budget.remaining < BoundedLineDifference.maximumWork
        let result: UnifiedDiff?
        if case let .text(old, new) = change.content {
            guard !budget.isExhausted else {
                self.init(change: change, result: nil, diffBudgetExhausted: true)
                return
            }
            result = try makeDiff(old, new)
        } else { result = nil }
        self.init(change: change, result: result,
                  diffBudgetExhausted: result?.isTooLarge == true && sharedBudgetLimitsSearch)
    }

    init(change: FileTreeChange, result: UnifiedDiff?, diffBudgetExhausted: Bool = false) {
        path = change.path
        kind = change.kind
        content = diffBudgetExhausted ? .diffBudgetExhausted : (result?.isTooLarge == true ? .tooLarge : change.content)
        diff = diffBudgetExhausted || result?.isTooLarge == true ? nil : result
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
            PinnedSkillFileDiff(change: change, budget: budget) { UnifiedDiff(old: $0, new: $1, budget: budget) }
        }
    }

    /// Throwing preview builder exposes diff progress so cancellation can stop inside the work.
    static func build(comparison: FileTreeComparison,
                      budget: BoundedLineDifference.WorkBudget = .init(maximumWork: maximumDiffWork),
                      checkpoint: (Int) throws -> Void = { _ in }) throws -> PinnedSkillDiff {
        try Task.checkCancellation()
        return try PinnedSkillDiff(comparison: comparison) { change in
            try Task.checkCancellation()
            let file = try PinnedSkillFileDiff(change: change, budget: budget) { old, new in
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

}
