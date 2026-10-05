import Foundation
import SwiftData

enum UpdateReviewResult {
    case apply(Result<SkillUpdateCompletion, Error>)
    case recheck(Result<SkillUpdateRecheckCompletion, Error>)

    /// Both surfaces use the same error mapping and canonical-write effects, even after presentation retirement.
    @MainActor
    func resolve(row: UpdatesRow, context: ModelContext, effects: UpdateReviewEffects) -> UpdatesRowStatus {
        do {
            switch self {
            case let .apply(result):
                let completion = try result.get()
                effects.echo([row.slug])
                UpdatesViewModel.applyCompletion(completion, context: context)
                effects.notify()
                return .updated
            case let .recheck(result):
                let completion = try result.get()
                UpdatesViewModel.applyRecheckCompletion(completion, context: context)
                if let error = completion.checkError { return .failed(message: error, offersRecheck: true) }
                return .idle
            }
        } catch {
            if error is SyncedStateMutationError {
                effects.echo([row.slug])
                effects.invalidateEditorBody()
                effects.notify()
                return .failedAfterReplacement(message: UpdatesViewModel.readable(error))
            }
            if error as? SkillUpdateFlowError == .localEditsRequireConfirmation { return .confirmationRequired }
            let recheck: Bool
            if case .recheck = self { recheck = true } else { recheck = UpdatesViewModel.offersRecheck(error) }
            return .failed(message: UpdatesViewModel.readable(error), offersRecheck: recheck)
        }
    }
}

struct UpdateReviewEffects {
    let echo: SyncWriteEchoRegistering
    let notify: SyncStateNotifying
    let invalidateEditorBody: () -> Void
}
