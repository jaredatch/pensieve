import Foundation

enum PinnedCommitFetchError: Error {
    case invalidCommit
    case unavailable
}

extension GitService {
    /// Fetch only the saved commit, without resolving a moving branch or copying local history.
    @_disfavoredOverload
    func downloadPinnedCommit(remote: String, commit: String, into path: String,
                              credential: GitCredential?) throws {
        guard Self.isHistoryObjectID(commit) else { throw PinnedCommitFetchError.invalidCommit }
        try runOrThrow(["init", "--quiet", "--", path], in: nil)
        let args = ["-C", path, "fetch", "--quiet", "--no-tags", "--depth", "1", "--", remote, commit]
        let output = try run(args, in: nil, credential: credential)
        if output.exit != 0 {
            // Only git's rejection of this exact object earns the missing-commit message.
            // Do not infer absence from authentication, transport, or arbitrary remote text.
            let missingObjectLines = [
                "fatal: remote error: upload-pack: not our ref \(commit)",
                "fatal: git upload-pack: not our ref \(commit)",
                "fatal: couldn't find remote ref \(commit)"
            ]
            if output.stderr.split(whereSeparator: \.isNewline).contains(where: { missingObjectLines.contains(String($0)) }) {
                throw PinnedCommitFetchError.unavailable
            }
            throw commandError(output, args: args, authenticationRemote: remote)
        }
        try runOrThrow(["-C", path, "checkout", "--quiet", "--detach", "FETCH_HEAD"], in: nil)
    }
}
