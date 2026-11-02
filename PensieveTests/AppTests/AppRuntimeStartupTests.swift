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
        try await BlockingWork.run { try CLIProcessProbe.assertHungProbeIsBounded() }
        // The test host has no production scene. Drive a disposable production process so removing
        // PensieveApp's registration cannot be masked by the runtime spy below.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        probe.arguments = ["-B", root.appendingPathComponent("script/cli_contract_test.py").path, "--binary",
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pensieve").path,
            "CLILaunchTests.test_background_production_reopens_from_the_dock"]
        let files = FileService()
        let outputRoot = TestTemporaryDirectory.path + "ProductionReopen-" + UUID().uuidString
        try files.createDirectory(at: outputRoot)
        defer { try? files.deleteDirectory(at: outputRoot) }
        let outputURL = URL(fileURLWithPath: outputRoot + "/probe.log")
        try files.writeFile(at: outputURL.path, content: "")
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        probe.standardOutput = output
        probe.standardError = output
        let result = try await BlockingWork.run { try CLIProcessProbe.run(probe) }
        let state = try probeState(result, outputURL: outputURL)
        XCTAssertFalse(result.timedOut, "\(state) | the production window probe exceeded its deadline")
        XCTAssertEqual(result.status, 0, "\(state) | the real production scene must open from its registered action")
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
        let animations = visible.map(\.animationBehavior)
        defer {
            delegate.runtime = previousRuntime
            for (window, animation) in zip(visible, animations) {
                window.orderFront(nil)
                window.animationBehavior = animation
            }
        }
        visible.forEach { $0.animationBehavior = .none; $0.orderOut(nil) }
        delegate.runtime = runtime
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertEqual(opened, 1, "Dock reopening must reach the pre-registered window action")
        runtime.openMainWindow()
        XCTAssertEqual(opened, 2, "the menu bar shares that action")
        XCTAssertEqual(runtime.launchWorkInvocationCount, 1)
    }

    private func probeState(_ result: CLIProcessProbe.Outcome, outputURL: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let end = try reader.seekToEnd()
        try reader.seek(toOffset: end > 1400 ? end - 1400 : 0)
        let tail = (String(data: try reader.readToEnd() ?? Data(), encoding: .utf8) ?? "non-UTF8 probe output")
            .replacingOccurrences(of: "\n", with: " | ")
        return "elapsed=\(result.elapsed) timedOut=\(result.timedOut) status=\(String(describing: result.status)) | \(tail)"
    }

}
