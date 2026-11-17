import Foundation

enum PinnedCommitFetchError: Error {
    case invalidCommit
    case unavailable
}

extension GitService {
    /// Fetch the tip's complete commit graph, without checking out files or fetching the saved pin.
    /// A successful fetch can still be empty when the server itself has only shallow history.
    @_disfavoredOverload
    func pinnedCommitIsReachable(_ commit: String, from tip: String, remote: String,
                                 into path: String, credential: GitCredential?) throws -> Bool? {
        guard Self.isHistoryObjectID(commit), Self.isHistoryObjectID(tip) else {
            throw PinnedCommitFetchError.invalidCommit
        }
        try runOrThrow(["init", "--bare", "--quiet", "--", path], in: nil, environment: Self.historyEnvironment)
        let args = ["-C", path, "fetch", "--quiet", "--no-tags", "--update-shallow", "--filter=tree:0",
                    "--recurse-submodules=no",
                    "--", remote, tip]
        let output = try runUpstreamHistoryNetwork(args, credential: credential)
        guard output.exit == 0 else {
            throw commandError(output, args: args, authenticationRemote: remote)
        }
        // Accept the server's shallow roots so a cut graph stays visibly shallow locally.
        guard try objectExists(tip + "^{commit}", at: path),
              try !isShallowRepository(at: path) else { return nil }
        // Missing in this complete graph means withdrawn; asking merge-base would throw for it.
        guard try objectExists(commit + "^{commit}", at: path) else { return false }
        return try isAncestor(commit, of: tip, at: path)
    }

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
