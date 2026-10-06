import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class InstalledSkillHistoryHostTests: XCTestCase {
    private enum Failure: LocalizedError {
        case offline

        var errorDescription: String? { "The repository couldn't be reached." }
    }

    func testSkillChangeDismissesSheetResetsPagingAndRequestsNewSkill() async throws {
        let first = installedHistorySkill(name: "First")
        let second = installedHistorySkill(name: "Second", commit: String(repeating: "c", count: 40))
        let readProbe = HostedHistoryReadProbe()
        let localProbe = LockedHistoryProbe()
        let owner = historyOwner(
            read: { origin, _, windowCount in
                readProbe.record(commit: origin.installedCommit, windowCount: windowCount)
                return Self.result(head: origin.installedCommit, windowCount: windowCount)
            },
            localEdits: { _, _, _ in localProbe.recordCall(); return .none }
        )
        let model = InstalledHistoryHostModel(skill: first)
        let session = InstalledSkillHistorySession()
        let window = makeWindow(model: model, history: owner, session: session)
        defer { window.close() }

        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "The first mounted skill must finish its initial history read") {
            guard case let .loaded(result) = owner.state else { return false }
            return readProbe.contains(commit: first.installedOrigin?.installedCommit)
                && result.headCommit == first.installedOrigin?.installedCommit
        }
        try await presentSheet(owner: owner, session: session, window: window)

        model.skill = second

        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Changing skill must dismiss the sheet and read window one") {
            guard case let .loaded(result) = owner.state else { return false }
            return window.attachedSheet == nil
                && readProbe.contains(commit: second.installedOrigin?.installedCommit, windowCount: 1)
                && result.headCommit == second.installedOrigin?.installedCommit
                && result.windowCount == 1
        }
        XCTAssertFalse(session.showAllReadRows)
        XCTAssertEqual(session.requestedWindow, 1)
        XCTAssertNil(session.diff)
        XCTAssertNil(session.edits)
        XCTAssertEqual(owner.currentSkillID, second.id)

        let question = owner.currentRequest?.key
        let readCount = readProbe.count
        model.localRevision = UpstreamHistoryLocalRevision(
            appWriteRevision: 1,
            watcherEventSequence: 0
        )

        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Changing local revision must refresh local edits once") {
            localProbe.calls == 1
        }
        XCTAssertEqual(localProbe.calls, 1)
        XCTAssertEqual(readProbe.count, readCount)
        XCTAssertEqual(owner.currentRequest?.key, question)
        XCTAssertEqual(owner.currentSkillID, second.id)
    }

    private func makeWindow(
        model: InstalledHistoryHostModel,
        history: UpstreamHistoryViewModel,
        session: InstalledSkillHistorySession
    ) -> NSWindow {
        makeFixture(model: model, history: history, session: session).window
    }

    private func makeFixture(
        model: InstalledHistoryHostModel,
        history: UpstreamHistoryViewModel,
        session: InstalledSkillHistorySession
    ) -> InstalledHistoryHostFixture {
        let host = NSHostingView(rootView: InstalledHistoryHostHarness(
            model: model,
            history: history,
            session: session
        ))
        let container = NSView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        let fixture = InstalledHistoryHostFixture(window: window, container: container, host: host)
        fixture.mount()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return fixture
    }

    private func presentSheet(
        owner: UpstreamHistoryViewModel,
        session: InstalledSkillHistorySession,
        window: NSWindow
    ) async throws {
        guard case let .loaded(result) = owner.state else { return XCTFail("expected first history") }
        let row = try XCTUnwrap(InstalledSkillHistoryPresentation.upstreamRows(
            result: result,
            shownCount: 1,
            updateAvailable: false
        ).first)
        session.showAllReadRows = true
        session.requestedWindow = 4
        session.presentDiff(row)
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Presenting history diff must mount its sheet") {
            window.attachedSheet != nil
        }
    }

    private func sendClick(at point: NSPoint, to window: NSWindow) -> Bool {
        window.makeKey()
        let eventTypes: [NSEvent.EventType] = [.leftMouseDown, .leftMouseUp]
        for eventType in eventTypes {
            guard let event = NSEvent.mouseEvent(
                with: eventType,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else { return false }
            window.sendEvent(event)
        }
        return true
    }

    private func clickRenderedTryAgain(
        in window: NSWindow,
        activated: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let bounds = window.contentView?.bounds ?? .zero
        for xPosition in stride(from: 8.0, through: min(bounds.maxX, 180), by: 8) {
            for yPosition in stride(from: 8.0, through: bounds.maxY, by: 8) {
                guard sendClick(at: NSPoint(x: xPosition, y: yPosition), to: window) else { return false }
                try? await Task.sleep(nanoseconds: 2_000_000)
                if activated() { return true }
            }
        }
        return false
    }

    private static func result(head: String, windowCount: Int) -> UpstreamHistoryResult {
        let base = historyResult(head: head)
        return UpstreamHistoryResult(
            headCommit: base.headCommit,
            rows: base.rows,
            installedPosition: base.installedPosition,
            hasOlderHistory: true,
            installedBaseline: base.installedBaseline,
            localEdits: base.localEdits,
            windowCount: windowCount
        )
    }
}

