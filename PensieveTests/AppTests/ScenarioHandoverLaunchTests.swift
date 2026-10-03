import SwiftData
import XCTest
@testable import Pensieve

@MainActor
private final class HandoverConvergence: PostSyncConverging {
    var calls = 0
    var onLaunch: () -> Void = {}
    func run(after result: SyncCycleResult) {}
    func runAfterLaunchIngest() { calls += 1; onLaunch() }
}

private final class HandoverWatcher: FileWatchServiceProtocol {
    var onChange: (String) -> Void = { _ in }
    func start() -> Bool { true }
    func stop() {}
}

@MainActor
final class ScenarioHandoverLaunchTests: XCTestCase {
    func testRuntimeDefersRealHandoverUntilLaunchLockRetryThenConverges() async throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed()
        let before = try harness.deployedFiles()
        let paths = AppRuntimePaths(storeRoot: harness.root, appSupportDir: harness.root + "/support")
        try harness.files.createDirectory(at: paths.appSupportDir)
        try harness.files.writeFile(at: paths.appSupportDir + "/machine-id", content: harness.identity.id + "\n")
        harness.defaults.set(true, forKey: AppRuntime.migrationDefaultsKey)
        harness.defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        let convergence = HandoverConvergence()
        convergence.onLaunch = {
            XCTAssertNil(SyncLock.tryAcquire(at: paths.syncLockPath), "handover and convergence must hold the launch lock")
            do { try harness.assertComplete() } catch { XCTFail("handover did not complete: \(error)") }
        }
        let runtime = try AppRuntime(
            container: harness.container, library: library(harness), defaults: harness.defaults,
            launchBackfill: { _ in }, hasRemoteConfigured: { false }, postSyncConvergence: convergence,
            launchIngestRetryNanoseconds: 10_000_000, paths: paths, gitUsabilityProbe: { .usable }
        )
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: paths.syncLockPath))
        defer { lock.release() }
        runtime.performLaunchWorkIfNeeded(context: harness.freshContext())
        XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 2)
        XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
        XCTAssertEqual(convergence.calls, 0)
        // Give the retry an opportunity while the competing owner still holds the lock.
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
        XCTAssertEqual(convergence.calls, 0)
        lock.release()
        await TestWait.until(failureMessage: "deferred handover did not finish") { convergence.calls == 1 }
        try harness.assertComplete()
        XCTAssertEqual(try harness.deployedFiles(), before)
        XCTAssertFalse(runtime.performLaunchWorkIfNeeded(context: harness.freshContext()))
        XCTAssertEqual(convergence.calls, 1)
    }

    func testRuntimeSkipsConvergenceOnHandoverFailureAndRetriesItFirst() async throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed()
        let before = try harness.deployedFiles()
        let paths = AppRuntimePaths(storeRoot: harness.root, appSupportDir: harness.root + "/support")
        harness.defaults.set(true, forKey: AppRuntime.migrationDefaultsKey)
        harness.defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        let convergence = HandoverConvergence()
        var attempts = 0
        let runtime = try AppRuntime(
            container: harness.container, library: library(harness), defaults: harness.defaults,
            launchReconcile: { context, migrated in
                attempts += 1
                XCTAssertTrue(migrated)
                XCTAssertNil(SyncLock.tryAcquire(at: paths.syncLockPath))
                return LaunchReconciler(
                    fileService: harness.files, manifestService: harness.manifest, root: harness.root,
                    lockPath: paths.syncLockPath, scenarioHandover: harness.handover()
                ).reconcileOnLaunch(context: context, alreadyMigrated: migrated, externallyHeldLock: true)
            },
            launchBackfill: { _ in }, hasRemoteConfigured: { false }, postSyncConvergence: convergence,
            launchIngestRetryNanoseconds: 10_000_000, paths: paths, gitUsabilityProbe: { .usable }
        )
        harness.manifest.failWrite = 1
        runtime.performLaunchWorkIfNeeded(context: harness.freshContext())
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(convergence.calls, 0)
        XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
        XCTAssertEqual(try harness.deployedFiles(), before)
        harness.manifest.failWrite = nil
        await TestWait.until(failureMessage: "handover failure did not retry") { convergence.calls == 1 }
        XCTAssertEqual(attempts, 2)
        try harness.assertComplete()
        XCTAssertEqual(try harness.deployedFiles(), before)
    }

    private func library(_ harness: HandoverHarness) -> SkillLibraryViewModel {
        SkillLibraryViewModel(
            skillStore: SkillStore(fileService: harness.files, baseDir: harness.root + "/skills"),
            fileService: harness.files, fileWatchService: HandoverWatcher(),
            manifestService: harness.manifest.live, manifestRoot: harness.root
        )
    }
}
