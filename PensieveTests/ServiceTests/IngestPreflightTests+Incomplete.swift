import Foundation
import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testFailedPulledRebuildStopsPushAndRetryPreservesPeerCategories() async throws {
        for failsCategories in [false, true] {
            try await assertFailedPulledRebuild(failsCategories: failsCategories)
        }
    }

    private func assertFailedPulledRebuild(failsCategories: Bool) async throws {
        let fixture = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir + "/pull-\(failsCategories)") }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        try NativeTestWork.run(container: container) { context in
            _ = StoreRebuildService().rebuild(fromRoot: fixture.app, context: context)
        }
        let initial = GitHeadStamp().read(root: fixture.app)
        try NativeTestWork.run {
            try fixture.changePeer()
            try fixture.files.writeFile(at: fixture.app + "/skills/item/local.txt", content: "local change")
        }
        let remoteBefore = try NativeTestWork.run { try fixture.remoteHead() }
        let rebuild = IncompleteIngestRebuild()
        rebuild.failsCategories = failsCategories
        rebuild.failWhenAddedCategoryExists = true
        let coordinator = await makeIncompleteCoordinator(container: container, fixture: fixture, rebuild: rebuild)
        await coordinator.seedLastIngestedHeadStamp(initial)

        let failedCycle = await coordinator.runCycle()
        XCTAssertEqual(failedCycle, .failed(IncompleteIngestFixture.message))
        let model = SyncModel(git: fixture.git, root: fixture.app)
        model.apply(failedCycle)
        XCTAssertEqual(model.state, .error(IncompleteIngestFixture.message))
        XCTAssertEqual(try NativeTestWork.run { try fixture.remoteHead() }, remoteBefore, "failed ingest must not push")
        XCTAssertNotEqual(GitHeadStamp().read(root: fixture.app), initial, "the failure must occur after the pull")
        let pulledBytes = try fixture.manifest.read(fromRoot: fixture.app)
        XCTAssertEqual(pulledBytes.categories.map(\.name).sorted(), ["Added", "Kept"])
        let calls = rebuild.calls
        let failedRetry = await coordinator.runCycle()
        XCTAssertEqual(failedRetry, .failed(IncompleteIngestFixture.message))
        XCTAssertGreaterThan(rebuild.calls, calls, "the failed head must be retried before any snapshot write")
        XCTAssertEqual(try fixture.manifest.read(fromRoot: fixture.app), pulledBytes)

        rebuild.failWhenAddedCategoryExists = false
        guard case .synced = await coordinator.runCycle() else { return XCTFail("healthy retry did not sync") }
        try NativeTestWork.run { try fixture.assertRemoteCategories() }
        let afterSuccess = rebuild.calls
        guard case let .synced(_, _, _, advanced, _) = await coordinator.runCycle() else { return XCTFail("idle sync failed") }
        XCTAssertFalse(advanced)
        XCTAssertEqual(rebuild.calls, afterSuccess + 1, "healthy ingest records the head and skips the next preflight")
    }

    func testIncompleteLaunchSkipsMigrationAndFirstSyncRebuilds() async throws {
        for failsCategories in [false, true] {
            try await assertIncompleteLaunch(failsCategories: failsCategories)
        }
        for failsListing in [false, true] {
            try await assertIncompleteLocalLaunchCompletes(failsListing: failsListing)
            try assertNoRemoteSyncRecovery(failsListing: failsListing)
        }
        for busyLock in [false, true] {
            try assertCompleteLaunchRetryMigrates(busyLock: busyLock)
        }
    }

    private func assertIncompleteLaunch(failsCategories: Bool) async throws {
        let fixture = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir + "/launch-\(failsCategories)") }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        try NativeTestWork.run(container: container) { context in
            _ = StoreRebuildService().rebuild(fromRoot: fixture.app, context: context)
            try fixture.changePeer()
            _ = try fixture.git.fastForwardOnly(at: fixture.app, credential: nil)
        }
        let rebuild = IncompleteIngestRebuild()
        rebuild.fails = true
        rebuild.failsCategories = failsCategories
        let outcome = try NativeTestWork.run(container: container) { context in
            LaunchReconciler(rebuildService: rebuild,
                migrationService: StoreMigrationService(skillStore: SkillStore(
                    fileService: FileService(), baseDir: fixture.app + "/skills", storeRoot: fixture.app)),
                root: fixture.app, lockPath: fixture.base + "/sync.lock", git: fixture.git)
                .reconcileOnLaunch(context: context, alreadyMigrated: false)
        }
        XCTAssertEqual(outcome.rebuild.saveFailed, !failsCategories)
        XCTAssertEqual(outcome.rebuild.categoryReadFailed, failsCategories)
        XCTAssertNil(outcome.ingestedHeadStamp)
        XCTAssertFalse(outcome.ingestionNeedsRetry, "An incomplete remote-backed launch also finishes without a retry")
        XCTAssertFalse(outcome.migrationRan)
        XCTAssertEqual(try fixture.manifest.read(fromRoot: fixture.app).categories.map(\.name).sorted(), ["Added", "Kept"])
        rebuild.fails = false
        let coordinator = await makeIncompleteCoordinator(container: container, fixture: fixture, rebuild: rebuild)
        await coordinator.seedLastIngestedHeadStamp(outcome.ingestedHeadStamp)
        guard case .synced = await coordinator.runCycle() else { return XCTFail("first sync failed") }
        try NativeTestWork.run { try fixture.assertRemoteCategories() }
        let later = try NativeTestWork.run(container: container) { context in
            LaunchReconciler(rebuildService: rebuild,
                migrationService: StoreMigrationService(skillStore: SkillStore(
                    fileService: FileService(), baseDir: fixture.app + "/skills", storeRoot: fixture.app)),
                root: fixture.app, lockPath: fixture.base + "/sync.lock", git: fixture.git)
                .reconcileOnLaunch(context: context, alreadyMigrated: false)
        }
        XCTAssertTrue(later.migrationRan, "a later complete launch still performs the due migration")
    }

    private func assertIncompleteLocalLaunchCompletes(failsListing: Bool) async throws {
        let fixture = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/persistent-local-launch-\(failsListing)")
        }
        try NativeTestWork.run { try fixture.git.removeRemote(at: fixture.app) }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let rebuild = IncompleteIngestRebuild()
        rebuild.fails = true
        rebuild.failsListing = failsListing
        let launch = LaunchReconciler(rebuildService: rebuild,
            migrationService: StoreMigrationService(skillStore: SkillStore(
                fileService: fixture.files, baseDir: fixture.app + "/skills", storeRoot: fixture.app)),
            root: fixture.app, lockPath: fixture.base + "/sync.lock", git: fixture.git)
        let outcome = try NativeTestWork.run(container: container) { context in
            launch.reconcileOnLaunch(context: context, alreadyMigrated: false)
        }
        XCTAssertTrue(outcome.rebuild.ingestIncomplete)
        XCTAssertFalse(outcome.ingestionNeedsRetry, "A persistent local ingest failure must let launch finish")
        XCTAssertFalse(outcome.migrationRan)
        XCTAssertNil(outcome.ingestedHeadStamp)
        let runtime = try AppRuntime(container: container, launchReconcile: { context, migrated in
            launch.reconcileOnLaunch(context: context, alreadyMigrated: migrated, externallyHeldLock: true)
        }, launchBackfill: { _ in }, hasRemoteConfigured: { false },
            launchIngestLockPath: fixture.base + "/sync.lock",
            paths: AppRuntimePaths.temporary(named: "IncompleteLocalLaunch"), gitUsabilityProbe: { .usable })
        await runtime.bootstrapTask.value
        _ = await runtime.performLaunchWorkIfNeeded(context: container.mainContext)
        XCTAssertTrue(runtime.launchWorkCompleted, "Launch must finish even while every ingest attempt fails")
        XCTAssertFalse(runtime.library.launchIngestPending)
        XCTAssertFalse(runtime.library.addsFenced, "An incomplete ingest must not hold adds behind launch")
        XCTAssertTrue(StoreIngestState.shared(for: container).needsRebuild)
        XCTAssertEqual(rebuild.calls, 2, "Both attempts exercise the persistent failure")
    }

    private func assertNoRemoteSyncRecovery(failsListing: Bool) throws {
        let fixture = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/sync-no-remote-\(failsListing)")
        }
        try NativeTestWork.run {
            try fixture.git.removeRemote(at: fixture.app)
            try fixture.manifest.write(IncompleteIngestFixture.snapshot(["Added", "Kept"]), toRoot: fixture.app)
        }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        try NativeTestWork.run(container: container) { context in
            let rebuild = IncompleteIngestRebuild()
            rebuild.failsListing = failsListing
            rebuild.fails = true
            let launch = LaunchReconciler(rebuildService: rebuild,
                migrationService: StoreMigrationService(skillStore: SkillStore(
                    fileService: fixture.files, baseDir: fixture.app + "/skills", storeRoot: fixture.app)),
                root: fixture.app, lockPath: fixture.base + "/sync.lock", git: fixture.git)
            let outcome = launch.reconcileOnLaunch(context: context, alreadyMigrated: false)
            XCTAssertFalse(outcome.ingestionNeedsRetry)
            let before = try fixture.git.runOrThrow(["-C", fixture.app, "diff", "--binary", "HEAD"], in: nil).stdout
            let manifest = try fixture.manifest.read(fromRoot: fixture.app)
            let engine = fixture.engine(rebuild: rebuild)
            for fails in [true, false] {
                rebuild.fails = fails
                let calls = rebuild.calls
                XCTAssertEqual(try engine.sync(root: fixture.app, message: "no remote", credential: nil,
                    context: context, prepare: { _ in
                        XCTFail("Unconfigured sync must not run snapshot preparation")
                    }), .noRemote)
                XCTAssertEqual(rebuild.calls, calls + 1, "No-remote sync must retry pending library ingestion")
                XCTAssertEqual(StoreIngestState.shared(for: container).needsRebuild, fails)
                XCTAssertEqual(try fixture.manifest.read(fromRoot: fixture.app), manifest)
                XCTAssertEqual(
                    try fixture.git.runOrThrow(["-C", fixture.app, "diff", "--binary", "HEAD"], in: nil).stdout, before)
            }
            XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Added", "Kept"])
            XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).map(\.directoryName), ["item"])
            XCTAssertTrue(launch.reconcileOnLaunch(context: context, alreadyMigrated: false).migrationRan)
        }
    }

    private func assertCompleteLaunchRetryMigrates(busyLock: Bool) throws {
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        try NativeTestWork.run(container: container) { context in
            let fixture = try IncompleteIngestFixture(base: self.tempDir + "/migration-retry-\(busyLock)")
            _ = StoreRebuildService().rebuild(fromRoot: fixture.app, context: context)
            try fixture.files.writeFile(at: fixture.app + "/skills/item/SKILL.md", content: "legacy body\n")
            let lockPath = fixture.base + "/sync.lock"
            let held = busyLock ? try XCTUnwrap(SyncLock.tryAcquire(at: lockPath)) : nil
            defer { held?.release() }
            var reads = 0
            let launch = LaunchReconciler(migrationService: StoreMigrationService(skillStore: SkillStore(
                fileService: fixture.files, baseDir: fixture.app + "/skills", storeRoot: fixture.app)),
                root: fixture.app, lockPath: lockPath, git: fixture.git, headStampOverride: {
                    reads += 1
                    if !busyLock, reads == 3 {
                        do {
                            try fixture.changePeer()
                            _ = try fixture.git.fastForwardOnly(at: fixture.app, credential: nil)
                        } catch { XCTFail("HEAD advance failed: \(error)") }
                    }
                    return GitHeadStamp().read(root: fixture.app)
                })
            let first = launch.reconcileOnLaunch(context: context, alreadyMigrated: false)
            XCTAssertFalse(first.rebuild.ingestIncomplete)
            XCTAssertTrue(first.ingestionNeedsRetry, "A busy lock or moved HEAD must request a launch retry")
            XCTAssertFalse(first.migrationRan)
            XCTAssertTrue(StoreIngestState.shared(for: container).needsRebuild)
            XCTAssertTrue(try fixture.manifest.read(fromRoot: fixture.app).skills.isEmpty)
            held?.release()
            let retry = launch.reconcileOnLaunch(context: context, alreadyMigrated: false)
            XCTAssertFalse(retry.rebuild.ingestIncomplete)
            XCTAssertFalse(retry.ingestionNeedsRetry)
            XCTAssertTrue(retry.migrationRan, "A complete retry after a busy lock or moved HEAD must run due migration")
            XCTAssertEqual(retry.ingestedHeadStamp, GitHeadStamp().read(root: fixture.app))
            XCTAssertEqual(try fixture.manifest.read(fromRoot: fixture.app).skills.map(\.slug), ["item"])
            XCTAssertTrue(SkillParser.parse(try fixture.files.readFile(at: fixture.app + "/skills/item/SKILL.md"))
                .hasRequiredFrontmatter, "The retry must backfill legacy frontmatter")
            XCTAssertFalse(launch.reconcileOnLaunch(context: context, alreadyMigrated: true).migrationRan)
        }
    }

    func testFailedConnectAndSameHeadReconnectInvalidateIngestCache() async throws {
        let fixture = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir) }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let rebuild = IncompleteIngestRebuild()
        let snapshots = IncompleteSnapshotManifest()
        let coordinator = await makeIncompleteCoordinator(container: container, fixture: fixture, rebuild: rebuild,
                                                          manifest: snapshots)
        let stamp = GitHeadStamp().read(root: fixture.app)
        await coordinator.seedLastIngestedHeadStamp(stamp)
        rebuild.fails = true
        let setup = SyncSetupModel(context: ModelContext(container), git: fixture.git,
            credentials: IngestEmptyCredentials(), rebuilder: rebuild, root: fixture.app,
            lockPath: fixture.base + "/sync.lock", steps: SyncStepModel())
        await setup.connectAndReport(url: "git@fixture.example:repo.git", username: "", token: "")
        XCTAssertEqual(setup.state, .failed(IncompleteIngestFixture.message))
        // Restore the file:// remote through the real setup transaction used by integration callers.
        try await setup.performDisconnect()
        rebuild.fails = false
        try await setup.perform(spec: RemoteSpec(url: fixture.remote, host: "fixture.test", transport: .ssh),
                                credential: .sshAgent)
        XCTAssertEqual(GitHeadStamp().read(root: fixture.app), stamp)
        // Disk changes while disconnected, but HEAD and the saved window rows stay unchanged.
        try await setup.performDisconnect()
        try fixture.manifest.write(IncompleteIngestFixture.snapshot(["Added", "Kept"]), toRoot: fixture.app)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(),
                       ["Deleted", "Kept"], "the first sync must start with stale saved window rows")
        try await setup.perform(spec: RemoteSpec(url: fixture.remote, host: "fixture.test", transport: .ssh),
                                credential: .sshAgent)
        XCTAssertEqual(GitHeadStamp().read(root: fixture.app), stamp, "reconnect must not advance HEAD")
        let pendingManifest = try fixture.manifest.read(fromRoot: fixture.app)
        try fixture.files.deleteDirectory(at: fixture.app + "/manifest")
        let skipped = try NativeTestWork.run(container: container) { context in
            LaunchReconciler(rebuildService: rebuild,
                migrationService: StoreMigrationService(skillStore: SkillStore(
                    fileService: fixture.files, baseDir: fixture.app + "/skills", storeRoot: fixture.app)),
                root: fixture.app, lockPath: fixture.base + "/sync.lock", git: fixture.git)
                .reconcileOnLaunch(context: context, alreadyMigrated: true)
        }
        XCTAssertEqual(skipped.rebuild, RebuildResult(), "a content-free manifest skips launch rebuilding")
        XCTAssertNil(skipped.ingestedHeadStamp, "skipping a rebuild cannot admit Connect's pending head")
        XCTAssertFalse(skipped.ingestionNeedsRetry, "a skipped rebuild hands off to the required sync preflight")
        try fixture.manifest.write(pendingManifest, toRoot: fixture.app)
        let calls = rebuild.calls
        guard case .synced = await coordinator.runCycle() else { return XCTFail("reconnected cycle failed") }
        XCTAssertEqual(rebuild.calls, calls + 2, "Connect invalidates a cached head even when HEAD does not move")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(),
                       ["Added", "Kept"])
        XCTAssertEqual(snapshots.categoriesAtSnapshot.first, ["Added", "Kept"], "ingest must precede the snapshot")
        try NativeTestWork.run { try fixture.assertRemoteCategories() }
    }

    func makeIncompleteCoordinator(container: ModelContainer, fixture: IncompleteIngestFixture,
                                   rebuild: IncompleteIngestRebuild,
                                   manifest: ManifestSnapshotting = ManifestService()) async -> SyncCoordinator {
        let coordinator = await Task.detached { SyncCoordinator(modelContainer: container) }.value
        await coordinator.configure(engine: fixture.engine(rebuild: rebuild, manifestService: manifest), git: fixture.git,
            credentials: IngestEmptyCredentials(), rebuildService: rebuild, root: fixture.app,
            audit: IngestNullAudit(), machine: (identity: InertMachineIdentity(), stateService: InertMachineStateService()))
        return coordinator
    }
}
