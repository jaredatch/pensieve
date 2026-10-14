import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeLaunchCompletionTests: XCTestCase {
    func testHeldLaunchKeepsMainActorRunningAndPublishesRebuiltRows() async throws {
        let paths = try AppRuntimePaths.temporary(named: "HeldLaunch")
        defer { try? FileService().deleteDirectory(at: (paths.storeRoot as NSString).deletingLastPathComponent) }
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        let container = try paths.makeContainer()
        let windowContext = container.mainContext
        let existing = Skill(name: "Stale", directoryName: "existing")
        windowContext.insert(existing)
        try windowContext.save()
        let gate = TestWait.Gate(owner: self)
        defer { gate.open() }
        let entered = expectation(description: "launch entered")
        let runtime = try AppRuntime(container: container, defaults: defaults,
            launchReconcile: { context, _ in
                XCTAssertFalse(Thread.isMainThread, "launch git and rebuild must leave the main thread")
                XCTAssertFalse(context === windowContext, "the job must own its context")
                entered.fulfill()
                if !Thread.isMainThread { try? gate.wait() }
                let rows = try? context.fetch(FetchDescriptor<Skill>())
                rows?.first?.name = "Updated"
                context.insert(Skill(name: "Rebuilt", directoryName: "rebuilt"))
                try? context.save()
                return LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: true, ingestedHeadStamp: "head")
            }, launchBackfill: { _ in XCTAssertFalse(Thread.isMainThread) },
            hasRemoteConfigured: { false }, paths: paths, gitUsabilityProbe: { .usable })
        let launch = Task { await runtime.performLaunchWorkIfNeeded(context: windowContext) }
        await fulfillment(of: [entered], timeout: TestWait.timeoutSeconds)
        XCTAssertFalse(runtime.launchWorkCompleted, "main actor must run before git is released")
        gate.open()
        await TestWait.until(failureMessage: "launch never published its result") { runtime.launchWorkCompleted }
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Skill>()).map(\.name).sorted(), ["Rebuilt", "Updated"])
        XCTAssertEqual(existing.name, "Updated", "the window's registered row must reflect the native rebuild")
        XCTAssertTrue(defaults.bool(forKey: AppRuntime.migrationDefaultsKey))
        _ = await launch.value
        await runtime.bootstrapTask.value
    }

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

    func testLaunchWorkStartsWithoutAWindowAndChecksUpdatesBeforeWatching() async throws {
        let paths = try AppRuntimePaths.temporary(named: "LaunchCompletion")
        defer { try? FileService().deleteDirectory(at: (paths.storeRoot as NSString).deletingLastPathComponent) }
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        defaults.set(UpdateCheckFrequency.daily.rawValue, forKey: UpdateCheckSchedule.frequencyKey)
        let watcher = AppRuntimeTests.StubWatcher()
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: FileService(),
            baseDir: paths.skillsDir, storeRoot: paths.storeRoot), fileWatchService: watcher, manifestRoot: paths.storeRoot)
        let checks = Counter()
        var backfilled = false
        let coordinatorGate = TestWait.Gate(owner: self)
        defer { coordinatorGate.open() }
        let runtime = try AppRuntime(library: library, defaults: defaults,
            launchReconcile: { _, _ in LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false) },
            launchBackfill: { _ in backfilled = true }, hasRemoteConfigured: { false }, paths: paths,
            updateCheckOperation: { _ in
                checks.increment()
                return RuntimeUpdateCheckResult(report: UpdateCheckReport(reachedRemote: false), skills: [:])
            }, gitUsabilityProbe: { .usable }, coordinatorConfigure: { _ in
                await BlockingWork.run { try? coordinatorGate.wait() }
            })
        XCTAssertFalse(runtime.launchWorkCompleted)
        watcher.onStart = { [weak runtime] in
            XCTAssertTrue(backfilled)
            XCTAssertTrue(runtime?.updateCheckInFlight == true, "the due check must start before the watcher")
            XCTAssertFalse(runtime?.launchWorkCompleted ?? true, "launch callbacks are still running")
        }
        runtime.start()
        await TestWait.until(failureMessage: "window-free launch never finished") { runtime.launchWorkCompleted }
        XCTAssertFalse(runtime.commandsReady, "coordinator setup is separate from completed launch callbacks")
        await TestWait.until(failureMessage: "due update check never finished") { !runtime.updateCheckInFlight }
        XCTAssertEqual(checks.value, 1)
        XCTAssertEqual(watcher.startCount, 1)
        XCTAssertEqual(runtime.launchWorkInvocationCount, 1)
        runtime.start()
        await runtime.performLaunchWorkIfNeeded(context: runtime.container.mainContext)
        XCTAssertEqual(runtime.launchWorkInvocationCount, 1)
        XCTAssertEqual(checks.value, 1)
        XCTAssertEqual(watcher.startCount, 1)
        coordinatorGate.open()
        await runtime.bootstrapTask.value
    }
}
