import Foundation

/// Carries the credential used by one attempt, so advice describes that attempt even after a replacement.
struct SyncAuthentication {
    let remote: RemoteSpec?
    let credential: GitCredential?

    static func hasToken(_ credential: GitCredential?) -> Bool {
        guard case let .httpsToken(_, token, _) = credential else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func message(resolvingConflict: Bool = false, authenticationDetail: String = "") -> String? {
        guard let remote else { return nil }
        switch remote.transport {
        case .ssh:
            if let advice = Self.hostKeyMessage(host: remote.host, detail: authenticationDetail) { return advice }
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
        guard case let GitError.authenticationFailed(_, detail) = error,
              let message = message(resolvingConflict: resolvingConflict, authenticationDetail: detail) else { return error }
        return Failure(message: message)
    }

    static func hostKeyMessage(host: String, detail: String) -> String? {
        guard detail.lowercased().contains("host key verification failed") else { return nil }
        return "Connect to \(host) once with ssh in Terminal to check and accept its key, then sync again."
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
