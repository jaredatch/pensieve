import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension SkillHistoryLayoutTests {
    func testInstalledDotsFollowTheSessionRevealRule() async throws {
        let fixture = try countFixture()
        let host = makeHost(fixture.tab, height: 1800)
        defer { host.window.close() }

        let initial = try await settledDots(in: host.view, expecting: 10)
        XCTAssertEqual(initial.count, 10, "the installed view draws ten initial rows")
        fixture.session.showOlder(.revealReadRows, currentWindow: 1)
        let revealed = try await settledDots(in: host.view, expecting: 12)
        XCTAssertEqual(revealed.count, 12, "the installed view draws all held rows after session reveal")
    }
}

private extension SkillHistoryLayoutTests {
    func countFixture() throws -> (tab: AnyView, session: InstalledSkillHistorySession) {
        let skill = installedHistorySkill()
        let session = InstalledSkillHistorySession()
        let result = historyTimelineResult(rowCount: 12)
        let history = historyOwner(read: { _, _, _ in result })
        let tab = InstalledSkillHistoryView(
            skill: skill, currentBody: "# Current", origin: try XCTUnwrap(skill.installedOrigin),
            updateAvailable: false, localRevision: .initial, onOpenUpdates: {}, onUpdateCheck: { _ in },
            history: history, hostedSession: session
        )
        return (AnyView(tab), session)
    }

    func settledDots(in view: NSView, expecting count: Int) async throws -> [CGFloat] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
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
        return try XCTUnwrap(settled, "History marker positions did not settle within 3 s")
    }
}
