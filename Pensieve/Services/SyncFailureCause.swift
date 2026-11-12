import Foundation

/// Chooses sync presentation independently of the raw descriptions retained by the audit.
enum SyncFailureCause {
    static func message(for error: Error, fallback: String? = nil) -> String {
        switch error {
        case let git as GitError:
            let pointer = " Run pensieve log in Terminal for the details."
            if case let .commandFailed(args, _, _, _) = git, args.suffix(2) == ["rebase", "--abort"] {
                return git.cause + pointer
            }
            return git.cause
        case let blocked as ConflictAbortBlocked:
            let cause = (blocked.underlying as? GitError)?.cause ?? message(for: blocked.underlying)
            return cause + " " + blocked.folderAdvice
        case let SyncError.returnToRestFailed(_, _, reasonCause, detailCause):
            return reasonCause + " Pensieve couldn’t return the store to rest. Resolve this problem, then sync again: "
                + detailCause
        default:
            return (error as? LocalizedError)?.errorDescription ?? fallback ?? error.localizedDescription
        }
    }
}
