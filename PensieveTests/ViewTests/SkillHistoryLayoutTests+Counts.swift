import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension SkillHistoryLayoutTests {
    func testShowOlderCommitsButtonRevealsHeldRows() async throws {
        let host = makeHost(try countFixture(), height: 1800)
        defer { host.window.close() }
        host.window.styleMask = [.titled, .closable]
        NSApp.activate(ignoringOtherApps: true)
        host.window.makeKeyAndOrderFront(nil)

        let initial = try await settledDots(
            in: host.view, expecting: 10, timeout: TestWait.firstRenderTimeoutSeconds
        )
        XCTAssertEqual(initial.count, 10, "the installed view draws ten initial rows")
        await TestWait.until(
            timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
            failureMessage: "the rendered Show older commits button must accept an accessibility press"
        ) {
            HistoryAccessibility.pressButton(titled: "Show older commits", in: host.view)
        }
        let revealed = try await settledDots(in: host.view, expecting: 12)
        XCTAssertEqual(revealed.count, 12, "pressing Show older commits renders all twelve held rows")
    }
}

private extension SkillHistoryLayoutTests {
    func countFixture() throws -> AnyView {
        let skill = installedHistorySkill()
        let result = historyTimelineResult(rowCount: 12)
        let history = historyOwner(read: { _, _, _ in result })
        let tab = InstalledSkillHistoryView(
            skill: skill, currentBody: "# Current", origin: try XCTUnwrap(skill.installedOrigin),
            updateAvailable: false, localRevision: .initial, onOpenUpdates: {}, onUpdateCheck: { _ in },
            history: history
        )
        return AnyView(tab)
    }

    func settledDots(
        in view: NSView,
        expecting count: Int,
        timeout: TimeInterval = TestWait.hostedActionTimeoutSeconds
    ) async throws -> [CGFloat] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var previous: [CGFloat]?
        var settled: [CGFloat]?
        repeat {
            view.layoutSubtreeIfNeeded()
            let dots = HistoryPixels.capture(in: view)?.positions.rowTops
            if let dots, dots == previous {
                settled = dots
                if dots.count == count { return dots }
            } else {
                settled = nil
            }
            previous = dots
            try await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        // A stable wrong count reaches the caller's count assertion, rather than a load timeout.
        return try XCTUnwrap(settled, "History marker positions did not settle within \(timeout) s")
    }
}
