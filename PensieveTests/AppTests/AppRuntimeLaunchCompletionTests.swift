import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeLaunchCompletionTests: XCTestCase {
    func testLaunchWorkCompletionFollowsCallbacksBeforeCoordinatorSignaling() async throws {
        let paths = try AppRuntimePaths.temporary(named: "LaunchCompletion")
        defer { try? FileService().deleteDirectory(at: (paths.storeRoot as NSString).deletingLastPathComponent) }
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        var backfilled = false
        let runtime = try AppRuntime(defaults: defaults,
            launchReconcile: { _, _ in LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false) },
            launchBackfill: { _ in backfilled = true }, hasRemoteConfigured: { false }, paths: paths,
            gitUsabilityProbe: { .usable })
        XCTAssertFalse(runtime.launchWorkCompleted)
        var callbackRan = false
        runtime.performLaunchWorkIfNeeded(context: runtime.container.mainContext) {
            XCTAssertTrue(backfilled)
            XCTAssertFalse(runtime.launchWorkCompleted, "launch callbacks are still running")
            callbackRan = true
        }
        XCTAssertTrue(callbackRan)
        XCTAssertTrue(runtime.launchWorkCompleted, "launch work finished before the asynchronous coordinator signal")
        await runtime.bootstrapTask.value
    }
}
