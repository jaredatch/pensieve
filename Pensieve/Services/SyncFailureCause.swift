import Foundation

/// Chooses sync presentation independently of the raw descriptions retained by the audit.
enum SyncFailureCause {
    static func message(for error: Error, fallback: String? = nil) -> String {
        switch error {
        case let git as GitError:
            return git.cause
        case let blocked as ConflictAbortBlocked:
            return message(for: blocked.underlying) + " " + blocked.folderAdvice
        case let SyncError.returnToRestFailed(_, _, reasonCause, detailCause):
            return reasonCause + " Pensieve couldn’t return the store to rest. Resolve this problem, then sync again: "
                + detailCause
        default:
            return (error as? LocalizedError)?.errorDescription ?? fallback ?? error.localizedDescription
        }
    }
}
