import XCTest
@testable import Pensieve

extension InstalledSkillHistoryPresentationTests {
    @MainActor
    func testInstalledTimelineShowsTenNewestCommitsThenRevealsHeldRows() throws {
        let result = historyTimelineResult(rowCount: 12)
        let session = InstalledSkillHistorySession()
        let initial = presentedRows(result, session: session)

        XCTAssertEqual(initial.count, 10, "installed history initially shows ten commits")
        XCTAssertEqual(initial.map(\.history.subject), result.rows.prefix(10).map(\.subject))
        XCTAssertEqual(InstalledSkillHistoryPresentation.showOlderTitle, "Show older commits")
        let action = try XCTUnwrap(InstalledSkillHistoryPresentation.olderAction(
            total: result.rows.count, shown: initial.count, hasOlderHistory: result.hasOlderHistory
        ))
        XCTAssertEqual(action, .revealReadRows)

        session.showOlder(action, currentWindow: result.windowCount)
        let revealed = presentedRows(result, session: session)
        XCTAssertEqual(revealed.count, 12)
        XCTAssertEqual(revealed.map(\.history.subject), result.rows.map(\.subject))
        XCTAssertEqual(session.requestedWindow, 1, "revealing held rows keeps windowCount at 1")
        XCTAssertNil(InstalledSkillHistoryPresentation.olderAction(
            total: result.rows.count, shown: revealed.count, hasOlderHistory: result.hasOlderHistory
        ))
    }

    @MainActor
    func testInstalledTimelineShowsAllFewerThanTenCommitsAndKeepsOlderWindowRule() {
        for hasOlder in [false, true] {
            let result = historyTimelineResult(rowCount: 6, hasOlderHistory: hasOlder)
            let rows = presentedRows(result, session: InstalledSkillHistorySession())

            XCTAssertEqual(rows.count, 6)
            XCTAssertEqual(rows.map(\.history.subject), result.rows.map(\.subject))
            XCTAssertEqual(InstalledSkillHistoryPresentation.olderAction(
                total: result.rows.count, shown: rows.count, hasOlderHistory: hasOlder
            ), hasOlder ? .readNextWindow : nil)
        }
    }
}

private extension InstalledSkillHistoryPresentationTests {
    @MainActor
    private func presentedRows(
        _ result: UpstreamHistoryResult,
        session: InstalledSkillHistorySession
    ) -> [InstalledSkillHistoryPresentation.UpstreamRow] {
        let shown = session.showAllReadRows
            ? result.rows.count
            : min(InstalledSkillHistoryPresentation.initiallyShown, result.rows.count)
        return InstalledSkillHistoryPresentation.upstreamRows(
            result: result, shownCount: shown, updateAvailable: false
        )
    }
}
