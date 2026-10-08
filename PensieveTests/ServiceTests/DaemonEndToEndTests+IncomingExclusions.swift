import XCTest
@testable import Pensieve

extension DaemonEndToEndTests {
    @MainActor
    func testIncomingTrackedExcludedFilesPauseDaemonWithAppMessageAndResumeAfterMovingThem() throws {
        for hidden in [false, true] {
            for path in ExcludedFileCollisionFixture.paths {
                let fixture = try ExcludedFileCollisionFixture(path: path, hidden: hidden, localCommit: false)
                defer { try? fixture.files.deleteDirectory(at: fixture.root) }
                let support = fixture.root + "/support"
                let reconciler = CollisionReconciler()
                let daemon = SyncDaemon(root: fixture.storeB, appSupport: support,
                    git: AllowlistedFastForwardGit(wrapping: fixture.git),
                    hasLocalBranches: fixture.git.hasLocalBranches, credentials: InMemoryCredentialStore(),
                    reconciler: reconciler, now: Date.init)
                XCTAssertTrue(fixture.git.isWorktreeClean(at: fixture.storeB), "Excluded additions alone remain clean")
                XCTAssertEqual(daemon.runOnce(), .failed(.preflight(fixture.message)))
                XCTAssertEqual(reconciler.calls, 0)
                let status = try JSONDecoder().decode(DaemonStatus.self,
                    from: fixture.files.readData(at: support + "/daemon-status.json"))
                XCTAssertEqual(status.detail, fixture.message)
                try fixture.assertUntouched()
                try fixture.moveLocalFile()
                XCTAssertEqual(daemon.runOnce(), .synced(changed: true))
                XCTAssertEqual(reconciler.calls, 1)
                try fixture.assertResumed()
            }
        }
    }
}

private final class CollisionReconciler: DeployReconciling {
    var calls = 0
    func reconcile(root: String) -> ReconcileOutcome {
        calls += 1
        return ReconcileOutcome()
    }
}
