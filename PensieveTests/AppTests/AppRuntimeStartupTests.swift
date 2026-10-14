import AppKit
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeStartupTests: XCTestCase {
    func testWindowFreeStartupUsesTheNormalSyncConditions() async throws {
        for (remote, enabled, conflict) in [(true, true, false), (false, true, false),
                                          (true, false, false), (true, true, true)] {
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            try fixture.seedRepository(remote: remote ? "https://fixture.test/store.git" : nil)
            let defaults = try isolatedDefaults()
            defaults.set(enabled, forKey: AppRuntime.backgroundSyncEnabledKey)
            let release = TestWait.Gate(owner: self)
            release.open()
            let engine = BlockingEngine(release: release)
            let runtime = try AppRuntime(defaults: defaults, launchBackfill: { _ in }, paths: fixture.paths,
                gitUsabilityProbe: { .usable }, coordinatorConfigure: { coordinator in
                    await coordinator.configure(engine: engine, git: fixture.paths.makeGitService(),
                        credentials: InMemoryCredentialStore(), root: fixture.root,
                        audit: SyncAudit(appSupport: fixture.support),
                        machine: (identity: InertMachineIdentity(), stateService: InertMachineStateService()))
                })
            defer { runtime.commandServer?.stop() }
            if conflict { runtime.syncModel.apply(.conflicted(["skills/example/SKILL.md"])) }
            runtime.start()
            await TestWait.until(failureMessage: "startup did not become ready") { runtime.commandsReady }
            if remote && enabled && !conflict {
                await TestWait.until(failureMessage: "window-free startup did not sync") { engine.finishedAt != nil }
                await TestWait.until(failureMessage: "startup sync did not settle") { !runtime.scheduler.isSyncing }
                XCTAssertEqual(engine.qosClasses.count, 1)
            } else {
                XCTAssertEqual(engine.qosClasses.count, 0)
                XCTAssertFalse(runtime.scheduler.isSyncing)
            }
            XCTAssertEqual(runtime.launchWorkInvocationCount, 1)
        }
    }

    func testDockAndMenuWindowActionWorksBeforeAnyWindowAppearedWithoutRestartingWork() async throws {
        let paths = try AppRuntimePaths.temporary(named: "ReopenStartup")
        defer { try? FileService().deleteDirectory(at: (paths.storeRoot as NSString).deletingLastPathComponent) }
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        let runtime = try AppRuntime(defaults: defaults, paths: paths, gitUsabilityProbe: { .usable })
        defer { runtime.commandServer?.stop() }
        runtime.start()
        await TestWait.until(failureMessage: "startup did not complete") { runtime.commandsReady }
        var opened = 0
        runtime.registerOpenMainWindowAction { opened += 1 }
        let delegate = try XCTUnwrap(PensieveAppDelegate.shared)
        let previousRuntime = delegate.runtime
        let visible = NSApp.windows.filter(\.isVisible)
        defer { delegate.runtime = previousRuntime; visible.forEach { $0.orderFront(nil) } }
        visible.forEach { $0.orderOut(nil) }
        delegate.runtime = runtime
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertEqual(opened, 1, "Dock reopening must reach the pre-registered window action")
        runtime.openMainWindow()
        XCTAssertEqual(opened, 2, "the menu bar shares that action")
        XCTAssertEqual(runtime.launchWorkInvocationCount, 1)
    }
}
