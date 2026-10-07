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
    let classify: () throws -> DeployArtifactOccupant
    let delete: () throws -> Bool

    init(fileService: FileServiceProtocol, path: String, classify: @escaping () throws -> DeployArtifactOccupant) {
        self.classify = classify
        self.delete = {
            try fileService.deleteFile(at: path)
            return true
        }
    }

    init(classify: @escaping () throws -> DeployArtifactOccupant, delete: @escaping () throws -> Bool) {
        self.classify = classify
        self.delete = delete
    }

    init(fileService: FileServiceProtocol, path: String, classify: @escaping () throws -> Bool) {
        self.init(fileService: fileService, path: path, classify: { try classify() ? .owned : .foreign })
    }

    init(classify: @escaping () throws -> Bool, delete: @escaping () throws -> Bool) {
        self.init(classify: { try classify() ? .owned : .foreign }, delete: delete)
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
    let foundAbsent: Bool

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

    var didRemoveArtifacts: Bool { outcomes.contains { $0.removed } }
    var completedArtifactPaths: Set<String> { Set(outcomes.filter(\.completed).map { $0.key.artifactPath }) }
    var didAttemptDeletion: Bool { outcomes.contains { $0.attemptedDeletion } }

    struct Report {
        let outcome: DeployRemovalOutcome
        let absentAfterRemoval: Bool
    }

    /// Duplicate absence changes reporting only; every occurrence has already been inspected.
    func orderedOutcomes<Input>(for inputs: [Input]) -> [(Input, Report)] {
        var removedPaths: Set<String> = []
        let work = zip(inputs, outcomes).map { input, outcome in
            let absentAfterRemoval = outcome.foundAbsent && removedPaths.contains(outcome.key.artifactPath)
            if outcome.removed { removedPaths.insert(outcome.key.artifactPath) }
            return (input, Report(outcome: outcome, absentAfterRemoval: absentAfterRemoval))
        }
        return work.filter { $0.1.outcome.failedBeforeDeletion } + work.filter { !$0.1.outcome.failedBeforeDeletion }
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
            result.didChangeRecords = try stateStore.remove(artifactPaths: result.completedArtifactPaths)
        } catch {
            result.stateWriteFailure = error
        }
        return result
    }

    private static func remove(_ candidate: DeployRemovalCandidate) -> DeployRemovalOutcome {
        var attempted = false, absent = false
        do {
            let disposition: DeployRemovalOutcome.Disposition
            switch candidate.action {
            case .retireWithoutInspection:
                disposition = .retired
                try fence(disposition, blocker: candidate.removalBlocker)
            case .fail(let error): throw error
            case .inspect(let operation):
                disposition = try apply(operation, retireIfUnowned: candidate.retireIfUnowned,
                    blocker: candidate.removalBlocker, didClassify: { absent = $0 == .absent },
                    willDelete: { attempted = true })
            }
            return DeployRemovalOutcome(key: candidate.key, disposition: disposition,
                attemptedDeletion: attempted, foundAbsent: absent)
        } catch {
            return DeployRemovalOutcome(key: candidate.key, disposition: .failed(error),
                attemptedDeletion: attempted, foundAbsent: absent)
        }
    }

    /// Direct leaf removals share the same adjacent check and delete without record retirement.
    static func removeArtifact(_ operation: DeployRemovalOperation) throws -> Bool {
        let disposition = try apply(operation, retireIfUnowned: false, blocker: nil,
            didClassify: { _ in }, willDelete: {})
        if case .removed = disposition { return true }
        return false
    }

    private static func fence(_ disposition: DeployRemovalOutcome.Disposition, blocker: Error?) throws {
        switch disposition {
        case .removed, .retired: if let blocker { throw blocker }
        case .ignored, .failed: break
        }
    }

    private static func apply(_ operation: DeployRemovalOperation, retireIfUnowned: Bool, blocker: Error?,
                              didClassify: (DeployArtifactOccupant) -> Void,
                              willDelete: () -> Void) throws -> DeployRemovalOutcome.Disposition {
        let occupant = try operation.classify()
        didClassify(occupant)
        let disposition: DeployRemovalOutcome.Disposition = occupant.isOwned ? .removed
            : (retireIfUnowned ? .retired : .ignored)
        try fence(disposition, blocker: blocker)
        guard occupant.isOwned else { return disposition }
        willDelete()
        return try operation.delete() ? .removed : .retired
    }
}
