import Foundation
import SwiftData

/// Dependencies for the window's independent pinned preview and Re-check.
struct UpdateReviewOperations {
    typealias DiffOperation = (UpdatesRow, ModelContainer) throws -> PinnedSkillDiff
    let diffOperation: DiffOperation
    let recheckOperation: UpdatesViewModel.RecheckOperation
}
