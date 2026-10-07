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
    var completed: Set<DeployRemovalKey> { keys { $0.completed } }
    var didAttemptDeletion: Bool { outcomes.contains { $0.attemptedDeletion } }
    /// Batch callers historically report inspection failures before deletion outcomes.
    func orderedOutcomes<Input>(for inputs: [Input]) -> [(Input, DeployRemovalOutcome)] {
        let work = Array(zip(inputs, outcomes))
        return work.filter { $0.1.failedBeforeDeletion } + work.filter { !$0.1.failedBeforeDeletion }
    }

    private func keys(where predicate: (DeployRemovalOutcome) -> Bool) -> Set<DeployRemovalKey> {
        Set(outcomes.filter(predicate).map(\.key))
    }
}

enum DeployRemovalInspection { case perCandidate, beforeBatch }

protocol DeployRemovalServicing {
    func remove(_ candidates: [DeployRemovalCandidate], inspection: DeployRemovalInspection) -> DeployRemovalResult
}

extension DeployRemovalServicing {
    func remove(_ candidates: [DeployRemovalCandidate]) -> DeployRemovalResult {
        remove(candidates, inspection: .perCandidate)
    }
}

/// Each occurrence is classified once. Results retain occurrence identity while record retirement
/// groups completed paths into one locked write. Callers decide ledger and reporting policy.
struct DeployRemovalService: DeployRemovalServicing {
    let stateStore: DeployStateStore

    func remove(_ candidates: [DeployRemovalCandidate], inspection: DeployRemovalInspection) -> DeployRemovalResult {
        let inspected = inspection == .beforeBatch ? candidates.map(Self.inspect) : nil
        var removedPaths: Set<String> = []
        var result = DeployRemovalResult(outcomes: candidates.enumerated().map { index, candidate in
            let outcome = Self.remove(candidate, inspected: inspected?[index] ?? Self.inspect(candidate),
                previouslyRemoved: removedPaths.contains(candidate.key.artifactPath))
            if outcome.removed { removedPaths.insert(candidate.key.artifactPath) }
            return outcome
        })
        do {
            result.didChangeRecords = try stateStore.remove(artifactPaths: Set(result.completed.map(\.artifactPath)))
        } catch {
            result.stateWriteFailure = error
        }
        return result
    }

    private static func inspect(_ candidate: DeployRemovalCandidate) -> Result<Bool, Error> {
        Result {
            switch candidate.action {
            case .inspect(let operation): return try operation.classify()
            case .retireWithoutInspection: return false
            case .fail(let error): throw error
            }
        }
    }

    private static func remove(_ candidate: DeployRemovalCandidate,
                               inspected: Result<Bool, Error>, previouslyRemoved: Bool) -> DeployRemovalOutcome {
        var attempted = false
        do {
            let owned = try inspected.get()
            let willRetire = owned || candidate.retireIfUnowned || isUnconditionalRetirement(candidate.action)
            if willRetire, let blocker = candidate.removalBlocker { throw blocker }
            let disposition: DeployRemovalOutcome.Disposition
            switch candidate.action {
            case .retireWithoutInspection: disposition = .retired
            case .fail(let error): throw error
            case .inspect(let operation):
                let action = try apply(operation, owned: owned, previouslyRemoved: previouslyRemoved) { attempted = true }
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

    private static func isUnconditionalRetirement(_ action: DeployRemovalAction) -> Bool {
        if case .retireWithoutInspection = action { return true }
        return false
    }

    /// Direct leaf removals share the same check without changing deploy-state records.
    static func removeArtifact(_ operation: DeployRemovalOperation) throws -> Bool {
        try apply(operation, owned: operation.classify(), willDelete: {}) == .removed
    }

    private enum Disposition { case unowned, removed, preserved }

    private static func apply(_ operation: DeployRemovalOperation, owned: Bool, previouslyRemoved: Bool = false,
                              willDelete: () -> Void) throws -> Disposition {
        guard owned else { return .unowned }
        willDelete()
        // A pre-admitted duplicate still completes its attempt after this batch removed the path.
        guard !previouslyRemoved else { return .preserved }
        return try operation.delete() ? .removed : .preserved
    }
}
