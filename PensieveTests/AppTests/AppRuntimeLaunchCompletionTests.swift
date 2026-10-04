import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeLaunchCompletionTests: XCTestCase {
    func testLaunchStateRemainsPrivateAndCompletionIsReadOnly() throws {
        // Visibility and the source cap are explicit requirements; behavior cannot prove a missing setter.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Pensieve/AppRuntime.swift"), encoding: .utf8)
        for name in ["didCompleteLaunchIngest", "didFinishInitialLaunchCallbacks", "didSignalLaunchIngest",
                     "launchIngestHeadStamp", "forceLaunchPreflight"] {
            let declaration = try NSRegularExpression(pattern: "private var " + name + #"\b"#)
            XCTAssertNotNil(declaration.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), name)
        }
        XCTAssertTrue(source.contains("private(set) var launchWorkCompleted"))
        XCTAssertLessThanOrEqual(source.split(separator: "\n", omittingEmptySubsequences: false).count - 1, 400)
        let helpers = try String(contentsOf: root.appendingPathComponent("Pensieve/AppRuntime+LaunchSignals.swift"),
                                 encoding: .utf8)
        XCTAssertFalse(helpers.contains("didSignalLaunchIngest"))
        XCTAssertFalse(helpers.contains("forceLaunchPreflight"))
    }

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
