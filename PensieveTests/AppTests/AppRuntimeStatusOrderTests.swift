import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeStatusOrderTests: XCTestCase {
    func testConflictedStateRefusesSyncNowFromEveryEntryPoint() async throws {
        let model = SyncModel(initialState: .conflicted(["skills/example/SKILL.md"]))
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        XCTAssertFalse(model.canSyncNow)
        var pending = 0, cycles = 0
        model.installPendingSyncRequest { pending += 1 }
        await model.syncNowAndReport()
        XCTAssertEqual(pending, 0, "a pre-coordinator request is refused")
        model.installSyncRequest { cycles += 1 }
        await model.syncNowAndReport()
        await model.syncNowAndReport(context: container.mainContext)
        model.syncNow()
        model.syncNow(context: container.mainContext)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(cycles, 0, "menu and sidebar requests cannot run over a conflict")
        model.apply(.synced(pushed: false, warnings: [], completedAt: Date()))
        XCTAssertTrue(model.canSyncNow)
        model.installSyncRequest {
            cycles += 1
            await model.syncNowAndReport()
            model.apply(.conflicted(["skills/example/SKILL.md"]))
        }
        await model.syncNowAndReport()
        XCTAssertEqual(cycles, 1, "Sync Now works after resolution")
        XCTAssertEqual(pending, 0, "a queued manual follow-up is discarded when the cycle finds a conflict")
        await model.syncScheduledAndReport()
        XCTAssertEqual(cycles, 1)
    }

    func testConflictResolutionCannotStartWhileCycleInFlight() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let git = IngestRecordingGit()
        git.remoteRead = { "https://fixture.test/store.git" }
        let model = SyncModel(git: git, root: fixture.root)
        let runtime = try AppRuntime(syncModel: model,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults(), paths: fixture.paths, gitUsabilityProbe: { .usable },
            coordinatorConfigure: { coordinator in
                await coordinator.configure(engine: StatusOrderEngine(operation: { .conflicted(["skills/example/SKILL.md"]) }),
                    git: GitService(), credentials: InMemoryCredentialStore(), root: fixture.root,
                    audit: SyncAudit(appSupport: fixture.support))
            })
        await runtime.bootstrapTask.value
        let reading = expectation(description: "cycle configuration read")
        let release = DispatchSemaphore(value: 0)
        git.remoteRead = { reading.fulfill(); release.wait(); return "https://fixture.test/store.git" }
        let cycle = Task { await model.syncNowAndReport() }
        await fulfillment(of: [reading], timeout: 2)
        XCTAssertEqual(model.state, .syncing)
        XCTAssertTrue(model.isCycleInFlight)
        var resolutions = 0
        let resolution = ConflictResolutionModel(engine: StatusOrderEngine(operation: {
            resolutions += 1
            return .synced(pushed: false, warnings: [])
        }), git: GitService(), credentials: InMemoryCredentialStore(), root: fixture.root,
            onResolutionStarted: runtime.beginConflictResolution)
        await resolution.loadAndReport(context: runtime.container.mainContext)
        XCTAssertEqual(resolutions, 0, "resolution cannot overlap the post-cycle read")
        release.signal()
        await cycle.value
        await resolution.loadAndReport(context: runtime.container.mainContext)
        XCTAssertEqual(resolutions, 1, "resolution works after the entire cycle callback completes")
    }

    func testOlderSuccessStillShowsNewerUnusableProbe() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let started = expectation(description: "cycle started")
        let release = DispatchSemaphore(value: 0)
        let probe = RuleProbe()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults("older-success"), paths: fixture.paths, gitUsabilityProbe: probe.run,
            coordinatorConfigure: { coordinator in
                await coordinator.configure(engine: StatusOrderEngine(operation: {
                    started.fulfill()
                    release.wait()
                    return .synced(pushed: false, warnings: [])
                }), git: GitService(), credentials: InMemoryCredentialStore(), root: fixture.root,
                    audit: SyncAudit(appSupport: fixture.support))
            })
        await runtime.bootstrapTask.value
        let cycle = Task { await runtime.syncModel.syncNowAndReport() }
        await fulfillment(of: [started], timeout: 2)
        probe.set { .developerToolsMissing }
        await runtime.refreshGitUsability()
        XCTAssertEqual(runtime.syncModel.state, .syncing)
        release.signal()
        await cycle.value
        XCTAssertEqual(runtime.gitUsability, .developerToolsMissing)
        XCTAssertEqual(runtime.syncModel.state, .error(try XCTUnwrap(GitUsability.developerToolsMissing.message)))
        XCTAssertNotNil(runtime.syncModel.lastSyncedAt)
    }

    func testConflictResolutionReleasesUnusableStateAndDeferredCheck() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let calls = RuleProbe()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults("resolution-recovery"), paths: fixture.paths, updateCheckOperation: { _ in
                _ = calls.run()
                let report = calls.count == 1
                    ? UpdateCheckReport(environmentError: GitError.unusable(.licenseNotAccepted),
                                        gitUsability: .licenseNotAccepted)
                    : UpdateCheckReport(reachedRemote: true, gitUsability: .usable)
                return RuntimeUpdateCheckResult(report: report, skills: [:])
            }, gitUsabilityProbe: { .licenseNotAccepted })
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesIfDue()
        await TestWait.until(failureMessage: "update check did not finish") { !runtime.updateCheckInFlight }
        XCTAssertEqual(calls.count, 1)
        runtime.syncModel.apply(.conflicted(["skills/example/SKILL.md"]))
        try runtime.beginConflictResolution()(.synced(pushed: true, warnings: [], completedAt: Date()))
        await TestWait.until(failureMessage: "update check did not finish") { !runtime.updateCheckInFlight }
        XCTAssertEqual(runtime.gitUsability, .usable)
        XCTAssertNil(runtime.syncModel.configurationError)
        XCTAssertEqual(calls.count, 2, "resolution recovery releases the automatic retry")
    }

    func testResolutionEvidenceCannotReplaceNewerUnusableProbe() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let probe = RuleProbe()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults("older-evidence"), paths: fixture.paths, gitUsabilityProbe: probe.run)
        await runtime.bootstrapTask.value
        let older = try runtime.beginConflictResolution()
        probe.set { .licenseNotAccepted }
        await runtime.refreshGitUsability()
        older(.synced(pushed: false, warnings: [], completedAt: Date()))
        XCTAssertEqual(runtime.gitUsability, .licenseNotAccepted)
        XCTAssertEqual(runtime.syncModel.state, .error(try XCTUnwrap(GitUsability.licenseNotAccepted.message)))
    }

}

private struct StatusOrderFailure: LocalizedError {
    var errorDescription: String? { "older cycle failed" }
}

struct StatusOrderEngine: SyncEngineProtocol {
    let operation: () throws -> SyncOutcome
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome { try operation() }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        .cleared(try operation())
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome { try operation() }
}
