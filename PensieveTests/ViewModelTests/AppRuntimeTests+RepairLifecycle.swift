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
        for releasedBeforeRepair in 0...1 {
            for conflictFinishesFirst in [true, false] {
                try await checkOverlappingRepair(releasedBeforeRepair: releasedBeforeRepair,
                                                 conflictFinishesFirst: conflictFinishesFirst)
            }
        }
        try await checkAdvancedCycleRepairConvergence()
    }

    private func checkOverlappingRepair(releasedBeforeRepair: Int, conflictFinishesFirst: Bool) async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged at launch")
        let backfills = Counter(), convergence = RepairLifecycleConvergence()
        let runtime = try await launchRepairRuntime(h, backfills: backfills, convergence: convergence,
                                                   successfulCycle: true)
        defer { runtime.commandServer?.stop(); runtime.library.stopWatching() }
        let gates = RepairReadGates(owner: self)
        defer { gates.release(conflict: true); gates.release(conflict: false) }
        let cycle = try await holdOverlappingReads(h, runtime: runtime, gates: gates)
        if releasedBeforeRepair > 0 {
            await finishRepairOwner(conflictFirst: conflictFinishesFirst, gates: gates, cycle: cycle, runtime: runtime)
        }
        XCTAssertEqual(backfills.value, 0, "Damage still defers launch backfill")
        XCTAssertEqual(convergence.launches, 0)
        h.saves.requestRepair()
        await h.saves.replaceWithThisMac(context: h.context)
        XCTAssertFalse(h.saves.libraryDamaged)
        XCTAssertEqual(backfills.value, 0, "A suspended successful owner must still own launch backfill")
        XCTAssertEqual(convergence.launches, 0)
        let conflictNext = releasedBeforeRepair == 0 ? conflictFinishesFirst : !conflictFinishesFirst
        await finishRepairOwner(conflictFirst: conflictNext, gates: gates, cycle: cycle, runtime: runtime)
        XCTAssertEqual(backfills.value, 1, "The first released owner must backfill the repaired library")
        XCTAssertEqual(convergence.launches, 1, "The backfill owner must run launch convergence")
        gates.release(conflict: true); gates.release(conflict: false)
        await TestWait.until(failureMessage: "Both damage-read gates must drain before joining the cycle") {
            gates.conflict.waiterCount == 0 && gates.cycle.waiterCount == 0
        }
        XCTAssertEqual(gates.conflict.waiterCount, 0)
        XCTAssertEqual(gates.cycle.waiterCount, 0)
        let result = await cycle.value
        guard case let .synced(_, _, _, headAdvanced, _) = result else { return XCTFail("Expected a successful cycle") }
        XCTAssertFalse(headAdvanced, "The stub cycle must not advance HEAD")
        await waitForConflictCompletion(runtime)
        XCTAssertEqual(backfills.value, 1, "Local repair must retain the launch callback after overlapping outcomes")
        XCTAssertEqual(convergence.launches, 1)
        XCTAssertEqual(convergence.successfulCycles, 1, "Only the outcome that did not backfill runs ordinary convergence")
        await runtime.applyLibrarySyncOutcome(.noRemote)
        XCTAssertEqual(backfills.value, 1, "A later observation must not repeat the backfill")
        XCTAssertEqual(convergence.launches, 1)
    }

    private func checkAdvancedCycleRepairConvergence() async throws {
        for repairBeforeCycle in [true, false] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let healthy = try h.files.readFile(at: h.root + "/manifest/manifest.yaml")
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged at launch")
            let backfills = Counter(), convergence = RepairLifecycleConvergence(fixture: h)
            let runtime = try await launchRepairRuntime(h, backfills: backfills, convergence: convergence)
            defer { runtime.commandServer?.stop(); runtime.library.stopWatching() }
            await TestWait.until(failureMessage: "Launch damage read must finish before the advanced outcome") {
                h.saves.damage != nil && h.saves.damageRefreshTask == nil
            }
            if repairBeforeCycle { try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: healthy) }
            await runtime.applyLibrarySyncOutcome(.synced(pushed: false, warnings: [], completedAt: Date(), headAdvanced: true))
            if !repairBeforeCycle {
                XCTAssertEqual(backfills.value, 0)
                h.saves.requestRepair()
                await h.saves.replaceWithThisMac(context: h.context)
            }
            XCTAssertEqual(backfills.value, 1, "A finished successful owner must release local repair's launch callback")
            XCTAssertEqual(convergence.launches, 1)
            XCTAssertEqual(convergence.ledgerPasses, repairBeforeCycle ? 1 : 2,
                           "Advanced backfill runs one ledger pass; an earlier completed cycle has its own pass")
        }
    }

    private func holdOverlappingReads(_ h: ManifestSaveFixture, runtime: AppRuntime,
                                      gates: RepairReadGates) async throws -> Task<SyncCycleResult, Never> {
        await TestWait.until(failureMessage: "Launch damage read must finish") {
            h.saves.damage != nil && h.saves.damageRefreshTask == nil
        }
        h.recording.afterReadFailure = { try gates.conflict.wait() }
        try runtime.beginConflictResolution()(.synced(pushed: false, warnings: [], completedAt: Date(), headAdvanced: false))
        await TestWait.until(failureMessage: "Conflict completion must hold its damage read") { gates.conflict.waiterCount == 1 }
        h.recording.afterReadFailure = { try gates.cycle.wait() }
        let cycle = Task { await runtime.syncModel.syncCycleForCommand() }
        await TestWait.until(failureMessage: "A successful cycle must overlap conflict completion") {
            gates.cycle.waiterCount == 2
        }
        h.recording.afterReadFailure = nil
        // A later damage observation settles while both successful reads stay held. Each owner
        // can then finish independently, so the chosen release order is also its completion order.
        await runtime.applyLibrarySyncOutcome(.noRemote)
        return cycle
    }

    private func finishRepairOwner(conflictFirst: Bool, gates: RepairReadGates,
                                   cycle: Task<SyncCycleResult, Never>, runtime: AppRuntime) async {
        gates.release(conflict: conflictFirst)
        if conflictFirst { await waitForConflictCompletion(runtime) } else { _ = await cycle.value }
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
        let root = h.root, appSupportDir = paths.appSupportDir
        let model = successfulCycle ? SyncModel(git: IngestRecordingGit(), root: root) : nil
        let runtime = try AppRuntime(container: h.context.container, library: h.library, syncModel: model,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }), defaults: defaults,
            launchBackfill: { _ in backfills.increment() }, hasRemoteConfigured: { false },
            postSyncConvergence: convergence ?? RepairLifecycleConvergence(), launchIngestLockPath: h.lockPath, paths: paths,
            coordinatorConfigure: { coordinator in
                guard successfulCycle else { return }
                await coordinator.configure(engine: StatusOrderEngine(operation: { .synced(pushed: false, warnings: []) }),
                    git: TestPaths.git, credentials: InMemoryCredentialStore(), root: root,
                    audit: ConvergenceNullAudit(), machine: (identity: MachineIdentity(appSupportDir: appSupportDir),
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

    /// This host exposes neither an AX action nor a rendered Button/frame for the plain footer.
    /// Its caption plus vertical padding fits the bottom 32-point strip; keep fallback clicks
    /// there and stop as soon as the actual confirmation opens.
    private func pressRenderedRepair(in host: NSView, footerOnly: Bool = false,
                                     activated: () -> Bool) async throws {
        XCTAssertTrue(hasDamageLine(host), "Click only after the live damage line renders")
        let window = try XCTUnwrap(host.window)
        window.makeKey()
        let positions = footerOnly ? [host.bounds.midY] : Array(stride(from: 8.0, through: 32, by: 8))
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
    var successfulCycles = 0
    private let recorder = ConvergenceRecorder()
    private var delegate: PostSyncConvergence?
    var ledgerPasses: Int { recorder.events.filter { $0 == "category" }.count }

    init(fixture: ManifestSaveFixture? = nil) {
        guard let fixture else { return }
        let context = fixture.context
        delegate = PostSyncConvergence(root: fixture.root,
            deployReconciler: ConvergenceRecordingDeploy(recorder: recorder), contextFactory: { context },
            categoryReconciler: ConvergenceRecordingLedger(name: "category", recorder: recorder),
            intentReconciler: ConvergenceRecordingLedger(name: "intent", recorder: recorder), auditLog: { _, _ in })
    }

    func run(after result: SyncCycleResult) {
        if case .synced = result { successfulCycles += 1 }
        delegate?.run(after: result)
    }
    func runAfterLaunchIngest() { launches += 1; delegate?.runAfterLaunchIngest() }
}

/// Grants exactly the held reads: one conflict read and two cycle observations. Repeated
/// cleanup calls grant no extra permits; an unexpected later read still times out in TestWait.Gate.
@MainActor
private final class RepairReadGates {
    let conflict: TestWait.Gate
    let cycle: TestWait.Gate
    private var released: Set<Bool> = []

    init(owner: XCTestCase) {
        conflict = TestWait.Gate(owner: owner)
        cycle = TestWait.Gate(owner: owner)
    }

    func release(conflict isConflict: Bool) {
        guard released.insert(isConflict).inserted else { return }
        if isConflict { conflict.open() } else {
            // The verdict supersedes the old observation; the cycle also requests its own refresh.
            cycle.open()
            cycle.open()
        }
    }
}
