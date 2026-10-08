import Darwin
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeSyncRecoveryTests: XCTestCase {
    func testRecoveryDuringCycleQueuesCatchUpForEligibleOutcomes() async throws {
        let outcomes: [Result<SyncOutcome, Error>] = [
            .success(.synced(pushed: false, warnings: [])), .success(.noRemote),
            .failure(SyncError.syncInProgress), .failure(SyncError.storeUnreadable([])),
            .failure(GitError.unusable(.developerToolsMissing)),
            .success(.conflicted(["skills/example/SKILL.md"])), .success(.branchless)
        ]
        for (index, outcome) in outcomes.enumerated() {
            let h = try await makeHarness(outcomes: [outcome])
            h.runtime.scheduler.launchIngestCompleted()
            await h.waitForCycle(1)
            if index == outcomes.count - 1 {
                try h.fixture.files.deleteFile(at: h.fixture.root + "/.git/refs/heads/main")
            }
            await h.recover()
            h.release.open()
            let shouldRetry = index < outcomes.count - 2
            await h.waitForFollowUpOrIdle()
            XCTAssertEqual(h.engine.count, shouldRetry ? 2 : 1, "outcome \(outcome)")
            if shouldRetry { h.release.open() }
            await h.finish()
            XCTAssertEqual(h.engine.count, shouldRetry ? 2 : 1, "no new recovery, no further cycle")
        }
    }

    func testQueuedRequestsAbsorbRecoveryAndRecoveryDuringCatchUpGetsOneMore() async throws {
        for queued in ["manual", "scheduled", "watcher", "none"] {
            let h = try await makeHarness()
            h.runtime.scheduler.launchIngestCompleted()
            await h.waitForCycle(1)
            switch queued {
            case "manual": await h.runtime.syncModel.syncNowAndReport()
            case "scheduled": h.runtime.scheduler.tick()
            case "watcher":
                h.runtime.scheduler.nudge()
                await TestWait.until(failureMessage: "watcher nudge was not queued") {
                    h.runtime.scheduler.hasPendingTrigger
                }
            default: break
            }
            await h.recover()
            h.release.open()
            await h.waitForFollowUpOrIdle()
            XCTAssertEqual(h.engine.count, 2, "\(queued) must absorb recovery into one cycle")
            if h.engine.count == 2 {
                await h.recover()
                h.release.open()
                await h.waitForFollowUpOrIdle(after: 2)
                XCTAssertEqual(h.engine.count, 3, "a new recovery during catch-up gets one more")
                h.release.open()
            }
            await h.finish()
            XCTAssertEqual(h.engine.count, 3, queued)
        }
    }

    func testRecoveryRetriesFailedManualSyncWithBackgroundOffButNotScheduledSync() async throws {
        let cases = [(true, false, true), (true, true, true), (true, false, false), (false, false, true)]
        for (manual, retryFails, unusableAtCompletion) in cases {
            let failure: GitError = unusableAtCompletion ? .unusable(.developerToolsMissing)
                : .repositoryUnreadable(path: "fixture", detail: "read failed")
            var outcomes: [Result<SyncOutcome, Error>] = [.failure(failure)]
            if retryFails { outcomes.append(.failure(GitError.unusable(.developerToolsMissing))) }
            let h = try await makeHarness(outcomes: outcomes)
            let cycle: Task<Void, Never>?
            if manual {
                h.preference.enabled = false
                h.runtime.scheduler.launchIngestCompleted()
                cycle = Task { await h.runtime.syncModel.syncNowAndReport() }
            } else {
                cycle = nil
                h.runtime.scheduler.launchIngestCompleted()
            }
            await h.waitForCycle(1)
            if unusableAtCompletion { h.probe.set { .developerToolsMissing } }
            h.release.open()
            await cycle?.value
            await h.waitForIdle()
            if !unusableAtCompletion {
                h.probe.set { .developerToolsMissing }
                await h.runtime.refreshGitUsability()
            }
            XCTAssertEqual(h.runtime.gitUsability, .developerToolsMissing)
            h.preference.enabled = false
            h.probe.set { .usable }
            await h.runtime.refreshGitUsability()
            await h.waitForFollowUpOrIdle()
            XCTAssertEqual(h.engine.count, manual ? 2 : 1)
            if manual {
                if retryFails { h.probe.set { .developerToolsMissing } }
                h.release.open()
                await h.waitForIdle()
                if retryFails {
                    h.probe.set { .usable }
                    await h.runtime.refreshGitUsability()
                    await h.waitForFollowUpOrIdle(after: 2)
                }
            }
            await h.finish()
            XCTAssertEqual(h.engine.count, manual ? 2 : 1, "one retry spends the manual request, even if it fails")
        }
    }

    func testQueuedPrivilegedRequestKeepsStandingWhenItMeetsDirectCycle() async throws {
        for preflight in [false, true] {
            let h = try await makeHarness()
            h.preference.enabled = false
            h.runtime.scheduler.launchIngestCompleted()
            let direct = Task { await h.runtime.syncModel.syncNowAndReport() }
            await h.waitForCycle(1)
            if preflight { h.runtime.scheduler.enqueueLaunchPreflight() } else { h.runtime.scheduler.enqueueManualTrigger() }
            await TestWait.until(failureMessage: "scheduler request did not return from the busy model") {
                !h.runtime.scheduler.isSyncing
            }
            h.release.open()
            await direct.value
            await h.waitForFollowUpOrIdle()
            XCTAssertEqual(h.engine.count, 2, "privileged request must survive background-off redispatch")
            if h.engine.count == 2 {
                XCTAssertEqual(h.engine.priorities.last,
                               preflight ? QOS_CLASS_DEFAULT : QOS_CLASS_USER_INITIATED)
                h.release.open()
            }
            await h.finish()
            XCTAssertEqual(h.engine.count, 2)
            h.runtime.scheduler.tick()
            XCTAssertFalse(h.runtime.scheduler.isSyncing, "the bypass must be spent")
        }
    }

    private func makeHarness(outcomes: [Result<SyncOutcome, Error>] = []) async throws -> RecoveryHarness {
        let fixture = try GitFailureFixture()
        var ready = false
        defer { if !ready { try? fixture.remove() } }
        try fixture.seedRepository()
        let release = TestWait.Gate(owner: self)
        let engine = RecoveryEngine(release: release, outcomes: outcomes)
        let preference = RecoveryPreference()
        let probe = RuleProbe()
        let scheduler = SyncScheduler(debounceSeconds: 0, startAutomatically: false,
                                      backgroundSyncEnabled: { preference.enabled })
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: fixture.files, baseDir: fixture.paths.skillsDir),
            fileService: fixture.files, fileWatchService: RecordingWatcher(), manifestRoot: fixture.root,
            notifier: SyncStateNotifier.suppressed)
        let runtime = try AppRuntime(library: library, scheduler: scheduler, defaults: isolatedDefaults(),
            launchBackfill: { _ in }, postSyncConvergence: RecoveryConvergence(), paths: fixture.paths,
            gitUsabilityProbe: probe.run, coordinatorConfigure: { coordinator in
                await coordinator.configure(engine: engine, git: IngestRecordingGit(),
                    credentials: InMemoryCredentialStore(), root: fixture.root, audit: IngestNullAudit())
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
private final class RecoveryPreference { var enabled = true }

@MainActor
private final class RecoveryHarness {
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

    func waitForCycle(_ count: Int) async {
        await TestWait.until(failureMessage: "cycle \(count) did not block in the engine") {
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

private final class RecoveryEngine: SyncEngineProtocol {
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
private final class RecoveryConvergence: PostSyncConverging {
    func run(after result: SyncCycleResult) {}
    func runAfterLaunchIngest() {}
}
