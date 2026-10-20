import XCTest
@testable import Pensieve

/// Public witnesses must dispatch through each consumer protocol, including shared operations.
final class GitProtocolDispatchTests: XCTestCase {
    private func expectCalled<T>(_ expected: String, _ call: @autoclosure () throws -> T,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try call(), file: file, line: line) {
            XCTAssertEqual($0 as? GitDispatchCalled, .operation(expected), file: file, line: line)
        }
    }

    func testGitServiceProtocolDispatchesPublicWitnesses() throws {
        let operations = GitDispatchOperations()
        let service: GitServiceProtocol = operations
        XCTAssertTrue(service.isWorktreeClean(at: "fixture"))
        expectCalled("fastForwardOnly(at,credential)", try service.fastForwardOnly(at: "fixture", credential: .sshAgent))
        expectCalled("manifestMatchesHead(at)", try service.manifestMatchesHead(at: "fixture"))
        expectCalled("probeUsability()", try service.probeUsability())
        expectCalled("remoteURL(at)", try service.remoteURL(at: "fixture"))
        expectCalled("initRepository(at)", try service.initRepository(at: "fixture"))
        expectCalled("setRemote(_,at)", try service.setRemote("fixture", at: "fixture"))
        expectCalled("removeRemote(at)", try service.removeRemote(at: "fixture"))
        expectCalled("configuredRemoteURL(at)", try service.configuredRemoteURL(at: "fixture"))
        expectCalled("clone(remote,into,credential)",
            try service.clone(remote: "fixture", into: "fixture", credential: .sshAgent))
        XCTAssertTrue(service.remoteHasCommits(remote: "fixture", credential: .sshAgent))
        expectCalled("remoteReferences(remote,credential)",
            try service.remoteReferences(remote: "fixture", credential: .sshAgent))
        expectCalled("checkoutUnbornBranch(_,at)", try service.checkoutUnbornBranch("fixture", at: "fixture"))
        expectCalled("fetchBranch(_,at,credential)", try service.fetchBranch("fixture", at: "fixture", credential: .sshAgent))
        expectCalled("materializeFromFetchHead(at)", try service.materializeFromFetchHead(at: "fixture"))
        expectCalled("bornBranch(_,at)", try service.bornBranch("fixture", at: "fixture"))
        expectCalled("setUpstream(branch,at)", try service.setUpstream(branch: "fixture", at: "fixture"))
        expectCalled("hasLocalBranches(at)", try service.hasLocalBranches(at: "fixture"))
        XCTAssertTrue(service.hasRemoteTrackingBranch("fixture", at: "fixture"))
        expectCalled("hasRemoteOriginConfigured(at)", try service.hasRemoteOriginConfigured(at: "fixture"))
        expectCalled("stageAllAndCommit(at,message)", try service.stageAllAndCommit(at: "fixture", message: "fixture"))
        XCTAssertEqual(operations.calls, [
            "isWorktreeClean(at)", "fastForwardOnly(at,credential)", "manifestMatchesHead(at)",
            "probeUsability()",
            "remoteURL(at)",
            "initRepository(at)",
            "setRemote(_,at)",
            "removeRemote(at)",
            "configuredRemoteURL(at)",
            "clone(remote,into,credential)",
            "remoteHasCommits(remote,credential)",
            "remoteReferences(remote,credential)",
            "checkoutUnbornBranch(_,at)",
            "fetchBranch(_,at,credential)",
            "materializeFromFetchHead(at)",
            "bornBranch(_,at)",
            "setUpstream(branch,at)",
            "hasLocalBranches(at)",
            "hasRemoteTrackingBranch(_,at)",
            "hasRemoteOriginConfigured(at)",
            "stageAllAndCommit(at,message)"
        ])
    }

    private func assertRefusedFolderForwarding() {
        let forwarded = GitDispatchOperations()
        let wrapper: GitServiceProtocol = AllowlistedRemoteGit(wrapping: forwarded)
        expectCalled("abortRebase(at,refusedFolder)", try wrapper.abortRebase(at: "fixture", refusedFolder: "folder"))
        XCTAssertEqual(forwarded.calls, ["abortRebase(at,refusedFolder)"])
    }

    private func assertLocalCommitDispatch(_ service: GitServiceProtocol) {
        XCTAssertFalse(service.hasUncommittedChanges(at: "fixture"))
        let expected = GitTreeExpectation(files: [:], deletablePaths: [], deletablePrefixes: [], ignoredPrefixes: [])
        expectCalled("localCommitMatches(_,from,to,at)",
            try service.localCommitMatches(expected, from: "parent", to: "head", at: "fixture"))
    }

    func testGitServiceProtocolDispatchesConflictAndHistoryWitnesses() throws {
        assertRefusedFolderForwarding()
        let operations = GitDispatchOperations()
        let service: GitServiceProtocol = operations
        assertLocalCommitDispatch(service)
        let entry = ConflictEntry(mode: "100644", objectID: "object", bytes: Data())
        expectCalled("preflightStoreUpdate(at,credential)",
            try service.preflightStoreUpdate(at: "fixture", credential: .sshAgent))
        expectCalled("pullRebase(at,credential)", try service.pullRebase(at: "fixture", credential: .sshAgent))
        expectCalled("pullRebase(at,fetchedRevision)",
            try service.pullRebase(at: "fixture", fetchedRevision: .init(commit: "fetched")))
        expectCalled("push(at,credential)", try service.push(at: "fixture", credential: .sshAgent))
        expectCalled("abortRebase(at)", try service.abortRebase(at: "fixture"))
        expectCalled("abortRebase(at,refusedFolder)", try service.abortRebase(at: "fixture", refusedFolder: "folder"))
        expectCalled("conflictedFiles(at)", try service.conflictedFiles(at: "fixture"))
        expectCalled("blob(atStage,path,in)", try service.blob(atStage: 1, path: "fixture", in: "fixture"))
        expectCalled("conflictEntry(atStage,path,in)", try service.conflictEntry(atStage: 1, path: "fixture", in: "fixture"))
        expectCalled("restoreConflictEntry(_,stage,path,at)",
            try service.restoreConflictEntry(entry, stage: 1, path: "fixture", at: "fixture"))
        expectCalled("retireConflictPath(_,at)", try service.retireConflictPath("fixture", at: "fixture"))
        expectCalled("removeConflictEntryFromIndex(_,at)", try service.removeConflictEntryFromIndex("fixture", at: "fixture"))
        expectCalled("continueRebase(at)", try service.continueRebase(at: "fixture"))
        expectCalled("skipRebase(at)", try service.skipRebase(at: "fixture"))
        expectCalled("stagePath(_,at)", try service.stagePath("fixture", at: "fixture"))
        expectCalled("collapseToSingleCommit(at,message,credential,fetchedRevision)",
            try service.collapseToSingleCommit(at: "fixture", message: "fixture", credential: .sshAgent, fetchedRevision: nil))
        expectCalled("hasCommitsToPush(at)", try service.hasCommitsToPush(at: "fixture"))
        _ = service.log(forPath: "fixture", at: "fixture", limit: 1)
        XCTAssertEqual(service.show(sha: "fixture", path: "fixture", at: "fixture"), "selected version")
        XCTAssertEqual(operations.calls, [
            "hasUncommittedChanges(at)", "localCommitMatches(_,from,to,at)", "preflightStoreUpdate(at,credential)",
            "pullRebase(at,credential)",
            "pullRebase(at,fetchedRevision)",
            "push(at,credential)",
            "abortRebase(at)",
            "abortRebase(at,refusedFolder)",
            "conflictedFiles(at)",
            "blob(atStage,path,in)",
            "conflictEntry(atStage,path,in)",
            "restoreConflictEntry(_,stage,path,at)",
            "retireConflictPath(_,at)",
            "removeConflictEntryFromIndex(_,at)",
            "continueRebase(at)",
            "skipRebase(at)",
            "stagePath(_,at)",
            "collapseToSingleCommit(at,message,credential,fetchedRevision)",
            "hasCommitsToPush(at)",
            "log(forPath,at,limit)",
            "show(sha,path,at)"
        ])
    }

    func testFastForwardGitServiceDispatchesPublicWitnesses() throws {
        let operations = GitDispatchOperations()
        let service: FastForwardGitService = operations
        expectCalled("probeUsability()", try service.probeUsability())
        expectCalled("remoteURL(at)", try service.remoteURL(at: "fixture"))
        expectCalled("fetch(at,credential)", try service.fetch(at: "fixture", credential: .sshAgent))
        expectCalled("fastForwardOnly(at,credential)", try service.fastForwardOnly(at: "fixture", credential: .sshAgent))
        XCTAssertEqual(operations.calls, [
            "probeUsability()",
            "remoteURL(at)",
            "fetch(at,credential)",
            "fastForwardOnly(at,credential)"
        ])
    }

    func testSkillInstallGitServingDispatchesPublicWitnesses() throws {
        let operations = GitDispatchOperations()
        let service: SkillInstallGitServing = operations
        expectCalled("cloneShallow(remote,branch,into,credential)",
            try service.cloneShallow(remote: "fixture", branch: "main", into: "fixture", credential: .sshAgent))
        expectCalled("commitSHA(at)", try service.commitSHA(at: "fixture"))
        expectCalled("treeHash(at,path)", try service.treeHash(at: "fixture", path: "fixture"))
        expectCalled("currentBranch(at)", try service.currentBranch(at: "fixture"))
        XCTAssertEqual(operations.calls, [
            "cloneShallow(remote,branch,into,credential)",
            "commitSHA(at)",
            "treeHash(at,path)",
            "currentBranch(at)"
        ])
    }

    func testUpdateCheckGitServingDispatchesPublicWitnesses() throws {
        let operations = GitDispatchOperations()
        let service: UpdateCheckGitServing = operations
        expectCalled("probeUsability()", try service.probeUsability())
        expectCalled("cloneShallow(remote,branch,into,credential)",
            try service.cloneShallow(remote: "fixture", branch: "main", into: "fixture", credential: .sshAgent))
        expectCalled("commitSHA(at)", try service.commitSHA(at: "fixture"))
        expectCalled("treeHash(at,path)", try service.treeHash(at: "fixture", path: "fixture"))
        expectCalled("remoteHead(remote,ref,credential)",
            try service.remoteHead(remote: "fixture", ref: "fixture", credential: .sshAgent))
        expectCalled("commitDate(at)", try service.commitDate(at: "fixture"))
        XCTAssertEqual(operations.calls, [
            "probeUsability()",
            "cloneShallow(remote,branch,into,credential)",
            "commitSHA(at)",
            "treeHash(at,path)",
            "remoteHead(remote,ref,credential)",
            "commitDate(at)"
        ])
    }

    func testUpstreamHistoryGitServingDispatchesPublicWitnesses() throws {
        let operations = GitDispatchOperations()
        let service: UpstreamHistoryGitServing = operations
        let request = UpstreamHistoryGitRequest(remote: "remote", ref: "main", installedCommit: "commit",
            path: "skill", repositoryPath: "scratch", commitLimit: 1, rowLimit: 1, textByteLimit: 1,
            baselineFileLimit: 1, baselineByteLimit: 1, credential: nil)
        expectCalled("remoteHead(remote,ref,credential)",
            try service.remoteHead(remote: "fixture", ref: "fixture", credential: .sshAgent))
        expectCalled("upstreamHistory(_)", try service.upstreamHistory(request))
        XCTAssertEqual(operations.calls, [
            "remoteHead(remote,ref,credential)",
            "upstreamHistory(_)"
        ])
    }

}
