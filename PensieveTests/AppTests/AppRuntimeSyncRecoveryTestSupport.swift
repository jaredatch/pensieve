import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension XCTestCase {
    @MainActor
    func makeSyncRecoveryHarness(outcomes: [Result<SyncOutcome, Error>] = [],
                                 probe: RuleProbe = RuleProbe(), initialProbeError: Error? = nil,
                                 debounceSeconds: TimeInterval = 0,
                                 updateCheckOperation: AppRuntime.UpdateCheckOperation? = nil,
                                 configurationGit: IngestRecordingGit? = nil) async throws -> RecoveryHarness {
        let fixture = try GitFailureFixture()
        var ready = false
        defer { if !ready { try? fixture.remove() } }
        try fixture.seedRepository()
        let release = TestWait.Gate(owner: self)
        let engine = RecoveryEngine(release: release, outcomes: outcomes)
        let preference = RecoveryPreference()
        let scheduler = SyncScheduler(debounceSeconds: debounceSeconds, startAutomatically: false,
                                      backgroundSyncEnabled: { preference.enabled })
        let errorLock = NSLock()
        var pendingInitialError = initialProbeError
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: fixture.files, baseDir: fixture.paths.skillsDir,
                storeRoot: fixture.paths.skillsDir),
            fileService: fixture.files, fileWatchService: RecordingWatcher(), manifestRoot: fixture.root,
            notifier: SyncStateNotifier.suppressed)
        let runtime = try AppRuntime(library: library,
            syncModel: configurationGit.map { SyncModel(git: $0, root: fixture.root) },
            scheduler: scheduler, defaults: isolatedDefaults(),
            launchBackfill: { _ in }, postSyncConvergence: RecoveryConvergence(), paths: fixture.paths,
            updateCheckOperation: updateCheckOperation,
            gitUsabilityProbe: {
                // Reserve the failure for this invocation before another probe can change the count.
                let failure = errorLock.withLock {
                    let failure = pendingInitialError
                    pendingInitialError = nil
                    return failure
                }
                let result = probe.run()
                if let failure { throw failure }
                return result
            }, coordinatorConfigure: { coordinator in
                await coordinator.configure(
                    engine: engine,
                    git: IngestRecordingGit(),
                    credentials: InMemoryCredentialStore(),
                    root: fixture.root,
                    audit: IngestNullAudit(),
                    machine: (identity: MachineIdentity(appSupportDir: TestPaths.appSupportDir),
                        stateService: TestPaths.stateService)
                )
            })
        await runtime.bootstrapTask.value
        let h = RecoveryHarness(fixture: fixture, runtime: runtime, engine: engine,
                                release: release, preference: preference, probe: probe)
        addTeardownBlock { @MainActor in await h.finish() }
        ready = true
        return h
    }
}

@MainActor
final class RecoveryPreference { var enabled = true }

@MainActor
final class RecoveryHarness {
    let fixture: GitFailureFixture
    let runtime: AppRuntime
    let engine: RecoveryEngine
    let release: TestWait.Gate
    let preference: RecoveryPreference
    let probe: RuleProbe
    private var removed = false

    init(fixture: GitFailureFixture, runtime: AppRuntime, engine: RecoveryEngine,
         release: TestWait.Gate, preference: RecoveryPreference, probe: RuleProbe) {
        self.fixture = fixture; self.runtime = runtime; self.engine = engine
        self.release = release; self.preference = preference; self.probe = probe
    }

    func waitForCycle(_ count: Int, timeout: Duration = .seconds(TestWait.timeoutSeconds)) async {
        await TestWait.until(timeout: timeout, failureMessage: "cycle \(count) did not block in the engine") {
            self.engine.count == count && self.release.waiterCount == 1
        }
    }

    func waitForFollowUpOrIdle(after count: Int = 1) async {
        await TestWait.until(failureMessage: "neither a follow-up nor completion arrived") {
            self.engine.count > count && self.release.waiterCount == 1
                || !self.runtime.syncModel.isCycleInFlight && !self.runtime.scheduler.isSyncing
        }
    }

    func waitForIdle() async {
        await TestWait.until(failureMessage: "runtime did not settle") {
            !self.runtime.syncModel.isCycleInFlight && !self.runtime.scheduler.isSyncing
        }
    }

    func waitForDrain() async {
        await TestWait.until(failureMessage: "scheduled request did not drain") {
            !self.runtime.scheduler.hasPendingTrigger && !self.runtime.scheduler.isSyncing
                && !self.runtime.syncModel.isCycleInFlight
        }
    }

    func recover() async {
        probe.set { .developerToolsMissing }
        await runtime.refreshGitUsability()
        probe.set { .usable }
        await runtime.refreshGitUsability()
        XCTAssertEqual(runtime.gitUsability, .usable)
    }

