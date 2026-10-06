import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeGitRulesTests: XCTestCase {
    func testConfigurationOnlyRefreshCannotDiscardRealProbe() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let probe = RuleProbe()
        let runtime = try AppRuntime(scheduler: SyncScheduler(startAutomatically: false),
                                     defaults: isolatedDefaults(), paths: fixture.paths, gitUsabilityProbe: probe.run)
        await runtime.bootstrapTask.value
        let started = expectation(description: "real probe started")
        let release = DispatchSemaphore(value: 0)
        probe.set { started.fulfill(); release.wait(); return .licenseNotAccepted }
        let real = Task { await runtime.refreshGitUsability() }
        await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
        await runtime.refreshGitConfiguration(probingGit: false)
        release.signal()
        await real.value
        XCTAssertEqual(runtime.gitUsability, .licenseNotAccepted)
        XCTAssertEqual(runtime.syncModel.configurationError, GitUsability.licenseNotAccepted.message)
        XCTAssertFalse(runtime.syncModel.canConnect)
    }

    func testSuccessfulSyncIsUsabilityEvidenceWithoutAnotherProbe() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let probe = RuleProbe()
        probe.set { .licenseNotAccepted }
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults(),
            paths: fixture.paths, gitUsabilityProbe: probe.run,
            coordinatorConfigure: { coordinator in
                await coordinator.configure(engine: RecoveredPresentationEngine(), git: GitService(),
                                            credentials: InMemoryCredentialStore(), root: fixture.root,
                                            audit: SyncAudit(appSupport: fixture.support))
            }
        )
        await runtime.bootstrapTask.value
        await runtime.syncModel.syncNowAndReport()
        XCTAssertEqual(runtime.gitUsability, .usable)
        XCTAssertNil(runtime.syncModel.configurationError)
        XCTAssertEqual(probe.count, 1, "the successful operation supplies evidence without a redundant version probe")
    }

    func testSuccessfulPreflightIsEvidenceWhenCycleStopsAfterGit() async throws {
        for (index, failure) in [SyncError.syncInProgress, .storeUnreadable(["fixture store failure"])].enumerated() {
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            try fixture.seedRepository()
            let probe = RuleProbe()
            probe.set { .licenseNotAccepted }
            let runtime = try AppRuntime(
                scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults("preflight-\(index)"),
                paths: fixture.paths, gitUsabilityProbe: probe.run,
                coordinatorConfigure: { coordinator in
                    await coordinator.configure(engine: StoppedRuleEngine(failure: failure), git: GitService(),
                                                credentials: InMemoryCredentialStore(), root: fixture.root,
                                                audit: SyncAudit(appSupport: fixture.support))
                }
            )
            await runtime.bootstrapTask.value
            await runtime.syncModel.syncNowAndReport()
            XCTAssertEqual(runtime.gitUsability, .usable)
            XCTAssertNil(runtime.syncModel.configurationError)
            XCTAssertEqual(probe.count, 1)
        }
    }

    func testUpdateEvidenceClearsCachedUnusableStateAndReleasesDeferral() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let defaults = try isolatedDefaults()
        let calls = RuleProbe()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: defaults, paths: fixture.paths,
            updateCheckOperation: { _ in
                let attempt = calls.run()
                let report = attempt == .licenseNotAccepted
                    ? UpdateCheckReport(
                        environmentError: GitError.unusable(.licenseNotAccepted), gitUsability: .licenseNotAccepted
                    )
                    : UpdateCheckReport(reachedRemote: true, gitUsability: .usable)
                return RuntimeUpdateCheckResult(report: report, skills: [:])
            }, gitUsabilityProbe: { .licenseNotAccepted }
        )
        calls.set { .licenseNotAccepted }
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        calls.set { .usable }
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        XCTAssertEqual(runtime.gitUsability, .usable)
        defaults.set(0, forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 3)
    }

    func testPassedUpdatePreflightIsUsabilityEvidenceEvenWhenOffline() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults(), paths: fixture.paths,
            updateCheckOperation: { _ in
                RuntimeUpdateCheckResult(report: UpdateCheckReport(
                    environmentError: SkillInstallError.networkUnavailable, gitUsability: .usable
                ), skills: [:])
            }, gitUsabilityProbe: { .licenseNotAccepted }
        )
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        XCTAssertEqual(runtime.gitUsability, .usable)
        XCTAssertEqual(runtime.updateCheckError, SkillInstallError.networkUnavailable.localizedDescription)
    }

    func testUpdateEvidenceRefreshesConfigurationWithoutScheduledSync() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let remote = try GitService().remoteURL(at: fixture.root)
        XCTAssertNotNil(remote)
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }), defaults: isolatedDefaults(),
            paths: fixture.paths,
            updateCheckOperation: { _ in
                RuntimeUpdateCheckResult(report: UpdateCheckReport(reachedRemote: true, gitUsability: .usable), skills: [:])
            }, gitUsabilityProbe: { .licenseNotAccepted }
        )
        await runtime.bootstrapTask.value
        XCTAssertNotNil(runtime.syncModel.configurationError)
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        XCTAssertEqual(runtime.gitUsability, .usable)
        XCTAssertNil(runtime.syncModel.configurationError)
        XCTAssertEqual(runtime.syncModel.remoteURL, remote)
        XCTAssertEqual(runtime.syncModel.configurationDescription, remote)
        XCTAssertFalse(runtime.syncModel.canConnect)
    }

    private func finished(_ runtime: AppRuntime) async {
        await TestWait.until(failureMessage: "update check did not finish") { !runtime.updateCheckInFlight }
    }
}

/// The closures run on detached tasks. The lock protects both the mutable operation and its call count.
final class RuleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: () -> GitUsability = { .usable }
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func set(_ operation: @escaping () -> GitUsability) { lock.withLock { self.operation = operation } }
    func run() -> GitUsability {
        let operation = lock.withLock { calls += 1; return self.operation }
        return operation()
    }
}

private struct StoppedRuleEngine: SyncEngineProtocol {
    let failure: SyncError
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome { throw failure }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        .conflicts(ConflictSet(items: []))
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome { throw failure }
}
