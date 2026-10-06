import XCTest
@testable import Pensieve

final class InstalledSkillHistoryPresentationTests: XCTestCase {
    func testUpstreamRowsFormatCopyBadgesAndActions() throws {
        let installedSHA = String(repeating: "b", count: 40)
        let result = makeResult(
            rows: [
                makeRow("a", year: 2026, files: 3, added: 214, removed: 38),
                makeRow("b", year: 2025, files: 1, added: 12, removed: 9),
                makeRow("c", year: 2024, files: 1, added: nil, removed: nil)
            ],
            position: .at(sha: installedSHA)
        )

        let rows = InstalledSkillHistoryPresentation.upstreamRows(
            result: result,
            shownCount: 3,
            updateAvailable: true,
            now: date(year: 2026),
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(rows.map(\.shortHash), ["aaaaaaa", "bbbbbbb", "ccccccc"])
        XCTAssertEqual(rows.map(\.date), ["Sep 10", "Sep 10, 2025", "Sep 10, 2024"])
        XCTAssertEqual(rows.map(\.stats), [
            "3 files changed · +214 −38",
            "1 file changed · +12 −9",
            "1 file changed"
        ])
        XCTAssertEqual(rows.map(\.badge), [.available, .installed, nil])
        XCTAssertEqual(rows.map(\.canViewDiff), [true, false, true])
        XCTAssertEqual(rows.map(\.canUpdate), [true, false, false])
        XCTAssertFalse(InstalledSkillHistoryPresentation.upstreamRows(
            result: result,
            shownCount: 3,
            updateAvailable: false
        ).contains(where: \.canUpdate))
    }

    func testLineChangePresentationSplitsVisibleColorsFromAccessibilityCopy() throws {
        let result = makeResult(
            rows: [makeRow("a", year: 2026, files: 3, added: 214, removed: 38)],
            position: .olderThanRowsRead
        )
        let upstream = try XCTUnwrap(InstalledSkillHistoryPresentation.upstreamRows(
            result: result,
            shownCount: 1,
            updateAvailable: false
        ).first)

        XCTAssertEqual(upstream.filesText, "3 files changed")
        XCTAssertEqual(upstream.additionsText, "+214")
        XCTAssertEqual(upstream.deletionsText, "−38")
        XCTAssertEqual(upstream.stats, "3 files changed · +214 −38")

        let local = try XCTUnwrap(InstalledSkillHistoryPresentation.localRow(
            edits: .changed([change("SKILL.md", added: 41, removed: 12)]),
            baseline: .files([]),
            installedCommit: String(repeating: "d", count: 40)
        ))
        XCTAssertEqual(local.detailText, "SKILL.md")
        XCTAssertEqual(local.additionsText, "+41")
        XCTAssertEqual(local.deletionsText, "−12")
        XCTAssertEqual(local.detail, "SKILL.md · +41 −12")
    }

    func testLocalRowsChooseExactCopyAndSumTheSameChangesTheyPresent() {
        let changes = [
            change("SKILL.md", added: 40, removed: 10),
            change("references/tone.md", added: 1, removed: 2),
            change("references/examples.md", added: 0, removed: 0)
        ]
        let row = InstalledSkillHistoryPresentation.localRow(
            edits: .changed(changes),
            baseline: .files([]),
            installedCommit: String(repeating: "d", count: 40)
        )

        XCTAssertEqual(row?.title, "3 files changed since you installed ddddddd")
        XCTAssertEqual(row?.detail, "SKILL.md, references/tone.md, and 1 more · +41 −12")
        XCTAssertEqual(row?.changes, changes)
        XCTAssertEqual(row?.canViewEdits, true)

        let singular = InstalledSkillHistoryPresentation.localRow(
            edits: .changed([change("SKILL.md", added: 1, removed: 0)]),
            baseline: .files([]),
            installedCommit: String(repeating: "e", count: 40)
        )
        XCTAssertEqual(singular?.title, "1 file changed since you installed eeeeeee")
    }

    func testUnknownLocalCountsHaveNoDetailOrViewAction() {
        let row = InstalledSkillHistoryPresentation.localRow(
            edits: .countsUnknown,
            baseline: nil,
            installedCommit: String(repeating: "a", count: 40)
        )

        XCTAssertEqual(row?.title, "This copy has local edits")
        XCTAssertNil(row?.detail)
        XCTAssertEqual(row?.canViewEdits, false)

        let binary = UpstreamHistoryLocalChange(
            path: "asset.png",
            linesAdded: nil,
            linesRemoved: nil,
            installedText: nil,
            currentText: nil
        )
        let measured = InstalledSkillHistoryPresentation.localRow(
            edits: .changed([binary]),
            baseline: .files([]),
            installedCommit: String(repeating: "a", count: 40)
        )
        XCTAssertEqual(measured?.detail, "asset.png")
        XCTAssertEqual(measured?.canViewEdits, true)
    }

    func testRowsWithoutReadableSkillMarkdownOfferNoDiff() {
        let base = makeRow("a", year: 2026, files: 1, added: 1, removed: 0)
        let rows = [
            UpstreamHistoryRow(
                sha: base.sha,
                author: base.author,
                date: base.date,
                subject: base.subject,
                filesChanged: base.filesChanged,
                linesAdded: base.linesAdded,
                linesRemoved: base.linesRemoved,
                skillMarkdown: nil
            ),
            UpstreamHistoryRow(
                sha: String(repeating: "b", count: 40),
                author: base.author,
                date: base.date,
                subject: base.subject,
                filesChanged: base.filesChanged,
                linesAdded: base.linesAdded,
                linesRemoved: base.linesRemoved,
                skillMarkdown: .tooLarge
            )
        ]
        let result = makeResult(rows: rows, position: .olderThanRowsRead)

        XCTAssertFalse(InstalledSkillHistoryPresentation.upstreamRows(
            result: result,
            shownCount: 2,
            updateAvailable: false
        ).contains(where: \.canViewDiff))
    }

    func testOlderActionRevealsHeldRowsBeforeReadingAnotherWindow() {
        XCTAssertEqual(
            InstalledSkillHistoryPresentation.olderAction(total: 20, shown: 10, hasOlderHistory: true),
            .revealReadRows
        )
        XCTAssertEqual(
            InstalledSkillHistoryPresentation.olderAction(total: 20, shown: 20, hasOlderHistory: true),
            .readNextWindow
        )
        XCTAssertNil(InstalledSkillHistoryPresentation.olderAction(total: 20, shown: 20, hasOlderHistory: false))
    }

    func testForcePushedHistoryNamesInstalledCommitAndRefWithoutInstalledBadge() {
        let result = makeResult(
            rows: [makeRow("a", year: 2026, files: 1, added: 1, removed: 0)],
            position: .notInRefHistory
        )
        let rows = InstalledSkillHistoryPresentation.upstreamRows(
            result: result,
            shownCount: 3,
            updateAvailable: false
        )

        XCTAssertFalse(rows.contains(where: { $0.badge == .installed }))
        XCTAssertEqual(
            InstalledSkillHistoryPresentation.installedNote(
                position: result.installedPosition,
                commit: String(repeating: "d", count: 40),
                ref: "main"
            ),
            "Installed version ddddddd is no longer in main."
        )
    }

    func testFailureFallbackNamesManifestVersionAndInstallDate() {
        let origin = InstalledOrigin(
            repo: "https://github.com/example/skills",
            path: "skills/demo",
            ref: "main",
            installedCommit: String(repeating: "d", count: 40),
            installedTree: "tree",
            contentHash: "sha256:value",
            installedAt: date(year: 2025),
            updatedAt: date(year: 2025)
        )

        XCTAssertTrue(InstalledSkillHistoryPresentation.installedSummary(origin: origin).hasPrefix("Installed ddddddd · "))
        XCTAssertEqual(InstalledSkillHistoryPresentation.tryAgainTitle, "Try Again")
    }

    func testAnotherSkillsStateIsLoadingRatherThanStaleRows() throws {
        let shownSkillID = UUID()
        let otherSkillID = UUID()
        let origin = try XCTUnwrap(installedHistorySkill().installedOrigin)

        XCTAssertEqual(
            InstalledSkillHistoryPresentation.content(
                state: .loaded(historyResult()),
                currentSkillID: otherSkillID,
                skillID: shownSkillID,
                origin: origin
            ),
            .loading
        )
        XCTAssertEqual(
            InstalledSkillHistoryPresentation.content(
                state: .failed("Offline"),
                currentSkillID: shownSkillID,
                skillID: shownSkillID,
                origin: origin
            ),
            .failed(
                message: "Offline",
                installedSummary: InstalledSkillHistoryPresentation.installedSummary(origin: origin)
            )
        )
    }

}

extension InstalledSkillHistoryPresentationTests {
    func testRefreshStatesKeepRowsAndExposeQuietStatusCopy() throws {
        let skillID = UUID()
        let result = historyResult()
        let origin = try XCTUnwrap(installedHistorySkill().installedOrigin)

        XCTAssertEqual(
            InstalledSkillHistoryPresentation.content(
                state: .refreshing(result),
                currentSkillID: skillID,
                skillID: skillID,
                origin: origin
            ),
            .loaded(result, isUpdating: true, failureMessage: nil)
        )
        XCTAssertEqual(
            InstalledSkillHistoryPresentation.content(
                state: .loadedWithFailure(result, "History couldn't be refreshed. Offline."),
                currentSkillID: skillID,
                skillID: skillID,
                origin: origin
            ),
            .loaded(
                result,
                isUpdating: false,
                failureMessage: "History couldn't be refreshed. Offline."
            )
        )
        XCTAssertEqual(InstalledSkillHistoryPresentation.updatingTitle, "Updating…")
        XCTAssertEqual(InstalledSkillHistoryPresentation.tryAgainTitle, "Try Again")
    }

