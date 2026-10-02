import Foundation

extension SkillInstallService {
    func cloneForInstall(remote: String, branch: String?, into path: String,
                         credential _: GitCredential?) throws {
        let installCredential = credentialStore.credential(forHost: CredentialHost.githubInstall)
        do {
            try gitService.cloneShallow(
                remote: remote,
                branch: branch,
                into: path,
                credential: installCredential
            )
        } catch {
            throw Self.mappedRepositoryError(error)
        }
    }

    static func mappedRepositoryError(_ error: Error) -> Error {
        guard let gitError = error as? GitError else { return error }
        switch gitError {
        case .unusable, .repositoryUnreadable:
            return error
        case .authenticationFailed:
            return SkillInstallError.authenticationFailed
        case let .commandFailed(_, _, stderr, _):
            let detail = stderr.lowercased()
            if Self.isAuthenticationFailure(detail) {
                return SkillInstallError.authenticationFailed
            }
            if Self.isRepositoryNotFound(detail) {
                return SkillInstallError.repositoryNotFound
            }
            if Self.isNetworkFailure(detail) { return SkillInstallError.networkUnavailable }
            return error
        }
    }

    private static func isAuthenticationFailure(_ detail: String) -> Bool {
        let markers = [
            "authentication failed",
            "could not read username",
            "invalid username or password",
            "permission denied (publickey)",
            "http 401",
            "http 403",
            "error: 401",
            "error: 403"
        ]
        return markers.contains { detail.contains($0) }
    }

    private static func isRepositoryNotFound(_ detail: String) -> Bool {
        if detail.contains("error: 404") || detail.contains("http 404") {
            return true
        }
        return detail.contains("repository")
            && (detail.contains("not found") || detail.contains("does not exist")
                || detail.contains("does not appear to be a git repository"))
    }

    /// curl's and ssh's words for a remote that cannot be reached at all — no DNS, no route, no answer.
    private static func isNetworkFailure(_ detail: String) -> Bool {
        let markers = [
            "could not resolve host",
            "failed to connect to",
            "couldn't connect to server",
            "network is unreachable",
            "connection timed out",
            "operation timed out"
        ]
        return markers.contains { detail.contains($0) }
    }
}
