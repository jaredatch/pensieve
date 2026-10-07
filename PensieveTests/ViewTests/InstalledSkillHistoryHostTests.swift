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
        let firstHead = try XCTUnwrap(first.installedOrigin?.installedCommit)
        let secondHead = try XCTUnwrap(second.installedOrigin?.installedCommit)
        let readProbe = LockedHistoryProbe()
        let localProbe = LockedHistoryProbe()
        let owner = historyOwner(
            read: { origin, _, windowCount in
                readProbe.recordCall()
                return Self.result(head: origin.installedCommit, windowCount: windowCount)
            },
            localEdits: { _, _, _ in localProbe.recordCall(); return .none }
        )
        let model = InstalledHistoryHostModel(skill: first)
        let session = InstalledSkillHistorySession()
        let window = makeWindow(model: model, history: owner, session: session)
        defer { window.close() }

        await waitForSettledHistory(owner: owner, expected: .loaded(Self.result(head: firstHead, windowCount: 1)),
                                    timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                                    failureMessage: "The first mounted skill must finish its initial history read")
        try await presentSheet(owner: owner, session: session, window: window)

        model.skill = second

        await waitForSettledHistory(owner: owner, expected: .loaded(Self.result(head: secondHead, windowCount: 1)),
                                    failureMessage: "Changing skill must dismiss the sheet and read window one",
                                    ready: { window.attachedSheet == nil })
        XCTAssertFalse(session.showAllReadRows)
        XCTAssertEqual(session.requestedWindow, 1)
        XCTAssertNil(session.diff)
        XCTAssertNil(session.edits)
        XCTAssertEqual(owner.currentSkillID, second.id)

        let question = owner.currentRequest?.key
        let readCount = readProbe.calls
        model.localRevision = UpstreamHistoryLocalRevision(
            appWriteRevision: 1,
            watcherEventSequence: 0
        )

        await waitForSettledHistory(owner: owner, expected: .loaded(Self.result(head: secondHead, windowCount: 1)),
                                    failureMessage: "Changing local revision must refresh local edits once",
                                    ready: { localProbe.calls == 1 })
        XCTAssertEqual(localProbe.calls, 1)
        XCTAssertEqual(readProbe.calls, readCount, "Changing local revision must not read upstream history")
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
        await waitForSettledHistory(owner: owner, expected: .loaded(Self.result(head: result.headCommit, windowCount: 4)),
                                    failureMessage: "Presenting history diff must mount its sheet",
                                    ready: { window.attachedSheet != nil })
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
        let reads = LockedHistoryProbe()
        let intents = HostedHistoryIntentProbe()
        let owner = historyOwner(
            read: { _, _, _ in
                reads.recordCall()
                if reads.calls == 1 { throw Failure.offline }
                return historyResult()
            },
            onRequest: intents.record
        )
        let model = InstalledHistoryHostModel(skill: installedHistorySkill())
        let fixture = makeFixture(model: model, history: owner, session: InstalledSkillHistorySession())
        defer { fixture.window.close() }

        let failed = UpstreamHistoryLoadState.failed("The repository couldn't be reached.")
        await waitForSettledHistory(owner: owner, expected: failed,
                                    timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                                    failureMessage: "The mounted history must display its initial read failure")
        XCTAssertEqual(reads.calls, 1)
        XCTAssertEqual(intents.values, [.appearance])

        fixture.unmount()
        await Task.yield()
        model.localRevision = UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)
        await waitForSettledHistory(owner: owner, expected: failed, timeout: .seconds(TestWait.timeoutSeconds),
                                    observeFor: .seconds(TestWait.hostedActionTimeoutSeconds),
                                    failureMessage: "Unmounted revision must preserve settled history without a read")
        XCTAssertEqual(owner.state, failed, "Unmounted revision must keep the pre-change settled state")
        XCTAssertEqual(reads.calls, 1, "Unmounted local revision must not read upstream history")
        fixture.mount()

        await waitForSettledHistory(owner: owner, expected: .loaded(historyResult()),
                                    failureMessage: "Remounting history must retry its read on appearance")
        XCTAssertEqual(reads.calls, 2)
        XCTAssertEqual(intents.values, [.appearance, .appearance])
    }

    func testRenderedTryAgainButtonSendsRetryAndStartsOneRead() async {
        let reads = LockedHistoryProbe()
        let intents = HostedHistoryIntentProbe()
        let owner = historyOwner(
            read: { _, _, _ in
                reads.recordCall()
                if reads.calls == 1 { throw Failure.offline }
                return historyResult()
            },
            onRequest: intents.record
        )
        let model = InstalledHistoryHostModel(skill: installedHistorySkill())
        let fixture = makeFixture(model: model, history: owner, session: InstalledSkillHistorySession())
        defer { fixture.window.close() }

        await waitForSettledHistory(owner: owner, expected: .failed("The repository couldn't be reached."),
                                    timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                                    failureMessage: "The mounted history must display its initial read failure")
        XCTAssertEqual(reads.calls, 1)
        var pressed = HistoryAccessibility.pressButtonIfFound(
            titled: InstalledSkillHistoryPresentation.tryAgainTitle,
            in: fixture.host
        )
        if !pressed {
            pressed = await clickRenderedTryAgain(in: fixture.window) { intents.values.count == 2 }
        }
        XCTAssertTrue(pressed)

        await waitForSettledHistory(owner: owner, expected: .loaded(historyResult()),
                                    failureMessage: "The rendered Try again action must start its retry read")
        XCTAssertEqual(reads.calls, 2)
        XCTAssertEqual(intents.values, [.appearance, .retry])
    }

    func testMountedRevisionRefireSendsMountedRefreshWithoutReading() async {
        let reads = LockedHistoryProbe()
        let intents = HostedHistoryIntentProbe()
        let owner = historyOwner(
            read: { _, _, _ in
                reads.recordCall()
                throw Failure.offline
            },
            onRequest: intents.record
        )
        let model = InstalledHistoryHostModel(skill: installedHistorySkill())
        let fixture = makeFixture(model: model, history: owner, session: InstalledSkillHistorySession())
        defer { fixture.window.close() }

        await waitForSettledHistory(owner: owner, expected: .failed("The repository couldn't be reached."),
                                    timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                                    failureMessage: "The mounted history must display its initial read failure")
        XCTAssertEqual(reads.calls, 1)
        model.localRevision = UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)

        await waitForSettledHistory(owner: owner, expected: .failed("The repository couldn't be reached."),
                                    failureMessage: "Mounted local revision must send its refresh intent",
                                    ready: { intents.values.count == 2 })
        XCTAssertEqual(reads.calls, 1, "Mounted local revision must not read upstream history")
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
