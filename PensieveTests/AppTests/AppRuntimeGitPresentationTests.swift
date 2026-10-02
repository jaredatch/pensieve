import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeGitPresentationTests: XCTestCase {
    func testOpenSettingsAndSyncStatusRecoverWithoutReappearing() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let probe = PresentationProbe()
        let runtime = try makeRuntime(fixture, probe: probe)
        await runtime.bootstrapTask.value
        XCTAssertEqual(runtime.syncModel.remoteURL, "https://fixture.test/store.git")
        XCTAssertNil(runtime.syncModel.configurationError)
        XCTAssertEqual(runtime.syncModel.state, .idle)
        let syncedAt = Date(timeIntervalSince1970: 100)
        runtime.syncModel.apply(.synced(pushed: false, warnings: [], completedAt: syncedAt))
        for failure in [GitUsability.licenseNotAccepted, .developerToolsMissing] {
            probe.set { failure }
            await runtime.refreshGitUsability()
            XCTAssertEqual(runtime.gitUsability, failure)
            XCTAssertEqual(runtime.syncModel.configurationError, failure.message)
            XCTAssertEqual(runtime.syncModel.state, .error(failure.message ?? ""))
            let footer = SyncFooterPresentation.make(state: runtime.syncModel.state,
                canResolve: runtime.syncModel.canResolve, hovering: false, now: Date())
            XCTAssertEqual(footer?.help, failure.message)
            XCTAssertEqual(footer?.label, "Sync failed")
            probe.set { .usable }
            await runtime.refreshGitUsability()
            XCTAssertNil(runtime.syncModel.configurationError)
            XCTAssertEqual(runtime.syncModel.remoteURL, "https://fixture.test/store.git")
            XCTAssertEqual(runtime.syncModel.state, .synced(at: syncedAt))
        }
        try GitService().removeRemote(at: fixture.root)
        await runtime.refreshGitUsability()
        XCTAssertNil(runtime.syncModel.remoteURL)
        XCTAssertNil(runtime.syncModel.configurationError)
        XCTAssertEqual(runtime.syncModel.state, .unconfigured)
    }

    func testUnusableStatePreservesSyncAndConflictAndPausesScheduler() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let probe = PresentationProbe()
        let runtime = try makeRuntime(fixture, probe: probe)
        await runtime.bootstrapTask.value
        var cycles = 0
        runtime.syncModel.installSyncRequest { cycles += 1; runtime.syncModel.apply(.locked) }
        runtime.syncModel.apply(.conflicted(["skills/example/SKILL.md"]))
        runtime.scheduler.launchIngestCompleted()
        probe.set { .developerToolsMissing }
        await runtime.refreshGitUsability()
        XCTAssertTrue(runtime.syncModel.isConflicted)
        runtime.scheduler.tick()
        await Task.yield()
        XCTAssertEqual(cycles, 0)
        probe.set { .usable }
        await runtime.refreshGitUsability()
        runtime.scheduler.tick()
        await Task.yield()
        XCTAssertTrue(runtime.syncModel.isConflicted)
        XCTAssertEqual(cycles, 0, "recovery must not sync over a conflict")
        runtime.syncModel.clearConflict()
        probe.set { .developerToolsMissing }
        await runtime.refreshGitUsability()
        runtime.scheduler.tick()
        await Task.yield()
        XCTAssertEqual(cycles, 0, "a known host failure must not repeatedly launch the shim")
        probe.set { .usable }
        await runtime.refreshGitUsability()
        await TestWait.until(failureMessage: "recovery did not resume scheduling") { cycles == 1 }
        runtime.syncModel.installSyncRequest {
            probe.set { .licenseNotAccepted }
            await runtime.refreshGitUsability()
            XCTAssertEqual(runtime.syncModel.state, .syncing)
            runtime.syncModel.apply(.locked)
        }
        await runtime.syncModel.syncNowAndReport()
        XCTAssertEqual(runtime.syncModel.state, .error(GitUsability.licenseNotAccepted.message ?? ""))
    }

    func testOlderProbeCannotReplaceNewerAppliedResult() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let probe = PresentationProbe()
        let runtime = try makeRuntime(fixture, probe: probe)
        await runtime.bootstrapTask.value
        for older in [GitUsability.licenseNotAccepted, .usable] {
            let started = expectation(description: "older probe started")
            let release = DispatchSemaphore(value: 0)
            probe.set {
                started.fulfill()
                release.wait()
                return older
            }
            let oldTask = Task { await runtime.refreshGitUsability() }
            await fulfillment(of: [started], timeout: 2)
            let newer: GitUsability = older == .usable ? .developerToolsMissing : .usable
            probe.set { newer }
            await runtime.refreshGitUsability()
            release.signal()
            await oldTask.value
            XCTAssertEqual(runtime.gitUsability, newer)
            XCTAssertEqual(runtime.syncModel.configurationError, newer.message)
            XCTAssertEqual(runtime.syncModel.state, newer == .usable ? .idle : .error(newer.message ?? ""))
        }
    }

    func testUnreadableRepositoryAndMissingStoreHavePlainSettingsErrors() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let runtime = try makeRuntime(fixture, probe: PresentationProbe())
        await runtime.bootstrapTask.value
        try fixture.files.deleteFile(at: fixture.root + "/.git/HEAD")
        await runtime.refreshGitUsability()
        XCTAssertTrue(runtime.syncModel.configurationError?.contains("Couldn’t read the store’s git repository") == true)
        XCTAssertNotEqual(runtime.syncModel.state, .unconfigured)
        try fixture.files.deleteDirectory(at: fixture.root)
        await runtime.refreshGitUsability()
        XCTAssertTrue(runtime.syncModel.configurationError?.contains("store folder can't be found") == true)
        XCTAssertFalse(runtime.syncModel.configurationError?.contains("couldn’t be opened") == true)
        XCTAssertNotEqual(runtime.syncModel.state, .unconfigured)
        let daemon = SyncDaemon(root: fixture.root, appSupport: fixture.support, git: GitService(),
                                credentials: InMemoryCredentialStore(), reconciler: NoPresentationReconciler(), now: Date.init)
        XCTAssertTrue(daemon.runOnce().detail.contains("store folder can't be found"))
    }

    func testConnectFailureNamesGitAndFixWithoutRawExitText() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        for state in [GitUsability.licenseNotAccepted, .developerToolsMissing] {
            let git = try fixture.broken(state)
            let model = SyncSetupModel(context: container.mainContext, git: git,
                                       credentials: InMemoryCredentialStore(), root: fixture.root,
                                       lockPath: fixture.support + "/sync.lock")
            await model.connectAndReport(url: "git@example.com:skills.git", username: "", token: "")
            guard case let .failed(message) = model.state else { return XCTFail("expected connect error") }
            XCTAssertEqual(message, state.message)
            XCTAssertFalse(message.contains("failed (exit"))
        }
    }

    func testMidConnectCloneFailureConfirmsGitAndNamesTheFix() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        // A non-scaffold empty store selects clone after the successful preflight.
        try fixture.files.writeFile(at: fixture.root + "/keep.txt", content: "fixture")
        let git = try fixture.executable("""
        if [ "$1" = clone ]; then touch '\(fixture.failureSwitch)'; fi
        if [ -f '\(fixture.failureSwitch)' ]; then
          echo 'You have not agreed to the Xcode license.' >&2
          exit 69
        fi
        exec /usr/bin/git "$@"
        """)
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = SyncSetupModel(context: container.mainContext, git: git,
            credentials: InMemoryCredentialStore(), root: fixture.root, lockPath: fixture.support + "/sync.lock")
        await model.connectAndReport(url: "git@example.com:skills.git", username: "", token: "")
        XCTAssertEqual(model.state, .failed(GitUsability.licenseNotAccepted.message ?? ""))
        let calls = try fixture.files.readFile(at: fixture.trace).split(separator: "\n")
        XCTAssertEqual(calls.filter { $0 == "--version" }.count, 2, "one preflight and one confirming probe")
        XCTAssertTrue(calls.contains { $0.hasPrefix("clone ") })
    }

    func testSuccessfulManualSyncReprobesPreviouslyUnusableGit() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let probe = PresentationProbe()
        probe.set { .licenseNotAccepted }
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults(), paths: fixture.paths, gitUsabilityProbe: probe.run,
            coordinatorConfigure: { coordinator in
                await coordinator.configure(engine: RecoveredPresentationEngine(), git: GitService(),
                                            credentials: InMemoryCredentialStore(), root: fixture.root,
                                            audit: SyncAudit(appSupport: fixture.support))
            }
        )
        await runtime.bootstrapTask.value
        XCTAssertEqual(runtime.gitUsability, .licenseNotAccepted)
        probe.set { .usable }
        await runtime.syncModel.syncNowAndReport()
        XCTAssertEqual(runtime.gitUsability, .usable)
        XCTAssertNil(runtime.syncModel.configurationError)
        guard case .synced = runtime.syncModel.state else { return XCTFail("manual recovery must show synced") }
    }

    private func makeRuntime(_ fixture: GitFailureFixture, probe: PresentationProbe) throws -> AppRuntime {
        try AppRuntime(scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { true }),
                       defaults: isolatedDefaults(), paths: fixture.paths, gitUsabilityProbe: probe.run)
    }
}

/// The probe crosses detached tasks; only the locked closure is shared, never actor-owned test state.
private final class PresentationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: () -> GitUsability = { .usable }
    func set(_ operation: @escaping () -> GitUsability) {
        lock.lock()
        self.operation = operation
        lock.unlock()
    }
    func run() -> GitUsability {
        XCTAssertFalse(Thread.isMainThread)
        lock.lock()
        let operation = operation
        lock.unlock()
        return operation()
    }
}

private struct NoPresentationReconciler: DeployReconciling {
    func reconcile(root: String) throws -> ReconcileOutcome {
        XCTFail("unknown repository must not reconcile")
        return ReconcileOutcome()
    }
}

/// The coordinator still reads the real temporary repository; this engine avoids network and store writes.
struct RecoveredPresentationEngine: SyncEngineProtocol {
    var finish: (() throws -> Void)?
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        try finish?()
        return .synced(pushed: false, warnings: [])
    }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        .conflicts(ConflictSet(items: []))
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome { .synced(pushed: false, warnings: []) }
}
