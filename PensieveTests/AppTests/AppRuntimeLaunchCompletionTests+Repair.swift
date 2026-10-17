import SwiftData
import XCTest
@testable import Pensieve

extension AppRuntimeLaunchCompletionTests {
    func testDamagedLaunchResumesBackfillAndConvergenceOnceAfterLocalOrPeerRepair() async throws {
        for mode in ["local", "peer", "newer"] {
            let paths = try AppRuntimePaths.temporary(named: "RepairLaunch")
            let files = FileService()
            defer { try? files.deleteDirectory(at: (paths.storeRoot as NSString).deletingLastPathComponent) }
            let defaults = try paths.makeDefaults()
            defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
            defaults.set("off", forKey: UpdateCheckSchedule.frequencyKey)
            try files.writeFile(at: paths.storeRoot + "/manifest/manifest.yaml",
                content: mode == "newer" ? "schema_version: 999\n" : "damaged")
            let backfills = Counter(), convergence = RepairLaunchConvergence()
            let runtime = try AppRuntime(defaults: defaults, launchBackfill: { _ in backfills.increment() },
                hasRemoteConfigured: { false }, postSyncConvergence: convergence, paths: paths)
            runtime.start()
            await TestWait.until(failureMessage: "Damaged launch did not finish") { runtime.launchWorkCompleted }
            await runtime.bootstrapTask.value
            defer { runtime.commandServer?.stop(); runtime.library.stopWatching() }
            let saves = try XCTUnwrap(runtime.library.manifestSaves)
            await saves.refreshAndRetry()
            XCTAssertEqual(backfills.value, 0)
            XCTAssertEqual(convergence.launches, 0)
            if mode == "newer" { continue }
            try files.writeFile(at: paths.appSupportDir + "/deploy-state.json", content: "damaged ledger")
            XCTAssertEqual(runtime.platformVM.deployIndex, .empty)
            if mode == "local" {
                saves.requestRepair()
                await saves.replaceWithThisMac(context: runtime.container.mainContext)
            } else {
                let manifest = ManifestService()
                let token = ManifestDamage.capture(root: paths.storeRoot, files: files)
                _ = try manifest.repair(try manifest.snapshot(from: runtime.container.mainContext),
                    root: paths.storeRoot, replacing: token)
                await runtime.applyLibrarySyncOutcome(.noRemote)
            }
            XCTAssertEqual(backfills.value, 1, "Repair must resume the skipped launch backfill")
            XCTAssertEqual(convergence.launches, 1, "Repair must resume launch convergence")
            XCTAssertEqual(runtime.platformVM.deployIndex, .unavailable, "Repair refreshes the deploy index")
            await saves.refreshAndRetry()
            XCTAssertEqual(backfills.value, 1, "Launch backfill runs once")
            XCTAssertEqual(convergence.launches, 1)
        }
    }
}

@MainActor
private final class RepairLaunchConvergence: PostSyncConverging {
    var launches = 0
    func run(after result: SyncCycleResult) {}
    func runAfterLaunchIngest() { launches += 1 }
}
