import Foundation

/// The daemon's synchronous, SwiftData-free git surface. Shared operations inherit the same
/// call-site wrapper as the app's protocols; conformers supply explicit public-name witnesses.
protocol FastForwardGitService: GitUsabilityProbing, GitRemoteReading {

    @_disfavoredOverload
    func isWorktreeClean(at path: String) -> Bool
    @_disfavoredOverload
    func fetch(at path: String, credential: GitCredential?) throws
    @_disfavoredOverload
    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult
}

extension GitService: FastForwardGitService {}
