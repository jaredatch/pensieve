import Foundation
import Observation

/// Usability evidence and remote reads have separate clocks. Reading configuration cannot retire a real git result.
@MainActor
@Observable
final class RuntimeGitState {
    struct Change {
        let usability: GitUsability
        let recovered: Bool
    }

    private(set) var usability: GitUsability?
    private var evidenceOrder = 0
    private var appliedEvidenceOrder = 0
    private let probe: () throws -> GitUsability

    init(probe: @escaping () throws -> GitUsability) { self.probe = probe }

    func failureClassifier() -> (Error) -> ClassifiedUpdateFailure {
        let probe = probe
        return { error in
            guard case GitError.commandFailed = error else { return ClassifiedUpdateFailure.classify(error) }
            return ClassifiedUpdateFailure.classify(error, probe: probe)
        }
    }

    func beginEvidence() -> Int {
        evidenceOrder += 1
        return evidenceOrder
    }

    func accept(_ value: GitUsability, order: Int, model: SyncModel) -> Change? {
        guard order > appliedEvidenceOrder else { return nil }
        appliedEvidenceOrder = order
        let recovered = usability != .usable && value == .usable
        let wasUnavailable = model.configurationError != nil
        usability = value
        model.gitUsabilityDidChange(wasUnavailable: wasUnavailable, recovered: recovered)
        return Change(usability: value, recovered: recovered)
    }

    func refresh(probingGit: Bool, model: SyncModel) async -> Change? {
        let configuration = model.beginConfiguration()
        let cached = usability
        let read = model.configurationRead()
        let evidence = probingGit ? await probeGit() : nil
        let observed = evidence.flatMap { try? $0.result.get() }
        let remote: Result<SyncModel.Configuration, Error>?
        if case let .failure(error)? = evidence?.result {
            // A failed probe supplies no host evidence. Only known unusable git gates configuration failures.
            remote = cached == nil || cached == .usable ? .failure(error) : nil
        } else if (observed ?? cached) == .usable {
            remote = await BlockingWork.task(priority: .utility, operation: read).value
        } else {
            remote = nil
        }
        let change: Change?
        if let observed, let evidence {
            change = accept(observed, order: evidence.order, model: model)
        } else {
            change = nil
        }
        if let remote { model.applyConfiguration(remote, order: configuration) }
        return change
    }

    private func probeGit() async -> (order: Int, result: Result<GitUsability, Error>) {
        let order = beginEvidence()
        let probe = probe
        let result = await BlockingWork.task(priority: .utility) { Result { try probe() } }.value
        return (order, result)
    }
}
