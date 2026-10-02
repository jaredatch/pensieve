import XCTest
@testable import Pensieve

extension AppRuntimeStatusOrderTests {
    func testRecoveryAfterPreEngineFailureQueuesOneFollowUp() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let git = IngestRecordingGit(), coordinatorGit = IngestRecordingGit()
        let probe = RuleProbe(), preflights = RuleProbe(), cycles = RuleProbe()
        probe.set { .developerToolsMissing }
        coordinatorGit.remoteRead = {
            _ = preflights.run()
            if preflights.count == 1 { throw IngestPreflightBoom.expected }
            return nil
        }
        let runtime = try await completionRuntime(fixture, git: git, probe: probe,
            label: "pre-engine", coordinatorGit: coordinatorGit) {
            _ = cycles.run()
            return .synced(pushed: false, warnings: [])
        }
        runtime.scheduler.launchIngestCompleted()
        XCTAssertFalse(runtime.scheduler.hasPendingTrigger)
        probe.set { .usable }
        await runtime.syncModel.syncNowAndReport()
        XCTAssertTrue(runtime.scheduler.isSyncing, "recovery after a failed cycle must queue a follow-up")
        await TestWait.until(failureMessage: "recovery follow-up did not finish") {
            !runtime.scheduler.isSyncing && !runtime.syncModel.isCycleInFlight
        }
        XCTAssertEqual(preflights.count, 2, "the failed pre-engine attempt gets exactly one retry")
        XCTAssertEqual(cycles.count, 1, "only the scheduled follow-up reaches the engine")
    }

    func testResolveAvailabilityRefusesConflictWhileCycleRemainsInFlight() async {
        let model = SyncModel()
        model.installSyncRequest {
            model.apply(.conflicted(["skills/example/SKILL.md"]))
            await Task.yield()
            XCTAssertTrue(model.isCycleInFlight)
            XCTAssertTrue(model.isConflicted)
            XCTAssertFalse(model.canStartConflictResolution)
            XCTAssertFalse(model.canResolve, "the banner must not offer a resolution the model refuses")
            XCTAssertEqual(SyncFooterPresentation.make(state: model.state, canResolve: model.canResolve,
                hovering: true, now: Date())?.action, SyncFooterPresentation.Action.none)
        }
        await model.syncNowAndReport()
        XCTAssertTrue(model.canResolve)
        XCTAssertTrue(model.canStartConflictResolution)
        XCTAssertEqual(SyncFooterPresentation.make(state: model.state, canResolve: model.canResolve,
            hovering: true, now: Date())?.action, .resolve)
    }
}