extension InstalledSkillHistoryHostTests {
    func testRemountAfterAbsentRevisionChangeSendsAppearanceAndRetriesOnce() async {
        let reads = HostedHistoryReadProbe()
        let intents = HostedHistoryIntentProbe()
        let owner = historyOwner(
            read: { _, _, _ in
                reads.record(commit: "failure", windowCount: 1)
                if reads.count == 1 { throw Failure.offline }
                return historyResult()
            },
            onRequest: intents.record
        )
        let model = InstalledHistoryHostModel(skill: installedHistorySkill())
        let fixture = makeFixture(model: model, history: owner, session: InstalledSkillHistorySession())
        defer { fixture.window.close() }

        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "The mounted history must display its initial read failure") {
            reads.count == 1 && owner.state == .failed("The repository couldn't be reached.")
        }
        XCTAssertEqual(intents.values, [.appearance])

        fixture.unmount()
        await Task.yield()
        model.localRevision = UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)
        XCTAssertEqual(reads.count, 1)
        fixture.mount()

        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Remounting history must retry its read on appearance") {
            reads.count == 2 && owner.state == .loaded(historyResult())
        }
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(intents.values, [.appearance, .appearance])
    }

    func testRenderedTryAgainButtonSendsRetryAndStartsOneRead() async {
        let reads = HostedHistoryReadProbe()
        let intents = HostedHistoryIntentProbe()
        let owner = historyOwner(
            read: { _, _, _ in
                reads.record(commit: "failure", windowCount: 1)
                if reads.count == 1 { throw Failure.offline }
                return historyResult()
            },
            onRequest: intents.record
        )
        let model = InstalledHistoryHostModel(skill: installedHistorySkill())
        let fixture = makeFixture(model: model, history: owner, session: InstalledSkillHistorySession())
        defer { fixture.window.close() }

        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "The mounted history must display its initial read failure") {
            reads.count == 1 && owner.state == .failed("The repository couldn't be reached.")
        }
        var pressed = HistoryAccessibility.pressButtonIfFound(
            titled: InstalledSkillHistoryPresentation.tryAgainTitle,
            in: fixture.host
        )
        if !pressed {
            pressed = await clickRenderedTryAgain(in: fixture.window) { intents.values.count == 2 }
        }
        XCTAssertTrue(pressed)

        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "The rendered Try again action must start its retry read") {
            reads.count == 2 && owner.state == .loaded(historyResult())
        }
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(intents.values, [.appearance, .retry])
    }

    func testMountedRevisionRefireSendsMountedRefreshWithoutReading() async {
        let reads = HostedHistoryReadProbe()
        let intents = HostedHistoryIntentProbe()
        let owner = historyOwner(
            read: { _, _, _ in
                reads.record(commit: "failure", windowCount: 1)
                throw Failure.offline
            },
            onRequest: intents.record
        )
        let model = InstalledHistoryHostModel(skill: installedHistorySkill())
        let fixture = makeFixture(model: model, history: owner, session: InstalledSkillHistorySession())
        defer { fixture.window.close() }

        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "The mounted history must display its initial read failure") {
            reads.count == 1 && owner.state == .failed("The repository couldn't be reached.")
        }
        model.localRevision = UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)

        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Mounted local revision must send its refresh intent") {
            intents.values.count == 2
        }
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(intents.values, [.appearance, .mountedRefresh])
    }
}

@MainActor
@Observable
private final class InstalledHistoryHostModel {
    var skill: Skill
    var localRevision = UpstreamHistoryLocalRevision.initial

    init(skill: Skill) {
        self.skill = skill
    }
}

private struct InstalledHistoryHostHarness: View {
    @Bindable var model: InstalledHistoryHostModel
    @Bindable var history: UpstreamHistoryViewModel
    let session: InstalledSkillHistorySession

    var body: some View {
        if let origin = model.skill.installedOrigin {
            InstalledSkillHistoryView(
                skill: model.skill,
                currentBody: "# Current",
                origin: origin,
                updateAvailable: false,
                localRevision: model.localRevision,
                onOpenUpdates: {},
                onUpdateCheck: { _ in },
                history: history,
                hostedSession: session
            )
        }
    }
}

@MainActor
private struct InstalledHistoryHostFixture {
    let window: NSWindow
    let container: NSView
    let host: NSHostingView<InstalledHistoryHostHarness>

    func mount() {
        guard host.superview == nil else { return }
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
    }

    func unmount() {
        host.removeFromSuperview()
    }
}

@MainActor
private final class HostedHistoryIntentProbe {
    private(set) var values: [UpstreamHistoryViewModel.RequestIntent] = []

    func record(_ intent: UpstreamHistoryViewModel.RequestIntent) {
        values.append(intent)
    }
}

private final class HostedHistoryReadProbe {
    private struct Request {
        let commit: String
        let windowCount: Int
    }

    private let lock = NSLock()
    private var requests: [Request] = []

    func record(commit: String, windowCount: Int) {
        lock.lock()
        requests.append(Request(commit: commit, windowCount: windowCount))
        lock.unlock()
    }

    func contains(commit: String?, windowCount: Int? = nil) -> Bool {
        guard let commit else { return false }
        lock.lock()
        defer { lock.unlock() }
        return requests.contains {
            $0.commit == commit && (windowCount == nil || $0.windowCount == windowCount)
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}
