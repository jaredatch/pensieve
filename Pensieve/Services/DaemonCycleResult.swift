import Foundation

/// The result of one daemon pull cycle (PLAN-12 / 12.6). SwiftData-free; `Equatable` so branch tests
/// assert it directly. `.synced(changed:)` — the store was already up-to-date (`changed:false`) or
/// fast-forwarded (`changed:true`); reconcile ran. `.skipped` — a safe no-op precondition; reconcile did
/// NOT run. `.failed` — a git/auth error mid-cycle.
enum DaemonCycleResult: Equatable {
    case synced(changed: Bool)
    case skipped(SkipReason)
    case failed(FailureReason)

    enum SkipReason: String, Equatable {
        case locked, noRemote, branchless, rejectedRemote, dirtyTree, diverged
    }
    enum FailureReason: Equatable {
        case authentication(String), gitError
        case preflight(String)

        var detail: String {
            switch self {
            case let .authentication(message): return message
            case .gitError: return "gitError"
            case let .preflight(message): return message
            }
        }
    }

    /// Coarse category for the status/log line ("synced" / "skipped" / "failed").
    var category: String {
        switch self {
        case .synced: return "synced"
        case .skipped: return "skipped"
        case .failed: return "failed"
        }
    }
    /// Fine detail for the status/log line.
    var detail: String {
        switch self {
        case let .synced(changed): return changed ? "fastForwarded" : "upToDate"
        case let .skipped(reason): return reason.rawValue
        case let .failed(reason): return reason.detail
        }
    }
}
