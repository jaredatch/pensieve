import Foundation

/// The successful result of deploying one (skill, platform) pair.
struct DeployOutcome {
    let targetPath: String
}

/// One (skill, platform) pair's outcome inside a batch. `error == nil` means success.
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

    init(
        skillID: UUID,
        skillName: String,
        platform: PlatformTarget,
        target: BatchPairTarget? = nil,
        error: String?
    ) {
        self.skillID = skillID
        self.skillName = skillName
        self.platform = platform
        self.target = target
        self.error = error
    }

    var isSuccess: Bool { error == nil }
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
    var failures: [BatchPairOutcome] { outcomes.filter { !$0.isSuccess } }
    var failureCount: Int { failures.count + readFailures.count }
    var hasFailures: Bool { failureCount > 0 }

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
