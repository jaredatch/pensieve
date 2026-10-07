import Foundation
import Observation

extension UpdatesViewModel {
    /// The sheet owns its busy state. Window callers wait for its result without inspecting the batch.
    func waitForCompletion(affecting skillID: UUID) async throws {
        let wait = UpdatesCompletionWait(model: self, skillID: skillID)
        await withTaskCancellationHandler {
            await withCheckedContinuation { wait.start($0) }
        } onCancel: {
            Task { @MainActor in wait.finish() }
        }
        try Task.checkCancellation()
    }

    fileprivate func operationAffects(_ skillID: UUID) -> Bool {
        recheckingSkillID == skillID
            || (isApplying && (selectedSkillIDs.contains(skillID) || statuses[skillID] == .updating))
    }
}

/// One-shot observations are rearmed only on changes. Cancellation resumes the continuation once.
@MainActor
private final class UpdatesCompletionWait {
    let model: UpdatesViewModel
    let skillID: UUID
    var continuation: CheckedContinuation<Void, Never>?
    var finished = false

    init(model: UpdatesViewModel, skillID: UUID) {
        self.model = model
        self.skillID = skillID
    }

    func start(_ continuation: CheckedContinuation<Void, Never>) {
        guard !finished else { continuation.resume(); return }
        self.continuation = continuation
        observe()
    }

    private func observe() {
        guard !finished else { return }
        let busy = withObservationTracking {
            model.operationAffects(skillID)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        if !busy { finish() }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        continuation?.resume()
        continuation = nil
    }
}
