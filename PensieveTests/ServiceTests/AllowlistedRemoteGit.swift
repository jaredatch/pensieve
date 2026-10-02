import Foundation
@testable import Pensieve

/// Test double: wraps a real `GitServiceProtocol` but reports an ACCEPTED `remoteURL`, so a `SyncEngine`
/// under test — whose sync-time guard rejects `file://` (PLAN-10 / 10.3) — still runs over `file://`
/// local clones. The real `file://` origin still drives every actual clone/pull/push because
/// `GitService.pullRebase`/`push` run `git … origin main` (git resolves the URL from `.git/config`);
/// `remoteURL(at:)` feeds only the guard + error strings. (PLAN-10 / 10.3 — file:// test reconciliation.)
final class AllowlistedRemoteGit: GitServiceProtocol {
    private let wrapped: GitServiceProtocol
    private let acceptedRemote: String

    init(wrapping wrapped: GitServiceProtocol, acceptedRemote: String = "https://fixture.test/x.git") {
        self.wrapped = wrapped
        self.acceptedRemote = acceptedRemote
    }

    func probeUsability() -> GitUsability { wrapped.probeUsability() }

    /// The ONLY override: report an accepted URL when the wrapped service has an origin (preserving the
    /// `.noRemote` path when it does not).
    func remoteURL(at path: String) throws -> String? {
        try wrapped.remoteURL(at: path) == nil ? nil : acceptedRemote
    }

    func initRepository(at path: String) throws { try wrapped.initRepository(at: path) }
    func setRemote(_ url: String, at path: String) throws { try wrapped.setRemote(url, at: path) }
    func removeRemote(at path: String) throws {}
    func configuredRemoteURL(at path: String) throws -> String? { nil }
    func clone(remote: String, into path: String, credential: GitCredential?) throws {
        try wrapped.clone(remote: remote, into: path, credential: credential)
    }
    func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool {
        wrapped.remoteHasCommits(remote: remote, credential: credential)
    }
    @discardableResult
    func stageAllAndCommit(at path: String, message: String) throws -> Bool {
        try wrapped.stageAllAndCommit(at: path, message: message)
    }
    func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult {
        try wrapped.pullRebase(at: path, credential: credential)
    }
    func push(at path: String, credential: GitCredential?) throws {
        try wrapped.push(at: path, credential: credential)
    }
    func abortRebase(at path: String) throws { try wrapped.abortRebase(at: path) }
    func conflictedFiles(at path: String) throws -> [String] { try wrapped.conflictedFiles(at: path) }
    func blob(atStage stage: Int, path: String, in workingDir: String) throws -> String? {
        try wrapped.blob(atStage: stage, path: path, in: workingDir)
    }
    func continueRebase(at path: String) throws -> PullResult { try wrapped.continueRebase(at: path) }
    func skipRebase(at path: String) throws -> PullResult { try wrapped.skipRebase(at: path) }
    func stagePath(_ path: String, at root: String) throws { try wrapped.stagePath(path, at: root) }
    func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?) throws -> Bool {
        try wrapped.collapseToSingleCommit(at: root, message: message, credential: credential)
    }
    func hasCommitsToPush(at path: String) throws -> Bool { try wrapped.hasCommitsToPush(at: path) }
    func log(forPath path: String, at workingDir: String, limit: Int) -> [GitCommit] {
        wrapped.log(forPath: path, at: workingDir, limit: limit)
    }
    func show(sha: String, path: String, at workingDir: String) -> String? {
        wrapped.show(sha: sha, path: path, at: workingDir)
    }
}
