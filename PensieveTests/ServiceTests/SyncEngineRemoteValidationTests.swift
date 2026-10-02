import XCTest
@testable import Pensieve

extension SyncEngineTests {
    // MARK: - 10.3: sync-time remote re-validation enforces the SAME allowlist as connect

    /// Every connect-rejected origin form must also be rejected at sync time — before any git op — so a
    /// hand-edited `.git/config` can't ride an unchecked path (C1 defense in depth). Uses the
    /// SHARED `RemoteURLTestVectors.rejected` list so this is gated over the SAME class set as connect
    /// (`RemoteURLPolicyTests`), per the frozen Stage 10.3 acceptance — not just `ext::`.
    func testSyncRejectsEveryTamperedRemoteBeforeAnyGitOp() throws {
        for origin in RemoteURLTestVectors.rejected {
            let git = StubGit()
            git.remote = origin
            XCTAssertThrowsError(try makeEngine(git: git).sync(root: tempDir, message: "m",
                                                              credential: nil, context: makeContext()),
                                 "sync must reject \(origin)") { error in
                guard case SyncError.rejectedRemote = error else {
                    return XCTFail("expected .rejectedRemote for \(origin), got \(error)")
                }
            }
            XCTAssertTrue(git.calls.isEmpty, "no git op for rejected remote: \(origin)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir + "/manifest/manifest.yaml"),
                           "no manifest write for rejected remote: \(origin)")
        }
    }

    func testInspectConflictsRejectsTamperedRemoteBeforeAnyGitOp() throws {
        let git = StubGit()
        git.remote = "ext::sh -c 'touch /tmp/pwn'"
        XCTAssertThrowsError(try makeEngine(git: git).inspectConflicts(root: tempDir, credential: nil,
                                                                       context: makeContext())) { error in
            guard case SyncError.rejectedRemote = error else { return XCTFail("inspect must reject") }
        }
        XCTAssertTrue(git.calls.isEmpty, "inspect: not even abort runs for a rejected remote")
    }

    func testResolveConflictsRejectsTamperedRemoteBeforeAnyGitOp() throws {
        let git = StubGit()
        git.remote = "file:///tmp/x"
        XCTAssertThrowsError(try makeEngine(git: git).resolveConflicts(root: tempDir, picks: [:],
                                                                       credential: nil, context: makeContext())) { error in
            guard case SyncError.rejectedRemote = error else { return XCTFail("resolve must reject") }
        }
        XCTAssertTrue(git.calls.isEmpty, "resolve: no git op for a rejected remote")
    }
}
