import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension SyncCoordinatorTests {
    func assertRuntimeSyncPriorities() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let release = TestWait.Gate(owner: self)
        let engine = BlockingEngine(release: release)
        let scheduler = SyncScheduler(debounceSeconds: 0, startAutomatically: false,
                                      backgroundSyncEnabled: { true })
        let runtime = try AppRuntime(scheduler: scheduler, paths: fixture.paths, gitUsabilityProbe: { .usable },
                                     coordinatorConfigure: { coordinator in
            await coordinator.configure(engine: engine, credentials: InMemoryCredentialStore(), root: fixture.root,
                                        audit: SyncAudit(appSupport: fixture.support), machineIdentity: InertMachineIdentity(),
                                        machineStateService: InertMachineStateService())
        })
        await runtime.bootstrapTask.value
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
            if trigger.0 == "nudge" {
                await runtime.syncModel.syncNowAndReport()
                scheduler.tick()
                scheduler.wake()
            }
            release.open()
            if trigger.0 != "nudge" {
                await TestWait.until(failureMessage: "\(trigger.0) did not finish") { !scheduler.isSyncing }
            }
        }
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
        await manual.value
    }

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
