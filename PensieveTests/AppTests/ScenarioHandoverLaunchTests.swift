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

    func testRuntimeCompletesIngestAndConvergesDespitePersistentHandoverFailure() async throws {
        try await assertPersistentFailureAllowsLaunch(migrationWarning: false)
    }

    func testRuntimeCompletesIngestAndConvergesDespitePersistentMigrationWarning() async throws {
        try await assertPersistentFailureAllowsLaunch(migrationWarning: true)
    }

    private func assertPersistentFailureAllowsLaunch(migrationWarning: Bool) async throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed()
        let before = try harness.deployedFiles()
        let paths = AppRuntimePaths(storeRoot: harness.root, appSupportDir: harness.root + "/support")
        let migration = try preparePersistentFailure(harness, migrationWarning: migrationWarning)
        let deploys = HandoverDeployments(root: harness.root)
        let convergence = HandoverConvergence()
        convergence.onLaunch = {
            XCTAssertFalse(IntentReconciler(platformVM: deploys.platformVM, machineIdentity: harness.identity,
                handoverIsComplete: { false })
                .reconcile(context: harness.freshContext()).hasFailures)
        }
        var attempts = 0
        var backfills = 0
        var outcomes: [LaunchReconcileOutcome] = []
        func runtime() throws -> AppRuntime {
            try AppRuntime(
                container: harness.container, library: library(harness), defaults: harness.defaults,
                launchReconcile: { context, migrated in
                    attempts += 1
                    XCTAssertNil(SyncLock.tryAcquire(at: paths.syncLockPath))
                    let outcome = LaunchReconciler(
                        rebuildService: StoreRebuildService(fileService: harness.files, manifestService: harness.manifest),
                        migrationService: migration,
                        fileService: harness.files, manifestService: harness.manifest, root: harness.root,
                        lockPath: paths.syncLockPath, scenarioHandover: harness.handover()
                    ).reconcileOnLaunch(context: context, alreadyMigrated: migrated, externallyHeldLock: true)
                    outcomes.append(outcome)
                    return outcome
                },
                launchBackfill: { _ in backfills += 1 }, hasRemoteConfigured: { false }, postSyncConvergence: convergence,
                launchIngestRetryNanoseconds: 10_000_000, paths: paths, gitUsabilityProbe: { .usable }
            )
        }
        let first = try runtime()
        first.performLaunchWorkIfNeeded(context: harness.freshContext())
        XCTAssertEqual(convergence.calls, 1)
        XCTAssertEqual(backfills, 1)
        XCTAssertFalse(try XCTUnwrap(outcomes.first).ingestionNeedsRetry)
        XCTAssertFalse(try XCTUnwrap(outcomes.first).rebuild.warnings.isEmpty)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(attempts, 1, "persistent handover conditions must not create an ingest retry loop")
        let next = try runtime()
        next.performLaunchWorkIfNeeded(context: harness.freshContext())
        XCTAssertEqual(attempts, 2, "the next launch ingest tries again")
        XCTAssertEqual(convergence.calls, 2)
        XCTAssertEqual(backfills, 2)
        XCTAssertTrue(outcomes.allSatisfy { !$0.ingestionNeedsRetry })
        try assertRetainedOwnership(harness, before: before, deploys: deploys, migrationWarning: migrationWarning)
    }

    private func preparePersistentFailure(_ harness: HandoverHarness,
                                          migrationWarning: Bool) throws -> StoreMigrationService {
        harness.defaults.set(!migrationWarning, forKey: AppRuntime.migrationDefaultsKey)
        harness.defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        harness.manifest.failAllWrites = !migrationWarning
        if migrationWarning {
            try harness.files.writeFile(at: harness.root + "/skills/skill/SKILL.md",
                                        content: "---\nname: [broken\n---\nBody")
        }
        return StoreMigrationService(
            fileService: harness.files, manifestService: harness.manifest.live,
            skillStore: SkillStore(fileService: harness.files, baseDir: harness.root + "/skills")
        )
    }

    private func assertRetainedOwnership(_ harness: HandoverHarness, before: [String: HandoverArtifact],
                                         deploys: HandoverDeployments, migrationWarning: Bool) throws {
        XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 2)
        XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
        XCTAssertNotNil(harness.defaults.object(forKey: ScenarioHandover.activeKey))
        XCTAssertEqual(try harness.deployedFiles(), before)
        XCTAssertEqual(deploys.createCalls, 0)
        XCTAssertEqual(deploys.removeCalls, 0)
        XCTAssertEqual(harness.manifest.writes, migrationWarning ? 0 : 2)
        XCTAssertEqual(harness.defaults.bool(forKey: AppRuntime.migrationDefaultsKey), !migrationWarning)
        try harness.assertUnrelatedIntentsUnchanged()
    }

    private func library(_ harness: HandoverHarness) -> SkillLibraryViewModel {
        SkillLibraryViewModel(
            skillStore: SkillStore(fileService: harness.files, baseDir: harness.root + "/skills"),
            fileService: harness.files, fileWatchService: HandoverWatcher(),
            manifestService: harness.manifest.live, manifestRoot: harness.root
        )
    }
}
