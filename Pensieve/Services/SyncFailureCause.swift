import Foundation

/// Chooses sync presentation independently of the raw descriptions retained by the audit.
enum SyncFailureCause {
    struct Presentation {
        let cause: String
        let needsLogPointer: Bool
    }

    static func message(for error: Error, fallback: String? = nil, commandLink: CommandLinkInstaller? = nil) -> String {
        let presentation = presentation(for: error, fallback: fallback)
        guard presentation.needsLogPointer else { return presentation.cause }
        return presentation.cause + " Run " + logCommand(commandLink) + " in Terminal for the details."
    }

    /// Engines retain clean causes and pointer intent, without reading the command's installation state.
    static func presentation(for error: Error, fallback: String? = nil) -> Presentation {
        switch error {
        case let git as GitError:
            let abort: Bool
            if case let .commandFailed(args, _, _, _) = git {
                abort = args.suffix(2) == ["rebase", "--abort"]
            } else { abort = false }
            return Presentation(cause: git.cause, needsLogPointer: abort)
        case let blocked as ConflictAbortBlocked:
            let cause = (blocked.underlying as? GitError)?.cause ?? presentation(for: blocked.underlying).cause
            return Presentation(cause: cause + " " + blocked.folderAdvice, needsLogPointer: false)
        case let SyncError.returnToRestFailed(_, _, reasonCause, detailCause, needsLogPointer):
            return Presentation(cause: reasonCause
                + " Pensieve couldn’t return the store to rest. Resolve this problem, then sync again: "
                + detailCause, needsLogPointer: needsLogPointer)
        default:
            return Presentation(cause: (error as? LocalizedError)?.errorDescription ?? fallback ?? error.localizedDescription,
                                needsLogPointer: false)
        }
    }

    private static func logCommand(_ installer: CommandLinkInstaller?) -> String {
        let executable = installer?.executable ?? Bundle.main.bundlePath + "/Contents/Helpers/pensieve"
        // Display cleanup must never turn the command into a different filesystem path.
        guard DisplayTextSanitizer.singleLine(executable) == executable else { return "pensieve log" }
        if let installer, let status = try? installer.status() {
            switch status {
            case .installed, .homebrew: return "pensieve log"
            case let .alongsideHomebrew(local, _) where !local.hasProblem: return "pensieve log"
            default: break
            }
        }
        let bare = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+")
        let path = executable.unicodeScalars.allSatisfy(bare.contains) ? executable
            : "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return path + " log"
    }
}
