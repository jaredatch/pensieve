import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeGitRecoveryTests: XCTestCase {
    func testSettingsWaitsForFirstConfigurationReadAndTracksNoRemoteCycle() async throws {
        let git = IngestRecordingGit()
        let model = SyncModel(git: git, root: "/unused-test-root")
        XCTAssertFalse(model.canConnect, "a pending read is not known absence")
        XCTAssertNotEqual(model.configurationDescription, "Not connected")
        git.remoteRead = { "https://fixture.test/store.git" }
        let modelConfiguration = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("configuration"))
        defer { try? modelConfiguration.remove() }
        await modelConfiguration.refresh()
        XCTAssertFalse(model.canConnect)
        model.apply(.noRemote)
        XCTAssertEqual(model.remoteURL, "https://fixture.test/store.git")
        XCTAssertFalse(model.canConnect, "a cycle does not answer whether origin is absent")
        git.remoteRead = { nil }
        await modelConfiguration.refresh()
        XCTAssertNil(model.remoteURL)
        XCTAssertTrue(model.canConnect)
        XCTAssertEqual(model.configurationDescription, "Not connected")
    }

    func testCompletedCyclesReplaceStaleConfigurationErrors() async throws {
        for noRemote in [false, true] {
            let git = IngestRecordingGit()
            let model = SyncModel(git: git, root: "/unused-test-root")
            git.remoteRead = { "https://fixture.test/store.git" }
            let modelConfiguration = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("cycle-\(noRemote)"))
            defer { try? modelConfiguration.remove() }
            await modelConfiguration.refresh()
            git.remoteRead = { throw GitError.repositoryUnreadable(path: "/unused-test-root", detail: "transient read") }
            await modelConfiguration.refresh()
            let date = Date(timeIntervalSince1970: 100)
            model.apply(noRemote ? .noRemote : .synced(pushed: false, warnings: [], completedAt: date))
            XCTAssertNotNil(model.configurationError, "the read after the cycle owns configuration")
            XCTAssertFalse(model.canConnect)
            git.remoteRead = { noRemote ? nil : "https://fixture.test/store.git" }
            await modelConfiguration.refresh()
            XCTAssertNil(model.configurationError)
            XCTAssertEqual(model.state, noRemote ? .unconfigured : .synced(at: date))
            if noRemote { XCTAssertNil(model.remoteURL) }
        }
        let git = IngestRecordingGit()
        git.remoteRead = { throw GitError.repositoryUnreadable(path: "/unused-test-root", detail: "old read") }
        let failed = SyncModel(git: git, root: "/unused-test-root")
        let failedConfiguration = try RuntimeConfigurationFixture(failed, defaults: isolatedDefaults("failed-configuration"))
        defer { try? failedConfiguration.remove() }
        await failedConfiguration.refresh()
        failed.apply(.failed("current cycle failure"))
        XCTAssertEqual(failed.state, .error("current cycle failure"))
    }

    func testSuccessfulCycleCannotInventKnownAbsenceAfterFailedRead() async throws {
        let git = IngestRecordingGit()
        let model = SyncModel(git: git, root: "/unused-test-root")
        git.remoteRead = { throw GitError.repositoryUnreadable(path: "/unused-test-root", detail: "transient read") }
        let modelConfiguration = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("configuration"))
        defer { try? modelConfiguration.remove() }
        await modelConfiguration.refresh()
        model.apply(.synced(pushed: false, warnings: [], completedAt: Date()))
        XCTAssertFalse(model.canConnect)
        XCTAssertNotEqual(model.configurationDescription, "Not connected")
        XCTAssertNotNil(model.configurationError, "without a known URL, the failed read still owns the answer")
        git.remoteRead = { "https://fixture.test/store.git" }
        await modelConfiguration.refresh()
        XCTAssertFalse(model.canConnect)
        XCTAssertNil(model.configurationError)
        git.remoteRead = { nil }
        await modelConfiguration.refresh()
        XCTAssertTrue(model.canConnect)
    }

    func testLatestPostCycleConfigurationReadKeepsAbsenceAndFailure() async throws {
        for absent in [true, false] {
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            try fixture.seedRepository()
            let runtime = try AppRuntime(
                scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
                defaults: isolatedDefaults("cycle-\(absent)"), paths: fixture.paths, gitUsabilityProbe: { .usable },
                coordinatorConfigure: { coordinator in
                    let engine = RecoveredPresentationEngine(finish: {
                        if absent {
                            try GitService().removeRemote(at: fixture.root)
                        } else {
                            try fixture.files.deleteFile(at: fixture.root + "/.git/HEAD")
                        }
                    })
                    await coordinator.configure(engine: engine, git: GitService(),
                                                credentials: InMemoryCredentialStore(), root: fixture.root,
                                                audit: SyncAudit(appSupport: fixture.support))
                }
            )
            await runtime.bootstrapTask.value
            await runtime.syncModel.syncNowAndReport()
            if absent {
                XCTAssertNil(runtime.syncModel.remoteURL)
                XCTAssertEqual(runtime.syncModel.configurationDescription, "Not connected")
                XCTAssertTrue(runtime.syncModel.canConnect)
                XCTAssertEqual(runtime.syncModel.state, .unconfigured)
            } else {
                XCTAssertNotNil(runtime.syncModel.configurationError)
                guard case .error = runtime.syncModel.state else { return XCTFail("the latest read failed") }
            }
        }
    }

    func testScheduledCycleRecoversTransientRepositoryReadFailure() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let headPath = fixture.root + "/.git/HEAD"
        let head = try fixture.files.readFile(at: headPath)
        try fixture.files.deleteFile(at: headPath)
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { true }),
            defaults: isolatedDefaults(), paths: fixture.paths, gitUsabilityProbe: { .usable },
            coordinatorConfigure: { coordinator in
                await coordinator.configure(engine: RecoveredPresentationEngine(), git: GitService(),
                                            credentials: InMemoryCredentialStore(), root: fixture.root,
                                            audit: SyncAudit(appSupport: fixture.support))
            }
        )
        await runtime.bootstrapTask.value
        XCTAssertNotNil(runtime.syncModel.configurationError)
        try fixture.files.writeFile(at: headPath, content: head)
        runtime.scheduler.launchIngestCompleted()
        runtime.scheduler.tick()
        await TestWait.until(failureMessage: "usable git must retry an unknown repository") {
            runtime.syncModel.lastSyncedAt != nil && !runtime.scheduler.isSyncing && !runtime.scheduler.hasPendingTrigger
        }
        XCTAssertNil(runtime.syncModel.configurationError)
        XCTAssertEqual(runtime.syncModel.remoteURL, "https://fixture.test/store.git")
        XCTAssertFalse(runtime.syncModel.canConnect)
        guard case .synced = runtime.syncModel.state else { return XCTFail("cycle must replace the stale read failure") }
    }
}
