import AppKit
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeTests: XCTestCase {
    func testLaunchWorkRunsOnce() async throws {
        var launchCallCount = 0
        let harness = try makeRuntime {
            launchCallCount += 1
        }
        let launchStartedOnce = await harness.runtime.performLaunchWorkIfNeeded(context: harness.context)
        XCTAssertTrue(launchStartedOnce)
        let launchStartedAgain = await harness.runtime.performLaunchWorkIfNeeded(context: harness.context)
        XCTAssertFalse(launchStartedAgain)
        XCTAssertEqual(harness.runtime.launchWorkInvocationCount, 1)
        XCTAssertEqual(launchCallCount, 1)
        XCTAssertEqual(harness.watcher.startCount, 1)
        XCTAssertFalse(harness.runtime.shouldAutoShowImportWizard(skillCount: 1))
        XCTAssertFalse(harness.runtime.shouldAutoShowImportWizard(skillCount: 0), "the launch question was already answered")
    }

    func testQuarantineSuppressesImportWizardAutoPop() async throws {
        let lockPath = TestTemporaryDirectory.path + "/AppRuntimeQuarantine-\(UUID().uuidString)/sync.lock"
        let launchLock = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        var busyLaunchCalls = 0
        let harness = try makeRuntime(launchCalls: {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertNil(SyncLock.tryAcquire(at: lockPath))
            busyLaunchCalls += 1
        }, launchIngestLockPath: lockPath)
        let launchStartedOnce = await harness.runtime.performLaunchWorkIfNeeded(context: harness.context)
        XCTAssertTrue(launchStartedOnce)
        XCTAssertTrue(harness.runtime.storeQuarantined)
        XCTAssertEqual(busyLaunchCalls, 0, "a held sync.lock must defer launch reconciliation")
        XCTAssertTrue(harness.runtime.library.addsFenced, "lock deferral has not delivered a readable verdict")
        XCTAssertFalse(harness.runtime.shouldAutoShowImportWizard(skillCount: 0))
        launchLock.release()
        await TestWait.until(failureMessage: "deferred launch never retried after sync.lock was released") {
            harness.runtime.launchWorkCompleted
        }
        XCTAssertEqual(busyLaunchCalls, 1)
        XCTAssertFalse(harness.runtime.library.addsFenced, "a readable retry releases the launch fence")
        // Layer-2 P1 regression (PLAN-24 / 24.2): a quarantined outcome must take the deferral arm
        // UNCONDITIONALLY — never launchBackfill or post-ingest convergence, even though the same
        // origin-probe failure makes hasRemoteConfigured read nil (the no-remote arm's condition).
        let deploy = RecordingDeployReconciler()
        var backfillCalls = 0
        let quarantinedHarness = try makeRuntime(defaultsLabel: "quarantined",
            launchBackfill: { _ in backfillCalls += 1 },
            launchOutcome: LaunchReconcileOutcome(
                rebuild: RebuildResult(),
                migrationRan: false,
                ingestedHeadStamp: nil,
                ingestionNeedsRetry: false,
                quarantined: true
            ),
            hasRemoteConfigured: { false },
            deployReconciler: deploy
        )
        await quarantinedHarness.runtime.performLaunchWorkIfNeeded(context: quarantinedHarness.context)
        XCTAssertTrue(quarantinedHarness.runtime.storeQuarantined)
        XCTAssertFalse(quarantinedHarness.runtime.shouldAutoShowImportWizard(skillCount: 0))
        XCTAssertEqual(backfillCalls, 0)
        XCTAssertEqual(deploy.calls, 0)
    }

    func testSecondWindowAppearanceDoesNotRerunLaunchWork() async throws {
        var launchCallCount = 0
        let harness = try makeRuntime {
            launchCallCount += 1
        }
        var firstWindow: WindowModels? = WindowModels(runtime: harness.runtime)
        XCTAssertNotNil(firstWindow)
        await harness.runtime.performLaunchWorkIfNeeded(context: harness.context)
        firstWindow = nil
        let secondWindow = WindowModels(runtime: harness.runtime)
        XCTAssertNotNil(secondWindow)
        await harness.runtime.performLaunchWorkIfNeeded(context: harness.context)

        XCTAssertEqual(harness.runtime.launchWorkInvocationCount, 1)
        XCTAssertEqual(launchCallCount, 1)
    }

    func testWatcherKeepsRunningAfterViewTeardown() async throws {
        let harness = try makeRuntime()
        await harness.runtime.performLaunchWorkIfNeeded(context: harness.context)

        var window: WindowModels? = WindowModels(runtime: harness.runtime)
        XCTAssertNotNil(window)
        window = nil

        XCTAssertEqual(harness.watcher.startCount, 1)
        XCTAssertEqual(harness.watcher.stopCount, 0)
    }

    func testUnreadableLaunchIngestSkipsConvergence() async throws {
        let deploy = RecordingDeployReconciler()
        let harness = try makeRuntime(
            launchOutcome: LaunchReconcileOutcome(
                rebuild: RebuildResult(storeUnreadable: true),
                migrationRan: false
            ),
            deployReconciler: deploy
        )

        await harness.runtime.performLaunchWorkIfNeeded(context: harness.context)

        XCTAssertEqual(deploy.calls, 0)
    }

    func testUnstableLaunchIngestSkipsConvergence() async throws {
        let deploy = RecordingDeployReconciler()
        let harness = try makeRuntime(
            launchOutcome: LaunchReconcileOutcome(
                rebuild: RebuildResult(),
                migrationRan: false,
                ingestedHeadStamp: nil,
                ingestionNeedsRetry: true
            ),
            deployReconciler: deploy
        )

        await harness.runtime.performLaunchWorkIfNeeded(context: harness.context)

        XCTAssertEqual(deploy.calls, 0)
    }

}

