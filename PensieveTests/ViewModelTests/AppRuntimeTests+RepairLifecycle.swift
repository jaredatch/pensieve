import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

extension AppRuntimeTests {
    func testFirstSidebarRepairAfterDamagedLaunchNeedsNoTestRefresh() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged at launch")
        let runtime = try await launchRepairRuntime(h)
        defer { runtime.commandServer?.stop(); runtime.library.stopWatching() }
        // Observe launch completion before mounting the footer, whose own task could hide a missing launch read.
        await TestWait.until(failureMessage: "Launch must supply the first repair token without a window") {
            h.saves.damage != nil && h.saves.damageRefreshTask == nil
        }
        guard h.saves.damage != nil else { return }
        XCTAssertEqual(runtime.syncModel.state, .unconfigured)
        let window = hostMainWindow(runtime: runtime)
        defer { h.saves.cancelRepair(); window.contentView = nil; window.close() }
        let host = try XCTUnwrap(window.contentView)
        await TestWait.until(failureMessage: "The sidebar must show launch damage") { self.hasDamageLine(host) }
        try await pressRenderedRepair(in: host) { h.saves.showsRepairConfirmation }
        await TestWait.until(failureMessage: "Repair must present the confirmation") { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        sheet.animationBehavior = .none
        let buttons = PendingSaveTerminationTests.views(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }
        try XCTUnwrap(buttons.first { $0.title == "Replace" }).performClick(nil)
        await TestWait.until(failureMessage: "Replace must repair the library and dismiss confirmation") {
            !h.saves.libraryDamaged && window.attachedSheet == nil
        }
        XCTAssertNil(h.saves.repairError)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.map(\.name), ["Local", "ZDelete"])
        await TestWait.until(failureMessage: "The unconfigured sidebar must lose its repaired damage line") {
            !self.hasDamageLine(host)
        }
    }

    func testOverlappingConflictCompletionAndCycleKeepLocalRepairBackfill() async throws {
        for releasedBeforeRepair in 0...2 {
            for conflictFinishesFirst in [true, false] {
                for headAdvanced in [false, true] {
                    try await checkOverlappingRepair(releasedBeforeRepair: releasedBeforeRepair,
                        conflictFinishesFirst: conflictFinishesFirst, headAdvanced: headAdvanced)
                }
            }
        }
    }

    private func checkOverlappingRepair(releasedBeforeRepair: Int, conflictFinishesFirst: Bool,
                                        headAdvanced: Bool) async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged at launch")
        let backfills = Counter(), convergence = RepairLifecycleConvergence(fixture: h)
        let runtime = try await launchRepairRuntime(h, backfills: backfills, convergence: convergence,
                                                   successfulCycle: true)
        defer { runtime.commandServer?.stop(); runtime.library.stopWatching() }
        let conflict = TestWait.Gate(owner: self), cycleRead = TestWait.Gate(owner: self)
        defer { conflict.open(); releaseCycleReads(cycleRead) }
        let cycle = try await holdOverlappingReads(h, runtime: runtime, conflict: conflict,
                                                   cycleRead: cycleRead, headAdvanced: headAdvanced)
        if releasedBeforeRepair > 0 {
            await finishRepairOwner(conflictFirst: conflictFinishesFirst, conflict: conflict,
                                    cycleRead: cycleRead, cycle: cycle, runtime: runtime)
        }
        if releasedBeforeRepair == 2 {
            await finishRepairOwner(conflictFirst: !conflictFinishesFirst, conflict: conflict,
                                    cycleRead: cycleRead, cycle: cycle, runtime: runtime)
        }
        XCTAssertEqual(backfills.value, 0, "Damage still defers launch backfill")
        XCTAssertEqual(convergence.launches, 0)
        let ledgerPassesBeforeRepair = convergence.ledgerPasses
        h.saves.requestRepair()
        await h.saves.replaceWithThisMac(context: h.context)
        XCTAssertFalse(h.saves.libraryDamaged)
        if releasedBeforeRepair < 2 {
            XCTAssertEqual(backfills.value, 0, "A suspended successful owner must still own launch backfill")
            XCTAssertEqual(convergence.launches, 0)
            let conflictNext = releasedBeforeRepair == 0 ? conflictFinishesFirst : !conflictFinishesFirst
            await finishRepairOwner(conflictFirst: conflictNext, conflict: conflict,
                                    cycleRead: cycleRead, cycle: cycle, runtime: runtime)
            XCTAssertEqual(backfills.value, 1, "The first released owner must backfill the repaired library")
            XCTAssertEqual(convergence.launches, 1, "The backfill owner must run launch convergence")
            XCTAssertEqual(convergence.ledgerPasses, ledgerPassesBeforeRepair + 1,
                           "Launch backfill must force one ledger pass even without HEAD advancement")
        }
        conflict.open(); releaseCycleReads(cycleRead)
        await cycle.value
        await waitForConflictCompletion(runtime)
        XCTAssertEqual(backfills.value, 1, "Local repair must retain the launch callback after overlapping outcomes")
        XCTAssertEqual(convergence.launches, 1)
        let conflictOwnsBackfill = (releasedBeforeRepair == 0 && conflictFinishesFirst) ||
            (releasedBeforeRepair == 1 && !conflictFinishesFirst)
        let separateAdvancedCycle = headAdvanced && !conflictOwnsBackfill
        XCTAssertEqual(convergence.ledgerPasses, separateAdvancedCycle ? 2 : 1,
                       "A backfill outcome must not also run its ordinary ledger reconcilers")
        await runtime.applyLibrarySyncOutcome(.noRemote)
        XCTAssertEqual(backfills.value, 1, "A later observation must not repeat the backfill")
        XCTAssertEqual(convergence.launches, 1)
    }

    private func holdOverlappingReads(_ h: ManifestSaveFixture, runtime: AppRuntime, conflict: TestWait.Gate,
                                      cycleRead: TestWait.Gate, headAdvanced: Bool) async throws -> Task<Void, Never> {
        await TestWait.until(failureMessage: "Launch damage read must finish") {
            h.saves.damage != nil && h.saves.damageRefreshTask == nil
        }
        h.recording.afterReadFailure = { try conflict.wait() }
        try runtime.beginConflictResolution()(.synced(pushed: false, warnings: [], completedAt: Date(),
                                                      headAdvanced: headAdvanced))
        await TestWait.until(failureMessage: "Conflict completion must hold its damage read") { conflict.waiterCount == 1 }
        h.recording.afterReadFailure = { try cycleRead.wait() }
        let cycle = Task { await runtime.syncModel.syncNowAndReport() }
        await TestWait.until(failureMessage: "A successful cycle must overlap conflict completion") { cycleRead.waiterCount == 2 }
        h.recording.afterReadFailure = nil
        // A later damage observation settles while both successful reads stay held. Each owner
        // can then finish independently, so the chosen release order is also its completion order.
        await runtime.applyLibrarySyncOutcome(.noRemote)
        return cycle
    }

    private func finishRepairOwner(conflictFirst: Bool, conflict: TestWait.Gate, cycleRead: TestWait.Gate,
                                   cycle: Task<Void, Never>, runtime: AppRuntime) async {
        if conflictFirst {
            conflict.open()
            await waitForConflictCompletion(runtime)
        } else {
            releaseCycleReads(cycleRead)
            await cycle.value
        }
    }

    private func releaseCycleReads(_ gate: TestWait.Gate) {
        // The verdict supersedes the old observation; the cycle also requests its own refresh.
        gate.open()
        gate.open()
    }

    private func waitForConflictCompletion(_ runtime: AppRuntime) async {
        await TestWait.until(failureMessage: "Conflict completion must finish") { runtime.paths.syncSteps.pendingCount == 0 }
    }

    func testDamageLineAndRepairOfferFollowSyncOutcomesAndStateChanges() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let healthy = try h.files.readFile(at: h.root + "/manifest/manifest.yaml")
        let reads = Counter()
        h.recording.afterRead = { reads.increment() }
        let runtime = try await launchRepairRuntime(h)
        defer { runtime.commandServer?.stop(); runtime.library.stopWatching() }
        await TestWait.until(failureMessage: "The launch read must finish before the footer mounts") {
            reads.value > 0 && h.saves.damageRefreshTask == nil
        }
        let launchReads = reads.value
        // Keep the real footer mounted while testing state changes; no outcome accompanies them.
        runtime.syncModel.apply(.locked)
        let (window, host) = hostRepairFooter(runtime: runtime, saves: h.saves)
        defer { window.contentView = nil; window.close() }
        await TestWait.until(failureMessage: "The footer must finish its initial healthy read") {
            reads.value > launchReads && h.saves.requiresNewerVersion == false && h.saves.damageRefreshTask == nil
                && !RenderedViewTestSupport.values(in: host).isEmpty
        }
        XCTAssertFalse(h.saves.libraryDamaged)
        XCTAssertNil(h.saves.damage)
        XCTAssertFalse(hasDamageLine(host))
        for trigger in ["outcome", "state"] {
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged after \(trigger)")
            if trigger == "outcome" { await runtime.applyLibrarySyncOutcome(.noRemote) } else {
                runtime.syncModel.apply(.failed("State changed while disk is damaged"))
            }
            await TestWait.until(failureMessage: "\(trigger) must discover damage and render its repair action") {
                h.saves.libraryDamaged && h.saves.damage != nil && self.hasDamageLine(host)
            }
            guard h.saves.libraryDamaged, h.saves.damage != nil else { return }
            try await pressRenderedRepair(in: host, footerOnly: true) { h.saves.showsRepairConfirmation }
            await TestWait.until(failureMessage: "The rendered Repair action must open confirmation") {
                h.saves.showsRepairConfirmation
            }
            XCTAssertTrue(h.saves.showsRepairConfirmation)
            XCTAssertNotNil(h.saves.confirmedDamage)
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: healthy)
            if trigger == "outcome" { await runtime.applyLibrarySyncOutcome(.noRemote) } else {
                runtime.syncModel.apply(.failed("State changed after external repair"))
            }
            await TestWait.until(failureMessage: "\(trigger) must retire the externally repaired offer and damage line") {
                !h.saves.libraryDamaged && !h.saves.showsRepairConfirmation && h.saves.confirmedDamage == nil
                    && h.saves.damage == nil && !self.hasDamageLine(host)
            }
        }
    }

    private func hostRepairFooter(runtime: AppRuntime, saves: ManifestSaveModel) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(SyncStatusView(model: runtime.syncModel, saves: saves,
            onResolve: { XCTFail("Damage offers repair, not conflict resolution") }).modelContainer(runtime.container)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFront(nil)
        return (window, host)
    }

    private func launchRepairRuntime(_ h: ManifestSaveFixture, backfills: Counter = Counter(),
                                     convergence: PostSyncConverging? = nil,
                                     successfulCycle: Bool = false) async throws -> AppRuntime {
        let paths = AppRuntimePaths(storeRoot: h.root, appSupportDir: h.root + "/support")
        let defaults = try isolatedDefaults("repair-lifecycle")
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        defaults.set("off", forKey: UpdateCheckSchedule.frequencyKey)
        let runtime = try AppRuntime(container: h.context.container, library: h.library,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }), defaults: defaults,
            launchBackfill: { _ in backfills.increment() }, hasRemoteConfigured: { false },
            postSyncConvergence: convergence ?? RepairLifecycleConvergence(), launchIngestLockPath: h.lockPath, paths: paths,
            coordinatorConfigure: { coordinator in
                guard successfulCycle else { return }
                await coordinator.configure(engine: StatusOrderEngine(operation: { .synced(pushed: false, warnings: []) }),
                    git: TestPaths.git, credentials: InMemoryCredentialStore(), root: h.root,
                    audit: ConvergenceNullAudit(), machine: (identity: MachineIdentity(appSupportDir: paths.appSupportDir),
                                                           stateService: TestPaths.stateService))
            })
        await runtime.bootstrapTask.value
        await runtime.performLaunchWorkIfNeeded(context: h.context)
        XCTAssertTrue(runtime.launchWorkCompleted)
        return runtime
    }

    func hasDamageLine(_ host: NSView) -> Bool {
        RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
            .flatMap(RenderedViewTestSupport.strings).contains("Library file damaged")
    }

    /// This host gives the plain footer button no AX action or rendered Button value. Send
    /// real clicks in its bottom sidebar strip, stopping as soon as its confirmation opens.
    private func pressRenderedRepair(in host: NSView, footerOnly: Bool = false,
                                     activated: () -> Bool) async throws {
        XCTAssertTrue(hasDamageLine(host), "Click only after the live damage line renders")
        let window = try XCTUnwrap(host.window)
        window.makeKey()
        let positions = footerOnly ? [host.bounds.midY] : Array(stride(from: 8.0, through: 120, by: 8))
        for height in positions {
            let local = NSPoint(x: footerOnly ? host.bounds.midX : 80,
                                y: host.isFlipped ? host.bounds.maxY - height : height)
            let point = host.convert(local, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(10))
            if activated() { return }
        }
        XCTFail("Clicking the rendered footer must open its repair confirmation")
    }

}

@MainActor
private final class RepairLifecycleConvergence: PostSyncConverging {
    var launches = 0
    private let recorder = ConvergenceRecorder()
    private var delegate: PostSyncConvergence?
    var ledgerPasses: Int { recorder.events.filter { $0 == "category" }.count }

    init(fixture: ManifestSaveFixture? = nil) {
        guard let fixture else { return }
        delegate = PostSyncConvergence(root: fixture.root,
            deployReconciler: ConvergenceRecordingDeploy(recorder: recorder), contextFactory: { fixture.context },
            categoryReconciler: ConvergenceRecordingLedger(name: "category", recorder: recorder),
            intentReconciler: ConvergenceRecordingLedger(name: "intent", recorder: recorder), auditLog: { _, _ in })
    }

    func run(after result: SyncCycleResult) { delegate?.run(after: result) }
    func runAfterLaunchIngest() { launches += 1; delegate?.runAfterLaunchIngest() }
}
