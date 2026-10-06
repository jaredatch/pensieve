import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeTests: XCTestCase {
    private final class StubWatcher: FileWatchServiceProtocol {
        var onChange: (String) -> Void = { _ in }
        private(set) var startCount = 0
        private(set) var stopCount = 0

        func start() -> Bool {
            startCount += 1
            return true
        }

        func stop() {
            stopCount += 1
        }
    }

    private struct StubDetection: AgentDetectionServiceProtocol {
        func isInstalled(_ platform: PlatformTarget) -> Bool { false }
        func installedPlatforms() -> [PlatformTarget] { [] }
    }

    private struct NoopDeployReconciler: DeployReconciling {
        func reconcile(root: String) throws -> ReconcileOutcome { ReconcileOutcome() }
    }

    private final class RecordingDeployReconciler: DeployReconciling {
        private(set) var calls = 0

        func reconcile(root: String) throws -> ReconcileOutcome {
            calls += 1
            return ReconcileOutcome()
        }
    }

    private struct NoopLedgerReconciler: CategoryReconcilerProtocol,
        IntentReconcilerProtocol {
        func reconcileRemovingProject(_ projectID: UUID, preservingProjects: Set<UUID>, context: ModelContext) -> BatchResult {
            reconcile(context: context)
        }

        func reconcile(context: ModelContext) -> BatchResult { BatchResult() }
    }

    private final class RecordingLedgerReconciler: CategoryReconcilerProtocol,
        IntentReconcilerProtocol {
        func reconcileRemovingProject(_ projectID: UUID, preservingProjects: Set<UUID>, context: ModelContext) -> BatchResult {
            reconcile(context: context)
        }

        private(set) var calls = 0

        func reconcile(context: ModelContext) -> BatchResult {
            calls += 1
            return BatchResult()
        }
    }

    @MainActor
    private final class WindowModels {
        let library: SkillLibraryViewModel
        let platformVM: PlatformViewModel
        let syncModel: SyncModel

        init(runtime: AppRuntime) {
            library = runtime.library
            platformVM = runtime.platformVM
            syncModel = runtime.syncModel
        }
    }

    private struct RuntimeHarness {
        let runtime: AppRuntime
        let context: ModelContext
        let watcher: StubWatcher
        let launchIngestLockPath: String
        let paths: AppRuntimePaths
    }

    private func makeRuntime(
        defaultsLabel: String = "runtime",
        watcher: StubWatcher = StubWatcher(),
        launchCalls: (() -> Void)? = nil,
        launchBackfill: ((ModelContext) -> Void)? = nil,
        launchOutcome: LaunchReconcileOutcome = LaunchReconcileOutcome(
            rebuild: RebuildResult(),
            migrationRan: false,
            ingestedHeadStamp: "launch"
        ),
        launchRetryOutcome: LaunchReconcileOutcome? = nil,
        hasRemoteConfigured: (() -> Bool)? = nil,
        deployReconciler: DeployReconciling = NoopDeployReconciler(),
        categoryReconciler: CategoryReconcilerProtocol = NoopLedgerReconciler(),
        launchIngestLockPath: String? = nil
    ) throws -> RuntimeHarness {
        let paths = try AppRuntimePaths.temporary(named: "AppRuntimeTests")
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let defaults = try isolatedDefaults(defaultsLabel)
        let library = SkillLibraryViewModel(fileWatchService: watcher)
        let platformVM = PlatformViewModel(agentDetection: StubDetection(), deployStateStore: .memoryBacked)
        var returnedInitialLaunchOutcome = false
        let convergence = PostSyncConvergence(
            root: "/tmp/AppRuntimeTests",
            deployReconciler: deployReconciler,
            contextFactory: { ModelContext(container) },
            categoryReconciler: categoryReconciler,
            intentReconciler: NoopLedgerReconciler(),
            auditLog: { _, _ in }
        )
        let runtime = try AppRuntime(
            container: container,
            platformVM: platformVM,
            library: library,
            defaults: defaults,
            launchReconcile: { _, _ in
                launchCalls?()
                if returnedInitialLaunchOutcome, let launchRetryOutcome {
                    return launchRetryOutcome
                }
                returnedInitialLaunchOutcome = true
                return launchOutcome
            },
            launchBackfill: { launchBackfill?($0) },
            hasRemoteConfigured: hasRemoteConfigured,
            postSyncConvergence: convergence,
            launchIngestRetryNanoseconds: 10_000_000,
            launchIngestLockPath: launchIngestLockPath ?? paths.syncLockPath,
            paths: paths,
            gitUsabilityProbe: { .usable }
        )
        return RuntimeHarness(
            runtime: runtime,
            context: ModelContext(container),
            watcher: watcher,
            launchIngestLockPath: launchIngestLockPath ?? paths.syncLockPath,
            paths: paths
        )
    }

    func testLaunchWorkRunsOnce() throws {
        var launchCallCount = 0
        let harness = try makeRuntime {
            launchCallCount += 1
        }

        XCTAssertTrue(harness.runtime.performLaunchWorkIfNeeded(context: harness.context))
        XCTAssertFalse(harness.runtime.performLaunchWorkIfNeeded(context: harness.context))

        XCTAssertEqual(harness.runtime.launchWorkInvocationCount, 1)
        XCTAssertEqual(launchCallCount, 1)
        XCTAssertEqual(harness.watcher.startCount, 1)
    }

    func testQuarantineSuppressesImportWizardAutoPop() throws {
        XCTAssertTrue(AppRuntime.shouldAutoShowImportWizard(skillCount: 0, storeQuarantined: false, storeUnreadable: false))
        XCTAssertFalse(AppRuntime.shouldAutoShowImportWizard(skillCount: 0, storeQuarantined: true, storeUnreadable: false))
        XCTAssertFalse(AppRuntime.shouldAutoShowImportWizard(skillCount: 1, storeQuarantined: false, storeUnreadable: false))

        let lockPath = NSTemporaryDirectory() + "/AppRuntimeQuarantine-\(UUID().uuidString)/sync.lock"
        let launchLock = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        let harness = try makeRuntime(launchIngestLockPath: lockPath)
        XCTAssertTrue(harness.runtime.performLaunchWorkIfNeeded(context: harness.context))
        XCTAssertTrue(harness.runtime.storeQuarantined)
        XCTAssertFalse(AppRuntime.shouldAutoShowImportWizard(
            skillCount: 0,
            storeQuarantined: harness.runtime.storeQuarantined,
            storeUnreadable: false
        ))
        launchLock.release()

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
        quarantinedHarness.runtime.performLaunchWorkIfNeeded(context: quarantinedHarness.context)
        XCTAssertTrue(quarantinedHarness.runtime.storeQuarantined)
        XCTAssertEqual(backfillCalls, 0)
        XCTAssertEqual(deploy.calls, 0)
    }

    func testSecondWindowAppearanceDoesNotRerunLaunchWork() throws {
        var launchCallCount = 0
        let harness = try makeRuntime {
            launchCallCount += 1
        }

        var firstWindow: WindowModels? = WindowModels(runtime: harness.runtime)
        XCTAssertNotNil(firstWindow)
        harness.runtime.performLaunchWorkIfNeeded(context: harness.context)
        firstWindow = nil

        let secondWindow = WindowModels(runtime: harness.runtime)
        XCTAssertNotNil(secondWindow)
        harness.runtime.performLaunchWorkIfNeeded(context: harness.context)

        XCTAssertEqual(harness.runtime.launchWorkInvocationCount, 1)
        XCTAssertEqual(launchCallCount, 1)
    }

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

    func testWatcherKeepsRunningAfterViewTeardown() throws {
        let harness = try makeRuntime()
        harness.runtime.performLaunchWorkIfNeeded(context: harness.context)

        var window: WindowModels? = WindowModels(runtime: harness.runtime)
        XCTAssertNotNil(window)
        window = nil

        XCTAssertEqual(harness.watcher.startCount, 1)
        XCTAssertEqual(harness.watcher.stopCount, 0)
    }

    func testUnreadableLaunchIngestSkipsConvergence() throws {
        let deploy = RecordingDeployReconciler()
        let harness = try makeRuntime(
            launchOutcome: LaunchReconcileOutcome(
                rebuild: RebuildResult(storeUnreadable: true),
                migrationRan: false
            ),
            deployReconciler: deploy
        )

        harness.runtime.performLaunchWorkIfNeeded(context: harness.context)

        XCTAssertEqual(deploy.calls, 0)
    }

    func testUnstableLaunchIngestSkipsConvergence() throws {
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

        harness.runtime.performLaunchWorkIfNeeded(context: harness.context)

        XCTAssertEqual(deploy.calls, 0)
    }

}

