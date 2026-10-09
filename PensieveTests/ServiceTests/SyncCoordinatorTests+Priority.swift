import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension SyncCoordinatorTests {
    func testRuntimeSyncPriorities() async throws {
        let fixture = try GitFailureFixture()
        var cleanupRegistered = false
        defer { if !cleanupRegistered { try? fixture.remove() } }
        try fixture.seedRepository()
        let release = TestWait.Gate(owner: self)
        let engine = BlockingEngine(release: release)
        let scheduler = SyncScheduler(debounceSeconds: 0, startAutomatically: false,
                                      backgroundSyncEnabled: { true })
        let watcher = RecordingWatcher()
        let notifications = Counter()
        let library = priorityLibrary(fixture, watcher: watcher, notifier: notifications.notify)
        let runtime = try AppRuntime(library: library, scheduler: scheduler,
                                     launchBackfill: { _ in }, postSyncConvergence: PriorityConvergence(),
                                     paths: fixture.paths, gitUsabilityProbe: { .usable },
                                     coordinatorConfigure: { coordinator in
            await coordinator.configure(
                engine: engine,
                git: TestPaths.git,
                credentials: InMemoryCredentialStore(),
                root: fixture.root,
                audit: SyncAudit(appSupport: fixture.support),
                machine: (identity: InertMachineIdentity(), stateService: InertMachineStateService())
            )
        })
        registerPriorityCleanup(fixture: fixture, runtime: runtime, release: release)
        cleanupRegistered = true
        await runtime.bootstrapTask.value
        library.startWatching()
        try await assertScheduledPriorities(runtime: runtime, fixture: fixture, engine: engine, release: release,
                                            watcher: watcher, notifications: notifications)
    }

    private func assertScheduledPriorities(runtime: AppRuntime, fixture: GitFailureFixture,
                                           engine: BlockingEngine, release: TestWait.Gate,
                                           watcher: RecordingWatcher, notifications: Counter) async throws {
        let scheduler = runtime.scheduler
        let triggers: [(String, () -> Void)] = [
            ("startup", { scheduler.launchIngestCompleted() }),
            ("tick", { scheduler.tick() }),
            ("wake", { scheduler.wake() }),
            ("nudge", { scheduler.nudge() })
        ]
        for (index, trigger) in triggers.enumerated() {
            trigger.1()
            await TestWait.until(failureMessage: "\(trigger.0) did not enter the engine") {
                engine.qosClasses.count == index + 1 && release.waiterCount == 1
            }
            XCTAssertEqual(engine.qosClasses.last, QOS_CLASS_DEFAULT, "\(trigger.0) must retain default QoS")
            if trigger.0 == "startup" {
                try fixture.files.writeFile(at: fixture.root + "/skills/example/SKILL.md", content: "changed during sync\n")
                watcher.emit("example")
                XCTAssertEqual(runtime.library.folderChangeRevisions["example"], 1, "watcher must deliver the store edit")
            }
            if trigger.0 == "nudge" {
                await runtime.syncModel.syncNowAndReport()
                scheduler.tick()
                scheduler.wake()
            }
            release.open()
            if trigger.0 == "startup" {
                await assertIncidentalNotificationDoesNotStartCycle(runtime: runtime, engine: engine,
                                                                    notifications: notifications)
                guard engine.qosClasses.count == 1 else { return }
            } else if trigger.0 != "nudge" {
                await TestWait.until(failureMessage: "\(trigger.0) did not finish") { !scheduler.isSyncing }
            }
        }
        await assertManualPriorities(runtime: runtime, engine: engine, release: release)
    }

    private func assertIncidentalNotificationDoesNotStartCycle(
        runtime: AppRuntime, engine: BlockingEngine, notifications: Counter
    ) async {
        await TestWait.until(failureMessage: "startup did not settle") {
            engine.qosClasses.count > 1 || !runtime.scheduler.isSyncing
        }
        XCTAssertEqual(notifications.value, 1, "the watcher edit must produce an incidental store notification")
        let extraCycle = expectation(description: "incidental notification starts a fixture cycle")
        extraCycle.isInverted = true
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                if engine.qosClasses.count > 1 { extraCycle.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [extraCycle], timeout: 1) // upper-bound: Observe queued zero-delay nudges after startup finishes.
        monitor.cancel()
        await monitor.value
        XCTAssertEqual(engine.qosClasses.count, 1, "incidental store notification must not add a fixture cycle")
    }

    private func assertManualPriorities(runtime: AppRuntime, engine: BlockingEngine, release: TestWait.Gate) async {
        let scheduler = runtime.scheduler
        await TestWait.until(failureMessage: "queued Sync Now did not enter the engine") {
            engine.qosClasses.count == 5 && release.waiterCount == 1
        }
        XCTAssertEqual(engine.qosClasses.last, QOS_CLASS_USER_INITIATED, "queued Sync Now must retain manual priority")
        release.open()
        await TestWait.until(failureMessage: "queued Sync Now did not finish") { !scheduler.isSyncing }
        XCTAssertFalse(scheduler.hasPendingTrigger, "the manual follow-up must absorb the background requests")
        let manual = Task(priority: .userInitiated) { await runtime.syncModel.syncNowAndReport() }
        await TestWait.until(failureMessage: "Sync Now did not enter the engine") {
            engine.qosClasses.count == 6 && release.waiterCount == 1
        }
        XCTAssertEqual(engine.qosClasses.last, QOS_CLASS_USER_INITIATED, "Sync Now must retain its caller's priority")
        release.open()
        await TestWait.forTask(manual, failureMessage: "Sync Now did not finish post-cycle work")
        await TestWait.until(failureMessage: "runtime must be idle before fixture cleanup") {
            self.priorityRuntimeIsIdle(runtime)
        }
        XCTAssertEqual(engine.qosClasses.count, 6)
    }

    func testForcedLaunchPreflightKeepsDefaultPriority() async throws {
        for quarantined in [true, false] {
            let fixture = try GitFailureFixture()
            var cleanupRegistered = false
            defer { if !cleanupRegistered { try? fixture.remove() } }
            try fixture.seedRepository()
            let release = TestWait.Gate(owner: self)
            let engine = BlockingEngine(release: release)
            let scheduler = SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false })
            var backfills = 0
            let runtime = try AppRuntime(library: priorityLibrary(fixture), scheduler: scheduler,
                launchReconcile: { _, _ in
                    LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false,
                                           ingestedHeadStamp: nil, quarantined: quarantined)
                },
                launchBackfill: { _ in backfills += 1 }, hasRemoteConfigured: { true },
                postSyncConvergence: PriorityConvergence(), paths: fixture.paths, gitUsabilityProbe: { .usable },
                coordinatorConfigure: { coordinator in
                    await coordinator.configure(
                        engine: engine,
                        git: TestPaths.git,
                        credentials: InMemoryCredentialStore(),
                        root: fixture.root,
                        audit: SyncAudit(appSupport: fixture.support),
                        machine: (identity: InertMachineIdentity(), stateService: InertMachineStateService())
                    )
                })
            registerPriorityCleanup(fixture: fixture, runtime: runtime, release: release)
            cleanupRegistered = true
            await runtime.bootstrapTask.value
            runtime.performLaunchWorkIfNeeded(context: runtime.container.mainContext)
            await TestWait.until(failureMessage: "forced launch preflight did not enter the engine") {
                engine.qosClasses.count == 1 && release.waiterCount == 1
            }
            XCTAssertEqual(engine.qosClasses.last, QOS_CLASS_DEFAULT,
                           "forced preflight must use default QoS (quarantined: \(quarantined))")
            release.open()
            await TestWait.until(failureMessage: "forced launch preflight did not finish") {
                self.priorityRuntimeIsIdle(runtime)
            }
            XCTAssertEqual(engine.qosClasses.count, 1)
            XCTAssertEqual(backfills, 1)
            runtime.library.stopWatching()
        }
    }

    private func priorityLibrary(_ fixture: GitFailureFixture, watcher: RecordingWatcher = RecordingWatcher(),
                                 notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed) -> SkillLibraryViewModel {
        SkillLibraryViewModel(skillStore: SkillStore(fileService: fixture.files, baseDir: fixture.paths.skillsDir,
            storeRoot: fixture.paths.skillsDir),
                              fileService: fixture.files, fileWatchService: watcher, manifestRoot: fixture.root,
                              notifier: notifier)
    }

    private func priorityRuntimeIsIdle(_ runtime: AppRuntime) -> Bool {
        !runtime.syncModel.isCycleInFlight && !runtime.scheduler.isSyncing && !runtime.scheduler.hasPendingTrigger
    }

    private func registerPriorityCleanup(fixture: GitFailureFixture, runtime: AppRuntime, release: TestWait.Gate) {
        addTeardownBlock { @MainActor in
            release.open()
            await TestWait.until(failureMessage: "priority fixture still has runtime work") {
                self.priorityRuntimeIsIdle(runtime)
            }
            runtime.library.stopWatching()
            // On a failure, retain the store until the test host exits instead of deleting under a worker.
            guard self.priorityRuntimeIsIdle(runtime) else { return }
            try fixture.remove()
        }
    }
}

@MainActor
private final class PriorityConvergence: PostSyncConverging {
    func run(after result: SyncCycleResult) {}
    func runAfterLaunchIngest() {}
}

final class BlockingEngine: SyncEngineProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private let release: TestWait.Gate?
    private var recordedFinishedAt: Date?
    private var recordedQoSClasses: [qos_class_t] = []
    init(release: TestWait.Gate? = nil) { self.release = release }
    var qosClass: qos_class_t? { qosClasses.last }
    var qosClasses: [qos_class_t] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedQoSClasses
    }
    var finishedAt: Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedFinishedAt
    }
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        stateLock.lock()
        recordedQoSClasses.append(qos_class_self())
        stateLock.unlock()
        try prepare?(context)
        if let release {
            try release.wait()
        } else {
            Thread.sleep(forTimeInterval: 0.3)
        }
        stateLock.lock()
        recordedFinishedAt = Date()
        stateLock.unlock()
        return .synced(pushed: false, warnings: [])
    }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        fatalError("unused")
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome {
        fatalError("unused")
    }
}
