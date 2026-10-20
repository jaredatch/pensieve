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
        for firstReadFinishesFirst in [true, false] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged at launch")
            let backfills = Counter(), convergence = RepairLifecycleConvergence()
            let runtime = try await launchRepairRuntime(h, backfills: backfills, convergence: convergence)
            defer { runtime.commandServer?.stop(); runtime.library.stopWatching() }
            await TestWait.until(failureMessage: "Launch damage read must finish") {
                h.saves.damage != nil && h.saves.damageRefreshTask == nil
            }
            let first = TestWait.Gate(owner: self), second = TestWait.Gate(owner: self)
            defer { first.open(); second.open() }
            h.recording.afterReadFailure = { try first.wait() }
            try runtime.beginConflictResolution()(.synced(pushed: false, warnings: [], completedAt: Date()))
            await TestWait.until(failureMessage: "Conflict completion must hold its damage read") { first.waiterCount == 1 }
            h.recording.afterReadFailure = { try second.wait() }
            let cycle = Task { await runtime.syncModel.syncNowAndReport() }
            await TestWait.until(failureMessage: "The next cycle must overlap the conflict completion read") {
                second.waiterCount == 1
            }
            h.recording.afterReadFailure = nil
            if firstReadFinishesFirst {
                first.open()
                await TestWait.until(failureMessage: "First disk read must return while the second stays held") {
                    first.waiterCount == 0
                }
                second.open()
            } else {
                second.open()
                await cycle.value
                first.open()
            }
            await cycle.value
            await TestWait.until(failureMessage: "Conflict completion must finish") { runtime.paths.syncSteps.pendingCount == 0 }
            XCTAssertEqual(backfills.value, 0, "Damage still defers launch backfill")
            XCTAssertEqual(convergence.launches, 0)
            h.saves.requestRepair()
            await h.saves.replaceWithThisMac(context: h.context)
            XCTAssertEqual(backfills.value, 1, "Local repair must retain the launch callback after overlapping outcomes")
            XCTAssertEqual(convergence.launches, 1)
            await runtime.applyLibrarySyncOutcome(.noRemote)
            XCTAssertEqual(backfills.value, 1, "A later observation must not repeat the backfill")
            XCTAssertEqual(convergence.launches, 1)
        }
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
                                     convergence: PostSyncConverging? = nil) async throws -> AppRuntime {
        let paths = AppRuntimePaths(storeRoot: h.root, appSupportDir: h.root + "/support")
        let defaults = try isolatedDefaults("repair-lifecycle")
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        defaults.set("off", forKey: UpdateCheckSchedule.frequencyKey)
        let runtime = try AppRuntime(container: h.context.container, library: h.library,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }), defaults: defaults,
            launchBackfill: { _ in backfills.increment() }, hasRemoteConfigured: { false },
            postSyncConvergence: convergence ?? RepairLifecycleConvergence(), launchIngestLockPath: h.lockPath, paths: paths)
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
    func run(after result: SyncCycleResult) {}
    func runAfterLaunchIngest() { launches += 1 }
}
