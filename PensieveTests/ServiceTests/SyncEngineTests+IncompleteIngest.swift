import SwiftData
import XCTest
@testable import Pensieve

extension SyncEngineTests {
    @MainActor
    func testSyncWithoutPrepareRebuildsAfterUnvalidatedLaunchHead() throws {
        for movesDuringRetry in [false, true] {
            let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            try NativeTestWork.run(container: container) { [self] context in
                let fixture = try IncompleteIngestFixture(base: tempDir + "/head-\(movesDuringRetry)")
                _ = StoreRebuildService().rebuild(fromRoot: fixture.app, context: context)
                var headReads = 0
                let launch = LaunchReconciler(migrationService: StoreMigrationService(skillStore: SkillStore(
                    fileService: fixture.files, baseDir: fixture.app + "/skills", storeRoot: fixture.app)),
                    root: fixture.app, lockPath: fixture.base + "/sync.lock", git: fixture.git,
                    headStampOverride: {
                        headReads += 1
                        do {
                            if movesDuringRetry, headReads == 2 {
                                try fixture.files.writeFile(at: fixture.peer + "/skills/item/first.txt",
                                                            content: "first advance")
                                _ = try fixture.git.stageAllAndCommit(at: fixture.peer,
                                                                     message: "advance without category change")
                                try fixture.git.push(at: fixture.peer, credential: nil)
                                _ = try fixture.git.fastForwardOnly(at: fixture.app, credential: nil)
                            }
                            if headReads == 3 {
                                try fixture.changePeer()
                                _ = try fixture.git.fastForwardOnly(at: fixture.app, credential: nil)
                            }
                        } catch { XCTFail("head-advance fixture failed: \(error)") }
                        return GitHeadStamp().read(root: fixture.app)
                    })
                let outcome = launch.reconcileOnLaunch(context: context, alreadyMigrated: true)
                XCTAssertTrue(outcome.ingestionNeedsRetry)
                XCTAssertNil(outcome.ingestedHeadStamp)
                XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Deleted", "Kept"],
                               "HEAD must move after the last rebuild reads the old categories")
                let snapshots = IncompleteSnapshotManifest()
                let engine = fixture.engine(rebuild: StoreRebuildService(), manifestService: snapshots)
                _ = try engine.sync(root: fixture.app, message: "after launch", credential: nil, context: ModelContext(container))
                XCTAssertEqual(snapshots.categoriesAtSnapshot.first, ["Added", "Kept"])
                try fixture.assertRemoteCategories()
            }
        }
    }

    @MainActor
    func testSyncWithoutPrepareRecoversIncompleteIngestBeforeWriting() throws {
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        try NativeTestWork.run { [self] in
            let fixture = try IncompleteIngestFixture(base: tempDir)
            _ = StoreRebuildService().rebuild(fromRoot: fixture.app, context: ModelContext(container))
            try fixture.changePeer()
            let rebuild = IncompleteIngestRebuild()
            rebuild.failWhenAddedCategoryExists = true
            let engine = fixture.engine(rebuild: rebuild)
            let remoteBefore = try fixture.remoteHead()
            XCTAssertThrowsError(try engine.sync(root: fixture.app, message: "fail", credential: nil,
                                                 context: ModelContext(container))) { error in
                XCTAssertEqual(error.localizedDescription, IncompleteIngestFixture.message)
            }
            XCTAssertEqual(try fixture.remoteHead(), remoteBefore)
            // There is no coordinator prepare hook on this caller. Its fresh context is still stale.
            rebuild.failWhenAddedCategoryExists = false
            guard case .synced = try engine.sync(root: fixture.app, message: "retry", credential: nil,
                                                 context: ModelContext(container)) else { return XCTFail("retry failed") }
            try fixture.assertRemoteCategories()
        }
    }
}
