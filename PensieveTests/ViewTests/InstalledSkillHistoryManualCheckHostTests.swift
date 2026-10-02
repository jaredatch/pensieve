import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class HistoryManualCheckHostTests: XCTestCase {
    func testVisibleManualCheckRefiresAtCurrentWindowWithRetryIntent() async {
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
        let session = InstalledSkillHistorySession()
        let model = ManualCheckHostModel(skill: skill)
        let host = NSHostingView(rootView: ManualCheckHostHarness(
            model: model,
            history: owner,
            session: session
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let loaded = await eventually { reads.count == 1 }
        XCTAssertTrue(loaded)
        session.requestedWindow = 3
        let expanded = await eventually { reads.count == 2 }
        XCTAssertTrue(expanded)
        owner.invalidateForManualCheck(skillID: skill.id)
        let refreshed = await eventually { reads.count == 3 }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(reads.windows, [1, 3, 3])
        XCTAssertEqual(intents, [.appearance, .mountedRefresh, .retry])
    }

    /// Protects 39.2-b: the observed manual-check count belongs to the skill currently in the view.
    func testSwitchAfterManualCheckDoesNotRefreshTheNextSkillsKeptResult() async {
        let reads = ManualCheckHostReadProbe()
        let first = installedHistorySkill(name: "First")
        let second = installedHistorySkill(name: "Second", commit: String(repeating: "c", count: 40))
        let secondProbeStarted = DispatchSemaphore(value: 0)
        let releaseSecondProbe = DispatchSemaphore(value: 0)
        defer { releaseSecondProbe.signal() }
        let owner = historyOwner(
            read: { origin, _, window in
                reads.record(window: window)
                return Self.result(head: origin.installedCommit, window: window)
            },
            head: { origin in
                if origin.installedCommit == second.installedOrigin?.installedCommit {
                    secondProbeStarted.signal()
                    _ = releaseSecondProbe.wait(timeout: .now() + 3)
                }
                return origin.installedCommit
            }
        )
        await owner.request(skill: second)
        let model = ManualCheckHostModel(skill: first)
        let host = NSHostingView(rootView: ManualCheckHostHarness(
            model: model, history: owner, session: InstalledSkillHistorySession()
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let firstLoaded = await eventually { reads.count == 2 }
        XCTAssertTrue(firstLoaded)
        owner.invalidateForManualCheck(skillID: first.id)
        let firstRefreshed = await eventually { reads.count == 3 }
        XCTAssertTrue(firstRefreshed)
        owner.probedSkillIDs.remove(second.id)
        model.skill = second
        let secondProbeDidStart = await waitForHistorySemaphore(secondProbeStarted)
        XCTAssertTrue(secondProbeDidStart)

        XCTAssertEqual(reads.count, 3)
        let secondOrigin = try? XCTUnwrap(second.installedOrigin)
        XCTAssertEqual(owner.state, .loaded(Self.result(head: secondOrigin?.installedCommit ?? "", window: 1)))
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 150 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
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
