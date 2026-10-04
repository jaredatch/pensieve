import Foundation

/// The successful result of deploying one (skill, platform) pair.
struct DeployOutcome {
    let targetPath: String
}

/// One (skill, platform) pair's target inside a batch.
enum BatchPairTarget: Equatable {
    case userWide
    case project(UUID)

    init(_ target: DeployTarget) {
        self = target.project.map { .project($0.id) } ?? .userWide
    }
}

struct BatchPairOutcome: Identifiable {
    let id = UUID()
    let skillID: UUID
    let skillName: String
    let platform: PlatformTarget
    let target: BatchPairTarget?
    let error: String?
    let projectFolderError: ProjectFolderError?
    var isSkipped = false

    init(
        skillID: UUID,
        skillName: String,
        platform: PlatformTarget,
        target: BatchPairTarget? = nil,
        error: String?,
        projectFolderError: ProjectFolderError? = nil
    ) {
        self.skillID = skillID
        self.skillName = skillName
        self.platform = platform
        self.target = target
        self.error = error
        self.projectFolderError = projectFolderError
    }

    var isSuccess: Bool { error == nil && !isSkipped }

    static func failureMessage(_ error: Error, target: DeployTarget) -> String {
        let prefix = target.project.map { $0.name + ": " } ?? ""
        return prefix + error.localizedDescription
    }
}

/// A batch-wide state read that failed before Pensieve could safely determine any pair work.
struct BatchReadFailure: Identifiable {
    let id = UUID()
    let message: String
}

/// The aggregate result of a bulk deploy/remove. Pair attempts stay in `outcomes`; a state read
/// that prevents safe pair work is carried separately so it cannot impersonate a deploy.
struct BatchResult {
    var outcomes: [BatchPairOutcome] = []
    var readFailures: [BatchReadFailure] = []

    var successes: [BatchPairOutcome] { outcomes.filter { $0.isSuccess } }
    var failures: [BatchPairOutcome] { outcomes.filter { !$0.isSuccess && !$0.isSkipped } }
    var skipped: [BatchPairOutcome] { outcomes.filter(\.isSkipped) }
    var failureCount: Int { failures.count + readFailures.count }
    var hasFailures: Bool { failureCount > 0 }

    /// Convergence waits quietly for missing folders. Lookup failures remain failures.
    func skippingMissingProjects() -> BatchResult {
        var result = self
        for index in result.outcomes.indices {
            if case .missing? = result.outcomes[index].projectFolderError {
                result.outcomes[index].isSkipped = true
            }
        }
        return result
    }

    /// An explicit category deploy presents the same missing-folder reason as a direct deploy.
    func reportingSkippedProjects(where includes: (BatchPairOutcome) -> Bool) -> BatchResult {
        var result = self
        for index in result.outcomes.indices where includes(result.outcomes[index]) {
            result.outcomes[index].isSkipped = false
        }
        return result
    }

    static func readFailure(_ subject: String, error: Error) -> BatchResult {
        var result = BatchResult()
        result.recordReadFailure(subject, error: error)
        return result
    }

    mutating func recordReadFailure(_ subject: String, error: Error) {
        readFailures.append(BatchReadFailure(
            message: "Pensieve couldn't read \(subject), so it stopped before changing any deploys. "
                + error.localizedDescription
        ))
    }

    mutating func append(_ other: BatchResult) {
        outcomes.append(contentsOf: other.outcomes)
        readFailures.append(contentsOf: other.readFailures)
    }
}