    func testRequestIdentityChangesForEveryTimelineReloadInput() throws {
        let skill = installedHistorySkill()
        let revision = UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 2)
        let original = InstalledSkillHistoryPresentation.RequestID(
            skill: skill,
            localRevision: revision,
            windowCount: 1
        )

        skill.lastCheckedHead = String(repeating: "f", count: 40)
        XCTAssertNotEqual(original, InstalledSkillHistoryPresentation.RequestID(
            skill: skill, localRevision: revision, windowCount: 1
        ))
        skill.lastCheckedHead = nil
        let originalOrigin = try XCTUnwrap(skill.installedOrigin)
        var movedOrigin = originalOrigin
        movedOrigin.installedCommit = String(repeating: "c", count: 40)
        skill.installedOrigin = movedOrigin
        XCTAssertNotEqual(original, InstalledSkillHistoryPresentation.RequestID(
            skill: skill, localRevision: revision, windowCount: 1
        ))
        skill.installedOrigin = originalOrigin
        XCTAssertNotEqual(original, InstalledSkillHistoryPresentation.RequestID(
            skill: skill,
            localRevision: UpstreamHistoryLocalRevision(appWriteRevision: 2, watcherEventSequence: 2),
            windowCount: 1
        ))
        XCTAssertNotEqual(original, InstalledSkillHistoryPresentation.RequestID(
            skill: skill, localRevision: revision, windowCount: 2
        ))
        let anotherSkill = installedHistorySkill()
        XCTAssertNotEqual(original, InstalledSkillHistoryPresentation.RequestID(
            skill: anotherSkill, localRevision: revision, windowCount: 1
        ))
    }
}

private extension InstalledSkillHistoryPresentationTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func date(year: Int) -> Date {
        // A Gregorian noon with fixed components is a fixture invariant.
        utcCalendar.date(from: DateComponents(year: year, month: 9, day: 10, hour: 12))!
    }

    private func makeRow(
        _ character: Character,
        year: Int,
        files: Int,
        added: Int?,
        removed: Int?
    ) -> UpstreamHistoryRow {
        UpstreamHistoryRow(
            sha: String(repeating: String(character), count: 40),
            author: "Author",
            date: date(year: year),
            subject: "Subject",
            filesChanged: files,
            linesAdded: added,
            linesRemoved: removed,
            skillMarkdown: .text("# Skill")
        )
    }

    private func makeResult(
        rows: [UpstreamHistoryRow],
        position: UpstreamHistoryInstalledPosition
    ) -> UpstreamHistoryResult {
        UpstreamHistoryResult(
            headCommit: rows[0].sha,
            rows: rows,
            installedPosition: position,
            hasOlderHistory: false,
            installedBaseline: .files([]),
            localEdits: .none,
            windowCount: 1
        )
    }

    private func change(_ path: String, added: Int, removed: Int) -> UpstreamHistoryLocalChange {
        UpstreamHistoryLocalChange(
            path: path,
            linesAdded: added,
            linesRemoved: removed,
            installedText: "before",
            currentText: "after"
        )
    }
}
