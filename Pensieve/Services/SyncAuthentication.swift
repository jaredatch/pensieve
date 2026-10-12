import Foundation

/// Carries the credential used by one attempt, so advice describes that attempt even after a replacement.
struct SyncAuthentication {
    let remote: RemoteSpec?
    let credential: GitCredential?

    static func hasToken(_ credential: GitCredential?) -> Bool {
        guard case let .httpsToken(_, token) = credential else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func message(resolvingConflict: Bool = false) -> String? {
        guard let remote else { return nil }
        switch remote.transport {
        case .ssh:
            return "Couldn’t authenticate to \(remote.host) over SSH. Add your key to the agent "
                + "(run ssh-add in Terminal), then sync again."
        case .https:
            let advice = Self.hasToken(credential)
                ? "\(remote.host) didn’t accept the access token. Replace it in Settings › Sync"
                : "Sync over HTTPS needs an access token. Add one in Settings › Sync"
            return advice + (resolvingConflict ? ", then try again." : ".")
        }
    }

    func reporting(_ error: Error, resolvingConflict: Bool = false) -> Error {
        guard case GitError.authenticationFailed = error,
              let message = message(resolvingConflict: resolvingConflict) else { return error }
        return Failure(message: message)
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
