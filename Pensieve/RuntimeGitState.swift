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
        let recovered = usability != nil && usability != .usable && value == .usable
        let wasUnavailable = model.configurationError != nil
        usability = value
        model.gitUsabilityDidChange(wasUnavailable: wasUnavailable)
        return Change(usability: value, recovered: recovered)
    }

    func refresh(probingGit: Bool, model: SyncModel) async -> Change? {
        let evidence = probingGit ? beginEvidence() : nil
        let configuration = model.beginConfiguration()
        let cached = usability
        let probe = probe
        let read = model.configurationRead()
        let (observed, remote) = await BlockingWork.task(priority: .utility) {
            () -> (GitUsability?, Result<String?, Error>?) in
            do {
                let observed = probingGit ? try probe() : nil
                let remote = (observed ?? cached) == .usable ? read() : nil
                return (observed, remote)
            } catch {
                // A local probe read failure is configuration evidence, never host usability evidence.
                return (nil, .failure(error))
            }
        }.value
        let change: Change?
        if let observed, let evidence {
            change = accept(observed, order: evidence, model: model)
        } else {
            change = nil
        }
        if let remote { model.applyConfiguration(remote, order: configuration) }
        return change
    }
}
