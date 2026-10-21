import Foundation
@testable import Pensieve

enum GitDispatchCalled: Error, Equatable { case operation(String) }

final class GitDispatchOperations: GitServiceProtocol, FastForwardGitService,
                                SkillInstallGitServing, UpdateCheckGitServing, UpstreamHistoryGitServing {
    var calls: [String] = []
    func manifestMatchesHead(at path: String) throws -> Bool {
        calls.append("manifestMatchesHead(at)")
        throw GitDispatchCalled.operation("manifestMatchesHead(at)")
    }

    func hasUncommittedChanges(at path: String) -> Bool {
        calls.append("hasUncommittedChanges(at)")
        return false
    }

    func localCommitMatches(_ expected: GitTreeExpectation, from parent: String, to head: String,
                            at root: String) throws -> Bool {
        calls.append("localCommitMatches(_,from,to,at)")
        throw GitDispatchCalled.operation("localCommitMatches(_,from,to,at)")
    }

    func probeUsability() throws -> GitUsability {
        calls.append("probeUsability()")
        throw GitDispatchCalled.operation("probeUsability()")
    }

    func remoteURL(at path: String) throws -> String? {
        calls.append("remoteURL(at)")
        throw GitDispatchCalled.operation("remoteURL(at)")
    }

    func initRepository(at path: String) throws {
        calls.append("initRepository(at)")
        throw GitDispatchCalled.operation("initRepository(at)")
    }

    func setRemote(_ url: String, at path: String) throws {
        calls.append("setRemote(_,at)")
        throw GitDispatchCalled.operation("setRemote(_,at)")
    }

    func removeRemote(at path: String) throws {
        calls.append("removeRemote(at)")
        throw GitDispatchCalled.operation("removeRemote(at)")
    }

    func configuredRemoteURL(at path: String) throws -> String? {
        calls.append("configuredRemoteURL(at)")
        throw GitDispatchCalled.operation("configuredRemoteURL(at)")
    }

    func clone(remote: String, into path: String, credential: GitCredential?) throws {
        calls.append("clone(remote,into,credential)")
        throw GitDispatchCalled.operation("clone(remote,into,credential)")
    }

    func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool {
        calls.append("remoteHasCommits(remote,credential)")
        return true
    }

    func remoteReferences(remote: String, credential: GitCredential?) throws -> GitRemoteReferences {
        calls.append("remoteReferences(remote,credential)")
        throw GitDispatchCalled.operation("remoteReferences(remote,credential)")
    }

    func checkoutUnbornBranch(_ branch: String, at path: String) throws {
        calls.append("checkoutUnbornBranch(_,at)")
        throw GitDispatchCalled.operation("checkoutUnbornBranch(_,at)")
    }

    func fetchBranch(_ branch: String, at path: String, credential: GitCredential?) throws {
        calls.append("fetchBranch(_,at,credential)")
        throw GitDispatchCalled.operation("fetchBranch(_,at,credential)")
    }

    func materializeFromFetchHead(at path: String) throws {
        calls.append("materializeFromFetchHead(at)")
        throw GitDispatchCalled.operation("materializeFromFetchHead(at)")
    }

    func bornBranch(_ branch: String, at path: String) throws {
        calls.append("bornBranch(_,at)")
        throw GitDispatchCalled.operation("bornBranch(_,at)")
    }

    func setUpstream(branch: String, at path: String) throws {
        calls.append("setUpstream(branch,at)")
        throw GitDispatchCalled.operation("setUpstream(branch,at)")
    }

    func hasLocalBranches(at path: String) throws -> Bool {
        calls.append("hasLocalBranches(at)")
        throw GitDispatchCalled.operation("hasLocalBranches(at)")
    }

    func hasRemoteTrackingBranch(_ branch: String, at path: String) -> Bool {
        calls.append("hasRemoteTrackingBranch(_,at)")
        return true
    }

    func hasRemoteOriginConfigured(at path: String) throws -> Bool {
        calls.append("hasRemoteOriginConfigured(at)")
        throw GitDispatchCalled.operation("hasRemoteOriginConfigured(at)")
    }

    func stageAllAndCommit(at path: String, message: String) throws -> Bool {
        calls.append("stageAllAndCommit(at,message)")
        throw GitDispatchCalled.operation("stageAllAndCommit(at,message)")
    }

    func preflightStoreUpdate(at path: String, credential: GitCredential?) throws -> FetchedStoreRevision? {
        calls.append("preflightStoreUpdate(at,credential)")
        throw GitDispatchCalled.operation("preflightStoreUpdate(at,credential)")
    }

    func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult {
        calls.append("pullRebase(at,credential)")
        throw GitDispatchCalled.operation("pullRebase(at,credential)")
    }

    func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
        calls.append("pullRebase(at,fetchedRevision)")
        throw GitDispatchCalled.operation("pullRebase(at,fetchedRevision)")
    }

    func push(at path: String, credential: GitCredential?) throws {
        calls.append("push(at,credential)")
        throw GitDispatchCalled.operation("push(at,credential)")
    }

    func abortRebase(at path: String, refusedFolder: String) throws {
        calls.append("abortRebase(at,refusedFolder)")
        throw GitDispatchCalled.operation("abortRebase(at,refusedFolder)")
    }
    func abortRebase(at path: String) throws {
        calls.append("abortRebase(at)")
        throw GitDispatchCalled.operation("abortRebase(at)")
    }

    func conflictedFiles(at path: String) throws -> [String] {
        calls.append("conflictedFiles(at)")
        throw GitDispatchCalled.operation("conflictedFiles(at)")
    }

    func blob(atStage stage: Int, path: String, in workingDir: String) throws -> Data? {
        calls.append("blob(atStage,path,in)")
        throw GitDispatchCalled.operation("blob(atStage,path,in)")
    }

    func conflictEntry(atStage stage: Int, path: String, in workingDir: String) throws -> ConflictEntry? {
        calls.append("conflictEntry(atStage,path,in)")
        throw GitDispatchCalled.operation("conflictEntry(atStage,path,in)")
    }

    func restoreConflictEntry(_ entry: ConflictEntry, stage: Int, path: String, at root: String) throws {
        calls.append("restoreConflictEntry(_,stage,path,at)")
        throw GitDispatchCalled.operation("restoreConflictEntry(_,stage,path,at)")
    }

    func retireConflictPath(_ path: String, at root: String) throws {
        calls.append("retireConflictPath(_,at)")
        throw GitDispatchCalled.operation("retireConflictPath(_,at)")
    }

    func removeConflictEntryFromIndex(_ path: String, at root: String) throws {
        calls.append("removeConflictEntryFromIndex(_,at)")
        throw GitDispatchCalled.operation("removeConflictEntryFromIndex(_,at)")
    }

    func continueRebase(at path: String) throws -> PullResult {
        calls.append("continueRebase(at)")
        throw GitDispatchCalled.operation("continueRebase(at)")
    }

    func skipRebase(at path: String) throws -> PullResult {
        calls.append("skipRebase(at)")
        throw GitDispatchCalled.operation("skipRebase(at)")
    }

    func stagePath(_ path: String, at root: String) throws {
        calls.append("stagePath(_,at)")
        throw GitDispatchCalled.operation("stagePath(_,at)")
    }

    func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                fetchedRevision: FetchedStoreRevision?) throws -> Bool {
        calls.append("collapseToSingleCommit(at,message,credential,fetchedRevision)")
        throw GitDispatchCalled.operation("collapseToSingleCommit(at,message,credential,fetchedRevision)")
    }

    func hasCommitsToPush(at path: String) throws -> Bool {
        calls.append("hasCommitsToPush(at)")
        throw GitDispatchCalled.operation("hasCommitsToPush(at)")
    }

    func log(forPath path: String, at workingDir: String, limit: Int) -> [GitCommit] {
        calls.append("log(forPath,at,limit)")
        return []
    }

    func show(sha: String, path: String, at workingDir: String) -> String? {
        calls.append("show(sha,path,at)")
        return "selected version"
    }

    func isWorktreeClean(at path: String) -> Bool {
        calls.append("isWorktreeClean(at)")
        return true
    }

    func fetch(at path: String, credential: GitCredential?) throws {
        calls.append("fetch(at,credential)")
        throw GitDispatchCalled.operation("fetch(at,credential)")
    }

    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult {
        calls.append("fastForwardOnly(at,credential)")
        throw GitDispatchCalled.operation("fastForwardOnly(at,credential)")
    }

    func cloneShallow(remote: String, branch: String?, into path: String, credential: GitCredential?) throws {
        calls.append("cloneShallow(remote,branch,into,credential)")
        throw GitDispatchCalled.operation("cloneShallow(remote,branch,into,credential)")
    }

    func commitSHA(at path: String) throws -> String {
        calls.append("commitSHA(at)")
        throw GitDispatchCalled.operation("commitSHA(at)")
    }

    func treeHash(at repositoryPath: String, path: String) throws -> String {
        calls.append("treeHash(at,path)")
        throw GitDispatchCalled.operation("treeHash(at,path)")
    }

    func currentBranch(at path: String) throws -> String {
        calls.append("currentBranch(at)")
        throw GitDispatchCalled.operation("currentBranch(at)")
    }

    func remoteHead(remote: String, ref: String, credential: GitCredential?) throws -> String? {
        calls.append("remoteHead(remote,ref,credential)")
        throw GitDispatchCalled.operation("remoteHead(remote,ref,credential)")
    }

    func commitDate(at repositoryPath: String) throws -> Date {
        calls.append("commitDate(at)")
        throw GitDispatchCalled.operation("commitDate(at)")
    }

    func upstreamHistory(_ request: UpstreamHistoryGitRequest) throws -> UpstreamHistoryGitSnapshot {
        calls.append("upstreamHistory(_)")
        throw GitDispatchCalled.operation("upstreamHistory(_)")
    }

}