extension AppRuntimeTests {
    func testRuntimeModelsSurviveWindowTeardown() throws {
        let harness = try makeRuntime()
        weak var library = harness.runtime.library
        weak var platformVM = harness.runtime.platformVM
        weak var syncModel = harness.runtime.syncModel

        var window: WindowModels? = WindowModels(runtime: harness.runtime)
        XCTAssertNotNil(window)
        window = nil

        XCTAssertTrue(library === harness.runtime.library)
        XCTAssertTrue(platformVM === harness.runtime.platformVM)
        XCTAssertTrue(syncModel === harness.runtime.syncModel)
    }

    func testUnstableLaunchIngestRetriesOutsideSchedulerGate() async throws {
        let deploy = RecordingDeployReconciler()
        var backfillCalls = 0
        let lock = NSLock()
        var migrationArguments: [Bool] = []
        let gate = TestWait.Gate(owner: self)
        defer { gate.open() }
        let entered = expectation(description: "terminal launch retry held")
        let harness = try makeRuntime(
            launchBackfill: { _ in backfillCalls += 1 },
            launchOutcome: LaunchReconcileOutcome(
                rebuild: RebuildResult(),
                migrationRan: false,
                ingestedHeadStamp: nil,
                ingestionNeedsRetry: true
            ),
            launchRetryOutcomes: [
                LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: true, ingestionNeedsRetry: true),
                LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false, ingestedHeadStamp: "stable")
            ],
            launchAttempt: { migrated in
                let attempt = lock.withLock { migrationArguments.append(migrated); return migrationArguments.count }
                if attempt == 3 { entered.fulfill(); try? gate.wait() }
            },
            deployReconciler: deploy
        )

        let window = hostMainWindow(runtime: harness.runtime)
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
        await fulfillment(of: [entered], timeout: TestWait.firstRenderTimeoutSeconds)
        XCTAssertEqual(backfillCalls, 0)
        XCTAssertNil(window.attachedSheet, "wait for the launch verdict")
        gate.open()
        await TestWait.until(failureMessage: "Launch ingest retry never made the scheduler ready") {
            harness.runtime.scheduler.isLaunchIngestReady
        }

        XCTAssertEqual(lock.withLock { migrationArguments }, [false, false, true], "keep a migration from an unfinished retry")
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "a readable retry must present the launch wizard") {
            window.attachedSheet != nil
        }
        XCTAssertFalse(harness.runtime.shouldAutoShowImportWizard(skillCount: 0), "reopening the window must not auto-show again")
        XCTAssertEqual(deploy.calls, 1)
        XCTAssertEqual(backfillCalls, 1)
        XCTAssertTrue(harness.runtime.scheduler.isLaunchIngestReady)
        try await dismissLaunchWizard(in: window)
    }

    func testLaunchIngestRetryWaitsForInterleavedLockHolder() async throws {
        let retryRan = expectation(description: "retry ran after lock holder released")
        var launchCalls = 0
        let deploy = RecordingDeployReconciler()
        let lockPath = TestTemporaryDirectory.path + "/AppRuntimeRetryLock-\(UUID().uuidString)/sync.lock"
        let harness = try makeRuntime(
            launchCalls: {
                XCTAssertFalse(Thread.isMainThread)
                launchCalls += 1
                XCTAssertNil(
                    SyncLock.tryAcquire(at: lockPath),
                    "launch reconcile and acceptance must run under the runtime-owned lock"
                )
                if launchCalls == 2 { retryRan.fulfill() }
            },
            launchOutcome: LaunchReconcileOutcome(
                rebuild: RebuildResult(),
                migrationRan: false,
                ingestionNeedsRetry: true,
                quarantined: true
            ),
            launchRetryOutcome: LaunchReconcileOutcome(
                rebuild: RebuildResult(),
                migrationRan: false,
                ingestedHeadStamp: "stable"
            ),
            deployReconciler: deploy,
            launchIngestLockPath: lockPath
        )

        await harness.runtime.performLaunchWorkIfNeeded(context: harness.context)
        XCTAssertTrue(harness.runtime.storeQuarantined)
        let installLock = try XCTUnwrap(SyncLock.tryAcquire(at: harness.launchIngestLockPath))
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(launchCalls, 1, "an interleaved install must delay the retry rebuild")
        XCTAssertEqual(deploy.calls, 0, "an unvalidated retry outcome must not be accepted")
        installLock.release()
        await fulfillment(of: [retryRan], timeout: TestWait.hostedActionTimeoutSeconds)

        XCTAssertEqual(launchCalls, 2)
        XCTAssertEqual(deploy.calls, 1)
        XCTAssertFalse(harness.runtime.storeQuarantined)
    }

    func testInspectionClearedUpToDateRunsDeployButSkipsLedgerReconcilers() throws {
        let deploy = RecordingDeployReconciler()
        let category = RecordingLedgerReconciler()
        let harness = try makeRuntime(
            deployReconciler: deploy,
            categoryReconciler: category
        )

        try harness.runtime.beginConflictResolution()(.synced(
            pushed: false,
            warnings: [],
            completedAt: Date(),
            headAdvanced: false
        ))

        XCTAssertEqual(deploy.calls, 1)
        XCTAssertEqual(category.calls, 0)
    }

    func testConflictResolutionHeadAdvanceRunsDeployAndLedgerReconcilers() throws {
        let deploy = RecordingDeployReconciler()
        let category = RecordingLedgerReconciler()
        let harness = try makeRuntime(
            deployReconciler: deploy,
            categoryReconciler: category
        )

        try harness.runtime.beginConflictResolution()(.synced(
            pushed: true,
            warnings: [],
            completedAt: Date(),
            headAdvanced: true
        ))

        XCTAssertEqual(deploy.calls, 1)
        XCTAssertEqual(category.calls, 1)
    }
}