extension AppRuntimeTests {
    func testUnstableLaunchIngestRetriesOutsideSchedulerGate() async throws {
        let deploy = RecordingDeployReconciler()
        var backfillCalls = 0
        let harness = try makeRuntime(
            launchBackfill: { _ in backfillCalls += 1 },
            launchOutcome: LaunchReconcileOutcome(
                rebuild: RebuildResult(),
                migrationRan: false,
                ingestedHeadStamp: nil,
                ingestionNeedsRetry: true
            ),
            launchRetryOutcome: LaunchReconcileOutcome(
                rebuild: RebuildResult(),
                migrationRan: false,
                ingestedHeadStamp: "stable"
            ),
            deployReconciler: deploy
        )

        harness.runtime.performLaunchWorkIfNeeded(context: harness.context)
        XCTAssertEqual(backfillCalls, 0)
        await TestWait.until(failureMessage: "Launch ingest retry never made the scheduler ready") {
            harness.runtime.scheduler.isLaunchIngestReady
        }

        XCTAssertEqual(deploy.calls, 1)
        XCTAssertEqual(backfillCalls, 1)
        XCTAssertTrue(harness.runtime.scheduler.isLaunchIngestReady)
    }

    func testLaunchIngestRetryWaitsForInterleavedLockHolder() async throws {
        let retryRan = expectation(description: "retry ran after lock holder released")
        var launchCalls = 0
        let deploy = RecordingDeployReconciler()
        let lockPath = NSTemporaryDirectory() + "/AppRuntimeRetryLock-\(UUID().uuidString)/sync.lock"
        let harness = try makeRuntime(
            launchCalls: {
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

        harness.runtime.performLaunchWorkIfNeeded(context: harness.context)
        XCTAssertTrue(harness.runtime.storeQuarantined)
        let installLock = try XCTUnwrap(SyncLock.tryAcquire(at: harness.launchIngestLockPath))
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(launchCalls, 1, "an interleaved install must delay the retry rebuild")
        XCTAssertEqual(deploy.calls, 0, "an unvalidated retry outcome must not be accepted")
        installLock.release()
        await fulfillment(of: [retryRan], timeout: 1)

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
