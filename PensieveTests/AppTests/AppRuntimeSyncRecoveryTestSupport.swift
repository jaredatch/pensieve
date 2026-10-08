import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension AppRuntimeSyncRecoveryTests {
    func makeHarness(outcomes: [Result<SyncOutcome, Error>] = []) async throws -> RecoveryHarness {
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
