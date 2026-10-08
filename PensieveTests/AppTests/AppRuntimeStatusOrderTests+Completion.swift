import SwiftData
import XCTest
@testable import Pensieve

extension AppRuntimeStatusOrderTests {
    func testResolveAppearsOnlyAfterCycleCompletesDespiteConfigurationFailure() async throws {
        for hostFails in [false, true] {
            try await assertConflictAfterFailedRead(hostFails: hostFails)
        }
    }

    private func assertConflictAfterFailedRead(hostFails: Bool) async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let git = IngestRecordingGit()
        git.remoteRead = { "https://fixture.test/store.git" }
        let probe = RuleProbe()
        let runtime = try await completionRuntime(fixture, git: git, probe: probe, label: "resolve-\(hostFails)") {
            .conflicted(["skills/example/SKILL.md"])
        }
        let reading = expectation(description: "post-cycle read")
        let release = DispatchSemaphore(value: 0)
        git.remoteRead = {
            reading.fulfill(); release.wait()
            throw GitError.repositoryUnreadable(path: fixture.root, detail: "temporarily\nunreadable\u{2028}repository")
        }
        let model = runtime.syncModel
        let cycle = Task { await model.syncNowAndReport() }
        await fulfillment(of: [reading], timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertTrue(model.isCycleInFlight)
        XCTAssertEqual(SyncFooterPresentation.make(state: model.state, canResolve: model.canResolve,
                hovering: true, now: Date())?.action,
                       SyncFooterPresentation.Action.none)
        XCTAssertEqual(model.state, .syncing)
        XCTAssertFalse(model.canResolve, "the detail banner cannot offer Resolve yet")
        if hostFails { probe.set { .licenseNotAccepted } }
        if hostFails { await runtime.refreshGitUsability() }
        XCTAssertEqual(model.state, .syncing)
        release.signal()
        await cycle.value
        XCTAssertFalse(model.isCycleInFlight)
        XCTAssertTrue(model.canStartConflictResolution)
        XCTAssertEqual(SyncFooterPresentation.make(state: model.state, canResolve: model.canResolve,
                hovering: true, now: Date())?.action, .resolve)
        XCTAssertEqual(model.state, .conflicted(["skills/example/SKILL.md"]))
        XCTAssertEqual(runtime.gitUsability, hostFails ? .licenseNotAccepted : .usable)
        if !hostFails {
            XCTAssertEqual(model.configurationError, DisplayTextSanitizer.singleLine(GitError.repositoryUnreadable(
                path: fixture.root, detail: "temporarily\nunreadable\u{2028}repository").localizedDescription))
        }
        XCTAssertNotNil(model.configurationError, "conflict must win over both host and repository errors")
    }

    func testResolutionRecoveryStartsBackgroundSyncAfterConflictClears() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let git = IngestRecordingGit()
        git.remoteRead = { "https://fixture.test/store.git" }
        let probe = RuleProbe()
        probe.set { .licenseNotAccepted }
        let cycles = RuleProbe()
        let runtime = try await completionRuntime(fixture, git: git, probe: probe, label: "recovery") {
            _ = cycles.run()
            return .synced(pushed: false, warnings: [])
        }
        runtime.syncModel.apply(.conflicted(["skills/example/SKILL.md"]))
        runtime.scheduler.launchIngestCompleted()
        XCTAssertFalse(runtime.scheduler.hasPendingTrigger)
        try runtime.beginConflictResolution()(.synced(pushed: false, warnings: [], completedAt: Date()))
        XCTAssertTrue(runtime.scheduler.isSyncing, "recovery must reach the scheduler after the conflict clears")
        await TestWait.until(failureMessage: "recovery cycle did not finish") { !runtime.scheduler.isSyncing }
        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(runtime.gitUsability, .usable)
    }

    func testRecoveryDuringPostCycleReadQueuesOneCatchUpCycle() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let git = IngestRecordingGit()
        git.remoteRead = { "https://fixture.test/store.git" }
        let probe = RuleProbe(), cycles = RuleProbe(), reads = RuleProbe()
        let runtime = try await completionRuntime(fixture, git: git, probe: probe, label: "in-flight") {
            _ = cycles.run()
            return .synced(pushed: false, warnings: [])
        }
        runtime.syncModel.apply(.conflicted(["skills/example/SKILL.md"]))
        runtime.scheduler.launchIngestCompleted()
        runtime.syncModel.apply(.synced(pushed: false, warnings: [], completedAt: Date()))
        let reading = expectation(description: "post-cycle read")
        let release = DispatchSemaphore(value: 0)
        git.remoteRead = {
            _ = reads.run()
            if reads.count == 1 { reading.fulfill(); release.wait() }
            return "https://fixture.test/store.git"
        }
        let cycle = Task { await runtime.syncModel.syncNowAndReport() }
        await fulfillment(of: [reading], timeout: TestWait.hostedActionTimeoutSeconds)
        probe.set { .developerToolsMissing }
        await runtime.refreshGitUsability()
        probe.set { .usable }
        await runtime.refreshGitUsability()
        XCTAssertTrue(runtime.syncModel.isCycleInFlight)
        XCTAssertFalse(runtime.scheduler.isSyncing, "catch-up waits for the active callback to finish")
        release.signal()
        await cycle.value
        await TestWait.until(failureMessage: "follow-up did not finish") {
            !runtime.scheduler.isSyncing && !runtime.syncModel.isCycleInFlight
        }
        XCTAssertEqual(cycles.count, 2, "recovery during the read must queue exactly one catch-up cycle")
    }

    func completionRuntime(_ fixture: GitFailureFixture, git: IngestRecordingGit, probe: RuleProbe,
                           label: String, coordinatorGit: GitServiceProtocol = GitService(),
                           operation: @escaping () throws -> SyncOutcome) async throws -> AppRuntime {
        let runtime = try AppRuntime(syncModel: SyncModel(git: git, root: fixture.root),
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { true }),
            defaults: isolatedDefaults(label), paths: fixture.paths, gitUsabilityProbe: probe.run,
            coordinatorConfigure: { coordinator in
                await coordinator.configure(engine: StatusOrderEngine(operation: operation),
                    git: coordinatorGit, credentials: InMemoryCredentialStore(), root: fixture.root,
                    audit: SyncAudit(appSupport: fixture.support))
            })
        await runtime.bootstrapTask.value
        return runtime
    }
}
