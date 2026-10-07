import Foundation

struct DeployRemovalKey: Hashable {
    let slug: String
    let platform: PlatformTarget
    let projectPath: String?
    let artifactPath: String
}

enum DeployRemovalEvidence: Hashable {
    case selection, enumeratedSkillPath, deployState, localHistory, localProjectRecords, danglingLink
}

/// Adapters provide a throwing classification and an owned-artifact deletion without another check.
struct DeployRemovalOperation {
    let classify: () throws -> Bool
    let delete: () throws -> Bool

    init(fileService: FileServiceProtocol, path: String, classify: @escaping () throws -> Bool) {
        self.classify = classify
        self.delete = {
            try fileService.deleteFile(at: path)
            return true
        }
    }

    init(classify: @escaping () throws -> Bool, delete: @escaping () throws -> Bool) {
        self.classify = classify
        self.delete = delete
    }
}

enum DeployRemovalAction {
    case inspect(DeployRemovalOperation)
    /// The caller did not admit deletion, but its completed record still retires.
    case retireWithoutInspection
    /// Admission already failed. There is no artifact operation to execute.
    case fail(Error)
}

struct DeployRemovalCandidate {
    let key: DeployRemovalKey
    let evidence: Set<DeployRemovalEvidence>
    let action: DeployRemovalAction
    var retireIfUnowned = true
    var removalBlocker: Error?

    init(key: DeployRemovalKey, evidence: Set<DeployRemovalEvidence>, action: DeployRemovalAction) {
        self.key = key
        self.evidence = evidence
        self.action = action
    }

    init(key: DeployRemovalKey, evidence: Set<DeployRemovalEvidence>, operation: DeployRemovalOperation) {
        self.init(key: key, evidence: evidence, action: .inspect(operation))
    }
}

struct DeployRemovalOutcome {
    enum Disposition { case removed, retired, ignored, failed(Error) }
    let key: DeployRemovalKey
    let disposition: Disposition
    let attemptedDeletion: Bool

    var removed: Bool { if case .removed = disposition { return true }; return false }
    var retired: Bool { if case .retired = disposition { return true }; return false }
    var completed: Bool { removed || retired }
    var failure: Error? { if case .failed(let error) = disposition { return error }; return nil }
    var failedBeforeDeletion: Bool { failure != nil && !attemptedDeletion }
}

struct DeployRemovalResult {
    /// One outcome per input occurrence, in input order, even when keys repeat.
    var outcomes: [DeployRemovalOutcome] = []
    var stateWriteFailure: Error?
    var didChangeRecords = false

    var removed: Set<DeployRemovalKey> { keys { $0.removed } }
    var retired: Set<DeployRemovalKey> { keys { $0.retired } }
    var completed: Set<DeployRemovalKey> { keys { $0.completed } }
    var attemptedDeletions: Set<DeployRemovalKey> { keys { $0.attemptedDeletion } }
    var failuresBeforeDeletion: Set<DeployRemovalKey> { keys { $0.failedBeforeDeletion } }
    var didAttemptDeletion: Bool { outcomes.contains { $0.attemptedDeletion } }
    var failures: [DeployRemovalKey: Error] {
        Dictionary(outcomes.compactMap { outcome in outcome.failure.map { (outcome.key, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    private func keys(where predicate: (DeployRemovalOutcome) -> Bool) -> Set<DeployRemovalKey> {
        Set(outcomes.filter(predicate).map(\.key))
    }
}

protocol DeployRemovalServicing {
    func remove(_ candidates: [DeployRemovalCandidate]) -> DeployRemovalResult
}

/// Each occurrence is classified once. Results retain occurrence identity while record retirement
/// groups completed paths into one locked write. Callers decide ledger and reporting policy.
struct DeployRemovalService: DeployRemovalServicing {
    let stateStore: DeployStateStore

    func remove(_ candidates: [DeployRemovalCandidate]) -> DeployRemovalResult {
        var result = DeployRemovalResult(outcomes: candidates.map(Self.remove))
        do {
            result.didChangeRecords = try stateStore.remove(artifactPaths: Set(result.completed.map(\.artifactPath)))
        } catch {
            result.stateWriteFailure = error
        }
        return result
    }

    private static func remove(_ candidate: DeployRemovalCandidate) -> DeployRemovalOutcome {
        var attempted = false
        do {
            let disposition: DeployRemovalOutcome.Disposition
            switch candidate.action {
            case .retireWithoutInspection: disposition = .retired
            case .fail(let error): throw error
            case .inspect(let operation):
                let action = try apply(operation, blocker: candidate.removalBlocker) { attempted = true }
                switch action {
                case .removed: disposition = .removed
                case .preserved: disposition = .retired
                case .unowned: disposition = candidate.retireIfUnowned ? .retired : .ignored
                }
            }
            return DeployRemovalOutcome(key: candidate.key, disposition: disposition, attemptedDeletion: attempted)
        } catch {
            return DeployRemovalOutcome(key: candidate.key, disposition: .failed(error), attemptedDeletion: attempted)
        }
    }

    /// Direct leaf removals share the same check without changing deploy-state records.
    static func removeArtifact(_ operation: DeployRemovalOperation) throws -> Bool {
        try apply(operation, blocker: nil, willDelete: {}) == .removed
    }

    private enum Disposition { case unowned, removed, preserved }

    private static func apply(_ operation: DeployRemovalOperation, blocker: Error?,
                              willDelete: () -> Void) throws -> Disposition {
        guard try operation.classify() else { return .unowned }
        if let blocker { throw blocker }
        willDelete()
        return try operation.delete() ? .removed : .preserved
    }
}
