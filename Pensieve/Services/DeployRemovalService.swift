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

/// Leaf adapters supply a throwing ownership check and an owned-artifact delete. The real adapters
/// use FileService; protocol adapters can preserve their own storage and error semantics.
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

struct DeployRemovalCandidate {
    let key: DeployRemovalKey
    let evidence: Set<DeployRemovalEvidence>
    let operation: DeployRemovalOperation
    var retireIfUnowned = true
    /// Skill cleanup fences owned artifacts when its up-front state snapshot was unreadable.
    var removalBlocker: Error?
}

struct DeployRemovalResult {
    var removed: Set<DeployRemovalKey> = []
    var retired: Set<DeployRemovalKey> = []
    var failures: [DeployRemovalKey: Error] = [:]
    var failuresBeforeDeletion: Set<DeployRemovalKey> = []
    var attemptedDeletions: Set<DeployRemovalKey> = []
    var stateWriteFailure: Error?
    var didChangeRecords = false
    var didAttemptDeletion: Bool { !attemptedDeletions.isEmpty }

    var completed: Set<DeployRemovalKey> { removed.union(retired) }
}

protocol DeployRemovalServicing {
    func remove(_ candidates: [DeployRemovalCandidate]) -> DeployRemovalResult
}

/// The shared removal pipeline. Each candidate is classified once before its throwing delete.
/// Artifact failures remain per pair; the single locked state retirement has a separate failure.
/// Returning those errors as data lets each caller preserve its own retry and reporting policy.
struct DeployRemovalService: DeployRemovalServicing {
    let stateStore: DeployStateStore

    func remove(_ candidates: [DeployRemovalCandidate]) -> DeployRemovalResult {
        var result = DeployRemovalResult()
        var seen: Set<DeployRemovalKey> = []
        for candidate in candidates where seen.insert(candidate.key).inserted {
            do {
                let disposition = try Self.apply(candidate.operation, blocker: candidate.removalBlocker) {
                    result.attemptedDeletions.insert(candidate.key)
                }
                if disposition == .removed {
                    result.removed.insert(candidate.key)
                } else if disposition == .preserved || candidate.retireIfUnowned {
                    result.retired.insert(candidate.key)
                }
            } catch {
                result.failures[candidate.key] = error
                if !result.attemptedDeletions.contains(candidate.key) {
                    result.failuresBeforeDeletion.insert(candidate.key)
                }
            }
        }
        do {
            result.didChangeRecords = try stateStore.remove(artifactPaths: Set(result.completed.map(\.artifactPath)))
        } catch {
            result.stateWriteFailure = error
        }
        return result
    }

    /// Direct leaf removals share the same ownership-before-delete rule without changing records.
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
