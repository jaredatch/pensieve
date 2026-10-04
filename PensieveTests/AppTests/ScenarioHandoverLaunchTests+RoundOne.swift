import SwiftData
import XCTest
@testable import Pensieve

extension ScenarioHandoverLaunchTests {
    func testTwiceMovingHeadStillMigratesUnderLockButDefersHandover() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed()
        let migration = RoundOneMigration(manifestWritten: true)
        migration.checkLock = { XCTAssertNil(SyncLock.tryAcquire(at: harness.root + "/sync.lock")) }
        var stamps = ["a", "b", "c", "c"]
        let result = LaunchReconciler(
            rebuildService: StoreRebuildService(fileService: harness.files, manifestService: harness.manifest),
            migrationService: migration, fileService: harness.files, manifestService: harness.manifest,
            root: harness.root, lockPath: harness.root + "/sync.lock", scenarioHandover: harness.handover(),
            headStampOverride: { stamps.removeFirst() }
        ).reconcileOnLaunch(context: harness.freshContext(), alreadyMigrated: false)
        XCTAssertEqual(migration.calls, 1)
        XCTAssertTrue(result.migrationRan)
        XCTAssertTrue(result.ingestionNeedsRetry)
        XCTAssertNil(result.ingestedHeadStamp)
        XCTAssertEqual(harness.manifest.writes, 0)
        XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
        XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 2)
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        try harness.assertComplete()
    }

    func testLaunchOutcomeDoesNotDependOnHandoverPresence() throws {
        for saveFailed in [false, true] {
            let harness = try HandoverHarness(defaults: isolatedDefaults("outcome-\(saveFailed)"))
            defer { try? harness.cleanUp() }
            try harness.seed()
            let migration = RoundOneMigration(manifestWritten: false)
            let rebuild = RoundOneRebuild(saveFailed: saveFailed)
            func launch(_ handover: ScenarioHandingOver?) -> LaunchReconcileOutcome {
                LaunchReconciler(rebuildService: rebuild, migrationService: migration,
                    fileService: harness.files, manifestService: harness.manifest,
                    root: harness.root, lockPath: harness.root + "/sync.lock", scenarioHandover: handover)
                    .reconcileOnLaunch(context: harness.freshContext(), alreadyMigrated: saveFailed)
            }
            XCTAssertEqual(launch(nil), launch(harness.handover()))
            XCTAssertEqual(harness.manifest.writes, 0)
            XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
            XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 2)
        }
    }
}

private final class RoundOneMigration: StoreMigrationServiceProtocol {
    var calls = 0
    var checkLock: () -> Void = {}
    let manifestWritten: Bool
    init(manifestWritten: Bool) { self.manifestWritten = manifestWritten }
    func migrateIfNeeded(fromRoot root: String, context: ModelContext) -> MigrationResult {
        calls += 1
        checkLock()
        return MigrationResult(skillsMigrated: 0, manifestWritten: manifestWritten,
                               warnings: manifestWritten ? [] : ["manifest failed"])
    }
}

private struct RoundOneRebuild: StoreRebuildServiceProtocol {
    let saveFailed: Bool
    func rebuild(fromRoot root: String, context: ModelContext) -> RebuildResult {
        var result = RebuildResult()
        result.saveFailed = saveFailed
        return result
    }
}
