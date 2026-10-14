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
        guard case let .synced(_, _, _, advanced) = await coordinator.runCycle() else { return XCTFail("idle sync failed") }
        XCTAssertFalse(advanced)
        XCTAssertEqual(rebuild.calls, afterSuccess + 1, "healthy ingest records the head and skips the next preflight")
    }

    func testIncompleteLaunchSkipsMigrationAndFirstSyncRebuilds() async throws {
        for failsCategories in [false, true] {
            try await assertIncompleteLaunch(failsCategories: failsCategories)
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
