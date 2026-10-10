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

    func performProbeUsability() throws -> GitUsability { try wrapped.probeUsability() }

    /// The ONLY override: report an accepted URL when the wrapped service has an origin (preserving the
    /// `.noRemote` path when it does not).
    func performRemoteURL(at path: String) throws -> String? {
        try wrapped.remoteURL(at: path) == nil ? nil : acceptedRemote
    }

    func performInitRepository(at path: String) throws { try wrapped.initRepository(at: path) }
    func performSetRemote(_ url: String, at path: String) throws { try wrapped.setRemote(url, at: path) }
    func performRemoveRemote(at path: String) throws {}
    func performConfiguredRemoteURL(at path: String) throws -> String? { nil }
    func performClone(remote: String, into path: String, credential: GitCredential?) throws {
        try wrapped.clone(remote: remote, into: path, credential: credential)
    }
    func performRemoteHasCommits(remote: String, credential: GitCredential?) -> Bool {
        wrapped.remoteHasCommits(remote: remote, credential: credential)
    }
    @discardableResult
    func performStageAllAndCommit(at path: String, message: String) throws -> Bool {
        try wrapped.stageAllAndCommit(at: path, message: message)
    }
    func performPullRebase(at path: String, credential: GitCredential?) throws -> PullResult {
        try wrapped.pullRebase(at: path, credential: credential)
    }
    func performPreflightStoreUpdate(at path: String, credential: GitCredential?) throws -> FetchedStoreRevision? {
        try wrapped.preflightStoreUpdate(at: path, credential: credential)
    }
    func performPullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
        try wrapped.pullRebase(at: path, fetchedRevision: fetchedRevision)
    }
    func performPush(at path: String, credential: GitCredential?) throws {
        try wrapped.push(at: path, credential: credential)
    }
    func performAbortRebase(at path: String) throws { try wrapped.abortRebase(at: path) }
    func performConflictedFiles(at path: String) throws -> [String] { try wrapped.conflictedFiles(at: path) }
    func performBlob(atStage stage: Int, path: String, in workingDir: String) throws -> Data? {
        try wrapped.blob(atStage: stage, path: path, in: workingDir)
    }
    func performConflictEntry(atStage stage: Int, path: String, in workingDir: String) throws -> ConflictEntry? {
        try wrapped.conflictEntry(atStage: stage, path: path, in: workingDir)
    }
    func performRestoreConflictEntry(_ entry: ConflictEntry, stage: Int, path: String, at root: String) throws {
        try wrapped.restoreConflictEntry(entry, stage: stage, path: path, at: root)
    }
    func performRetireConflictPath(_ path: String, at root: String) throws { try wrapped.retireConflictPath(path, at: root) }
    func performRemoveConflictEntryFromIndex(_ path: String, at root: String) throws {
        try wrapped.removeConflictEntryFromIndex(path, at: root)
    }
    func performContinueRebase(at path: String) throws -> PullResult { try wrapped.continueRebase(at: path) }
    func performSkipRebase(at path: String) throws -> PullResult { try wrapped.skipRebase(at: path) }
    func performStagePath(_ path: String, at root: String) throws { try wrapped.stagePath(path, at: root) }
    func performCollapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                       fetchedRevision: FetchedStoreRevision?) throws -> Bool {
        try wrapped.collapseToSingleCommit(at: root, message: message, credential: credential, fetchedRevision: fetchedRevision)
    }
    func performHasCommitsToPush(at path: String) throws -> Bool { try wrapped.hasCommitsToPush(at: path) }
    func performLog(forPath path: String, at workingDir: String, limit: Int) -> [GitCommit] {
        wrapped.log(forPath: path, at: workingDir, limit: limit)
    }
    func performShow(sha: String, path: String, at workingDir: String) -> String? {
        wrapped.show(sha: sha, path: path, at: workingDir)
    }
}