    func finish() async {
        guard !removed else { return }
        // Release unexpected cycles too, and never delete a store beneath a worker on a failing test.
        for _ in 0..<8 { release.open() }
        await waitForIdle()
        guard !runtime.syncModel.isCycleInFlight && !runtime.scheduler.isSyncing else { return }
        XCTAssertEqual(release.waiterCount, 0)
        runtime.library.stopWatching()
        try? fixture.remove()
        removed = true
    }
}

final class RecoveryEngine: SyncEngineProtocol {
    private let lock = NSLock()
    private let release: TestWait.Gate
    private let outcomes: [Result<SyncOutcome, Error>]
    private var recordedPriorities: [qos_class_t] = []
    var priorities: [qos_class_t] { lock.withLock { recordedPriorities } }
    var count: Int { priorities.count }

    init(release: TestWait.Gate, outcomes: [Result<SyncOutcome, Error>]) {
        self.release = release; self.outcomes = outcomes
    }

    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        let index = lock.withLock { recordedPriorities.append(qos_class_self()); return recordedPriorities.count - 1 }
        try release.wait()
        return try index < outcomes.count ? outcomes[index].get() : .synced(pushed: false, warnings: [])
    }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        .conflicts(ConflictSet(items: []))
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome { .noRemote }
}

@MainActor
final class RecoveryConvergence: PostSyncConverging {
    func run(after result: SyncCycleResult) {}
    func runAfterLaunchIngest() {}
}

// Shared recovery assertions live here to keep the owning test file within the lint limit.
extension AppRuntimeSyncRecoveryTests {
    func assertPrivilegedRequestsSurviveGitOutage() async throws {
        for scenario in ["queued manual", "idle manual", "preflight", "first manual", "first preflight"] {
            let outcomes: [Result<SyncOutcome, Error>] = scenario == "queued manual"
                ? [.failure(GitError.unusable(.developerToolsMissing))] : []
            let probe = RuleProbe()
            let firstAnswer = scenario.hasPrefix("first")
            let h = try await makeSyncRecoveryHarness(outcomes: outcomes, probe: probe,
                initialProbeError: firstAnswer ? GitError.outputReadFailed(detail: "bootstrap EIO") : nil)
            h.preference.enabled = scenario == "queued manual"
            h.runtime.scheduler.launchIngestCompleted()
            if scenario == "queued manual" { await h.waitForCycle(1) }
            h.preference.enabled = false
            if firstAnswer {
                XCTAssertNil(h.runtime.gitUsability)
            } else {
                h.probe.set { .developerToolsMissing }
                await h.runtime.refreshGitUsability()
            }
            if scenario.hasSuffix("preflight") {
                h.runtime.scheduler.enqueueLaunchPreflight()
            } else if scenario == "queued manual" {
                await h.runtime.syncModel.syncNowAndReport()
            } else {
                h.runtime.scheduler.enqueueManualTrigger()
            }
            if scenario == "queued manual" { h.release.open() }
            await h.waitForIdle()
            let before = h.engine.count
            h.probe.set { .usable }
            await h.runtime.refreshGitUsability()
            await h.waitForFollowUpOrIdle(after: before)
            XCTAssertEqual(h.engine.count, before + 1, scenario + " must retain its background-off bypass")
            if h.engine.count == before + 1 {
                XCTAssertEqual(h.engine.priorities.last,
                               scenario.hasSuffix("preflight") ? QOS_CLASS_DEFAULT : QOS_CLASS_USER_INITIATED)
                h.probe.set { .usable }
                h.release.open()
            }
            await h.finish()
            XCTAssertEqual(h.engine.count, before + 1)
        }
    }

    func assertRetryExpiresWithUsableEvidence() async throws {
        let h = try await makeSyncRecoveryHarness(outcomes: [
            .failure(GitError.repositoryUnreadable(path: "fixture", detail: "offline"))
        ])
        h.preference.enabled = false
        h.runtime.scheduler.launchIngestCompleted()
        let manual = Task { await h.runtime.syncModel.syncNowAndReport() }
        await h.waitForCycle(1)
        h.release.open()
        await manual.value
        await h.waitForIdle()
        await h.runtime.refreshGitUsability() // Usable evidence after the failed cycle answers its host question.
        await h.recover() // An unrelated later outage must not revive the failed manual request.
        await h.waitForFollowUpOrIdle()
        XCTAssertEqual(h.engine.count, 1, "usable evidence must retire an unrelated failed Sync Now")
        await h.finish()
        XCTAssertEqual(h.engine.count, 1)
    }
}
