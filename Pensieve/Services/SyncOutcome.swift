import Foundation

/// The result of one `SyncEngine.sync`. `Equatable` so tests assert it directly and `SyncModel` maps it
/// to UI state. `.synced(pushed:)` reports whether this sync created a local commit to publish; the push
/// op runs regardless, so a merged history and the upstream ref are always published.
enum SyncOutcome: Equatable {
    case synced(pushed: Bool, warnings: [String], ingestedHeadStamp: String? = nil, pulled: Bool = false)
    case conflicted([String])
    case noRemote
    case branchless

    static func == (lhs: SyncOutcome, rhs: SyncOutcome) -> Bool {
        switch (lhs, rhs) {
        case let (.synced(leftPushed, leftWarnings, _, leftPulled), .synced(rightPushed, rightWarnings, _, rightPulled)):
            return leftPushed == rightPushed && leftWarnings == rightWarnings && leftPulled == rightPulled
        case let (.conflicted(left), .conflicted(right)):
            return left == right
        case (.noRemote, .noRemote), (.branchless, .branchless):
            return true
        default:
            return false
        }
    }
}
