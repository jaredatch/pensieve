import Foundation

/// The app and daemon share one call-site wrapper and explicit witnesses for safe fast-forwarding.
protocol GitFastForwarding {
    @_disfavoredOverload
    func isWorktreeClean(at path: String) -> Bool
    @_disfavoredOverload
    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult
}

/// The daemon's synchronous, SwiftData-free git surface.
protocol FastForwardGitService: GitUsabilityProbing, GitRemoteReading, GitFastForwarding {
    @_disfavoredOverload
    func fetch(at path: String, credential: GitCredential?) throws
}

extension GitService: FastForwardGitService {}
