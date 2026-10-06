import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class HistoryManualCheckHostTests: XCTestCase {
    func testVisibleManualCheckRefiresAtCurrentWindowWithRetryIntent() async throws {
        let reads = ManualCheckHostReadProbe()
        var intents: [UpstreamHistoryViewModel.RequestIntent] = []
        let owner = historyOwner(
            read: { origin, _, window in
                reads.record(window: window)
                return Self.result(head: origin.installedCommit, window: window)
            },
            onRequest: { intents.append($0) }
        )
        let skill = installedHistorySkill()
        let head = try XCTUnwrap(skill.installedOrigin?.installedCommit)
        let session = InstalledSkillHistorySession()
        let model = ManualCheckHostModel(skill: skill)
        let window = makeWindow(model: model, history: owner, session: session)
        defer { window.close() }

        await waitForSettledHistory(owner: owner, expected: .loaded(Self.result(head: head, window: 1)),
                                    timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                                    failureMessage: "The visible history must perform its initial read")
        XCTAssertEqual(reads.count, 1)
        session.requestedWindow = 3
        await waitForSettledHistory(owner: owner, expected: .loaded(Self.result(head: head, window: 3)),
                                    failureMessage: "Expanding history must read the requested window")
        XCTAssertEqual(reads.count, 2)
        owner.invalidateForManualCheck(skillID: skill.id)
        await waitForSettledHistory(owner: owner, expected: .loaded(Self.result(head: head, window: 3)),
                                    failureMessage: "Manual check must refire the visible history read",
                                    ready: { intents.count == 3 })
        XCTAssertEqual(reads.count, 3)
        XCTAssertEqual(reads.windows, [1, 3, 3])
        XCTAssertEqual(intents, [.appearance, .mountedRefresh, .retry])
    }

    /// Protects 39.2-b: the observed manual-check count belongs to the skill currently in the view.
    func testSwitchAfterManualCheckDoesNotRefreshTheNextSkillsKeptResult() async throws {
        let reads = ManualCheckHostReadProbe()
        let first = installedHistorySkill(name: "First")
        let second = installedHistorySkill(name: "Second", commit: String(repeating: "c", count: 40))
        let head = try XCTUnwrap(first.installedOrigin?.installedCommit)
        let secondHead = try XCTUnwrap(second.installedOrigin?.installedCommit)
        let secondProbeStarted = DispatchSemaphore(value: 0)
        let releaseSecondProbe = DispatchSemaphore(value: 0)
        defer { releaseSecondProbe.signal() }
        let owner = historyOwner(
            read: { origin, _, window in
                reads.record(window: window)
                return Self.result(head: origin.installedCommit, window: window)
            },
            head: { origin in
                if origin.installedCommit == secondHead {
                    secondProbeStarted.signal()
                    _ = releaseSecondProbe.wait(timeout: .now() + TestWait.heldFixtureTimeoutSeconds)
                }
                return origin.installedCommit
            }
        )
        await owner.request(skill: second)
        let model = ManualCheckHostModel(skill: first)
        let window = makeWindow(model: model, history: owner, session: InstalledSkillHistorySession())
        defer { window.close() }

        await waitForSettledHistory(owner: owner, expected: .loaded(Self.result(head: head, window: 1)),
                                    timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                                    failureMessage: "The first skill must load after the kept second result")
        XCTAssertEqual(reads.count, 2)
        let requestBeforeCheck = owner.currentRequest?.id
        owner.invalidateForManualCheck(skillID: first.id)
        await waitForSettledHistory(owner: owner, expected: .loaded(Self.result(head: head, window: 1)),
                                    failureMessage: "Manual check must refresh the first skill before switching",
                                    ready: { owner.currentRequest?.id != requestBeforeCheck })
        XCTAssertEqual(reads.count, 3)
        owner.probedSkillIDs.remove(second.id)
        model.skill = second
        var secondProbeDidStart = false
        await waitForSettledHistory(owner: owner, expected: .loaded(Self.result(head: secondHead, window: 1)),
                                    failureMessage: "Switching must keep the next skill's settled history",
                                    ready: {
                                        secondProbeDidStart = secondProbeDidStart
                                            || secondProbeStarted.wait(timeout: .now()) == .success
                                        return secondProbeDidStart
                                    })
        XCTAssertTrue(secondProbeDidStart)

        XCTAssertEqual(reads.count, 3)
        XCTAssertEqual(owner.state, .loaded(Self.result(head: secondHead, window: 1)))
    }

    private func makeWindow(
        model: ManualCheckHostModel,
        history: UpstreamHistoryViewModel,
        session: InstalledSkillHistorySession
    ) -> NSWindow {
        let host = NSHostingView(rootView: ManualCheckHostHarness(model: model, history: history, session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private static func result(head: String, window: Int) -> UpstreamHistoryResult {
        let base = historyResult(head: head)
        return UpstreamHistoryResult(
            headCommit: head,
            rows: base.rows,
            installedPosition: base.installedPosition,
            hasOlderHistory: true,
            installedBaseline: base.installedBaseline,
            localEdits: base.localEdits,
            windowCount: window
        )
    }
}

@MainActor
@Observable
private final class ManualCheckHostModel {
    var skill: Skill

    init(skill: Skill) {
        self.skill = skill
    }
}

private struct ManualCheckHostHarness: View {
    @Bindable var model: ManualCheckHostModel
    @Bindable var history: UpstreamHistoryViewModel
    let session: InstalledSkillHistorySession

    var body: some View {
        if let origin = model.skill.installedOrigin {
            InstalledSkillHistoryView(
                skill: model.skill,
                currentBody: "# Current",
                origin: origin,
                updateAvailable: false,
                localRevision: .initial,
                onOpenUpdates: {},
                onUpdateCheck: { _ in },
                history: history,
                hostedSession: session
            )
        }
    }
}

private final class ManualCheckHostReadProbe {
    private let lock = NSLock()
    private var recordedWindows: [Int] = []

    func record(window: Int) {
        lock.lock()
        recordedWindows.append(window)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedWindows.count
    }

    var windows: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recordedWindows
    }
}
