import Foundation

/// The narrow git surface the downstream-puller daemon needs (PLAN-12 / 12.6): read the remote, inspect
/// the worktree, and fast-forward. A focused protocol — NOT the full `GitServiceProtocol` — so the daemon
/// injects a small stub in tests and the app's existing `GitServiceProtocol` doubles are untouched
/// (interface segregation; the 12.4 note deferred protocol exposure to here). `GitService` already
/// implements all four (concretely + in the `GitService+FastForward` extension), so the conformance is
/// declaration-only. SwiftData-free — the daemon target compiles it.
protocol FastForwardGitService {
    func probeUsability() throws -> GitUsability
    func remoteURL(at path: String) throws -> String?
    func isWorktreeClean(at path: String) -> Bool
    func fetch(at path: String, credential: GitCredential?) throws
    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult
}

extension GitService: FastForwardGitService {}

extension FastForwardGitService {
    func probeUsability() -> GitUsability { .usable }
}
