import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeConfigurationOrderTests: XCTestCase {
    func testSynchronousConfigurationReadRetiresOlderDetachedAnswer() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let git = IngestRecordingGit()
        let model = SyncModel(git: git, root: fixture.root)
        let runtime = try AppRuntime(syncModel: model,
                                     scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
                                     defaults: isolatedDefaults(), paths: fixture.paths, gitUsabilityProbe: { .usable })
        await runtime.bootstrapTask.value
        let started = expectation(description: "old read started")
        let release = DispatchSemaphore(value: 0)
        let calls = RuleProbe()
        git.remoteRead = {
            _ = calls.run()
            if calls.count > 1 { return "https://fixture.test/connected.git" }
            started.fulfill()
            release.wait()
            return nil
        }
        let old = Task { await runtime.refreshGitConfiguration(probingGit: false) }
        await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
        await runtime.refreshGitConfiguration(probingGit: false)
        release.signal()
        await old.value
        XCTAssertEqual(model.remoteURL, "https://fixture.test/connected.git")
        XCTAssertFalse(model.canConnect)
        XCTAssertNotEqual(model.configurationDescription, "Not connected")
    }

    func testCycleConfigurationWritesRetireOlderDetachedReads() async throws {
        for absent in [false, true] {
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            let git = IngestRecordingGit()
            let model = SyncModel(git: git, root: fixture.root)
            let runtime = try AppRuntime(syncModel: model,
                                         scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
                                         defaults: isolatedDefaults("cycle-\(absent)"),
                                         paths: fixture.paths, gitUsabilityProbe: { .usable })
            await runtime.bootstrapTask.value
            let started = expectation(description: "old read started")
            let release = DispatchSemaphore(value: 0)
            git.remoteRead = {
                started.fulfill()
                release.wait()
                return absent ? "https://fixture.test/latest.git" : nil
            }
            let old = Task { await runtime.refreshGitConfiguration(probingGit: false) }
            await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
            model.apply(absent ? .noRemote : .synced(pushed: false, warnings: [], completedAt: Date()))
            release.signal()
            await old.value
            // The legacy test name stays in the plan. A cycle no longer retires a read without an answer.
            XCTAssertEqual(model.canConnect, !absent)
            XCTAssertEqual(model.remoteURL, absent ? "https://fixture.test/latest.git" : nil)
            XCTAssertEqual(model.configurationDescription, absent ? "https://fixture.test/latest.git" : "Not connected")
        }
    }
}
