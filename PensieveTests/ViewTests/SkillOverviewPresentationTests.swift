import XCTest
@testable import Pensieve

/// The Overview tab's rows (PLAN-34 / 34.2): the three cards, a linked and an authored skill's Source
/// rows, a pinned install, the Contents rows, the "more files" label, and the two date forms — all in
/// `en_US` against a fixed clock.
final class SkillOverviewPresentationTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private func day(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    private var now: Date { day(9, 16) }

    private func linkedProvenance() -> (SkillProvenance, InstalledOrigin) {
        let repo = URL(string: "https://github.com/basecamp/basecamp-cli")!
        let skillURL = URL(string: "https://github.com/basecamp/basecamp-cli/tree/main/skills/basecamp")!
        let provenance = SkillProvenance(installedAt: day(8, 9), updatedAt: day(9, 7), trackedRef: "main",
                                         shortCommit: "d3cc757", repositoryURL: repo, skillURL: skillURL,
                                         localEditNote: nil, checkError: nil, updateAvailable: false)
        let origin = InstalledOrigin(repo: "https://github.com/basecamp/basecamp-cli", path: "skills/basecamp",
                                     ref: "main", installedCommit: "d3cc757e4f1a9b2c3d4e5f60718293a4b5c6d7e8",
                                     installedTree: "", contentHash: "", installedAt: day(8, 9), updatedAt: day(9, 7))
        return (provenance, origin)
    }

    private func inventory(_ files: [SkillBundleInventory.File]) -> SkillBundleInventory {
        var inventory = SkillBundleInventory()
        inventory.files = files
        return inventory
    }

    private func file(_ path: String, _ bytes: Int, _ tokens: Int?) -> SkillBundleInventory.File {
        SkillBundleInventory.File(relativePath: path, bytes: bytes, tokens: tokens)
    }

    func testStatsFormatTheThreeCards() {
        var snapshot = DetailContentSnapshot()
        snapshot.tokenCount = 18857
        snapshot.inventory = inventory((0..<12).map { file("f\($0).md", 214_000 / 12 + ($0 == 0 ? 214_000 % 12 : 0), 10) })
        snapshot.macStatus = [.claudeCode: false, .codex: false, .cursor: false, .grok: false]

        let stats = SkillOverviewPresentation.stats(snapshot: snapshot, installedCount: 4, budget: 0, locale: locale)

        XCTAssertEqual(stats.map(\.label), ["Context cost", "Bundle", "Deployed"])
        XCTAssertEqual(stats[0].value, "18,857")
        XCTAssertEqual(stats[0].detail, "tokens when loaded")
        XCTAssertEqual(stats[1].value, "12")
        XCTAssertEqual(stats[1].detail, "files · 214 KB")
        XCTAssertEqual(stats[2].value, "0 of 4")
        XCTAssertEqual(stats[2].detail, "platforms on this Mac")
    }

    func testAOneFileBundleSaysFile() {
        var snapshot = DetailContentSnapshot()
        snapshot.inventory = inventory([file("SKILL.md", 3_000, 750)])

        let stats = SkillOverviewPresentation.stats(snapshot: snapshot, installedCount: 4, budget: 0)

        XCTAssertEqual(stats[1].value, "1")
        XCTAssertEqual(stats[1].detail, "file · 3 KB")
    }

    /// A walk stopped at its caps or at an unreadable entry counted what it read: the Bundle card reads it as
    /// a floor, "+" on both numbers (PLAN-34 / 34.2, Layer-1).
    func testATruncatedBundleReadsAsAFloor() {
        var snapshot = DetailContentSnapshot()
        snapshot.inventory = inventory([file("SKILL.md", 1000, 250), file("a.md", 1000, 250)])
        snapshot.inventory.truncated = true

        let bundle = SkillOverviewPresentation.stats(snapshot: snapshot, installedCount: 4, budget: 0)[1]

        XCTAssertEqual(bundle.value, "2+")
        XCTAssertEqual(bundle.detail, "files · 2 KB+")
    }

    func testLinkedSourceRowsInOrder() {
        let skill = Skill(name: "basecamp", directoryName: "basecamp")
        let (provenance, origin) = linkedProvenance()

        let rows = SkillOverviewPresentation.sourceRows(skill: skill, provenance: provenance, origin: origin,
                                                        homeDirectory: Constants.homeDirectory, now: now, locale: locale)

        XCTAssertEqual(rows.map(\.label), ["Repository", "Tracked ref", "Local path", "Installed", "Last updated"])
        XCTAssertEqual(rows[0].value, "basecamp/basecamp-cli")
        XCTAssertEqual(rows[0].detail, "/tree/main/skills/basecamp")
        XCTAssertEqual(rows[0].action, .open(provenance.skillURL!))
        XCTAssertEqual(rows[1].value, "main")
        XCTAssertEqual(rows[1].detail, "d3cc757")
        XCTAssertEqual(rows[1].separator, "@")
        XCTAssertEqual(rows[1].action, .copy(origin.installedCommit))
        XCTAssertEqual(rows[2].value, "~/.pensieve/skills/basecamp")
        XCTAssertEqual(rows[2].action, .reveal(skill.canonicalDir))
        XCTAssertEqual(rows[3].value, "Aug 9, 2026")
        XCTAssertEqual(rows[3].detail, "1 month ago")
        XCTAssertEqual(rows[4].value, "Sep 7, 2026")
        XCTAssertEqual(rows[4].detail, "1 week ago")
        XCTAssertNil(rows[4].action)
    }

    func testARootRepositoryPathFallsBackToTheOriginsRepo() {
        let skill = Skill(name: "basecamp", directoryName: "basecamp")
        let (linked, origin) = linkedProvenance()
        let provenance = SkillProvenance(installedAt: linked.installedAt, updatedAt: linked.updatedAt,
                                         trackedRef: linked.trackedRef, shortCommit: linked.shortCommit,
                                         repositoryURL: URL(string: "https://github.com/"), skillURL: linked.skillURL,
                                         localEditNote: nil, checkError: nil, updateAvailable: false)

        let rows = SkillOverviewPresentation.sourceRows(skill: skill, provenance: provenance, origin: origin,
                                                        homeDirectory: Constants.homeDirectory, now: now, locale: locale)

        XCTAssertEqual(rows.first { $0.label == "Repository" }?.value, origin.repo)
    }

    func testPinnedInstallReadsCommitPinned() {
        let skill = Skill(name: "basecamp", directoryName: "basecamp")
        var (provenance, origin) = linkedProvenance()
        provenance = SkillProvenance(installedAt: provenance.installedAt, updatedAt: provenance.updatedAt, trackedRef: nil,
                                     shortCommit: "d3cc757", repositoryURL: provenance.repositoryURL,
                                     skillURL: provenance.skillURL, localEditNote: nil, checkError: nil, updateAvailable: false)
        origin.ref = ""

        let rows = SkillOverviewPresentation.sourceRows(skill: skill, provenance: provenance, origin: origin,
                                                        homeDirectory: Constants.homeDirectory, now: now, locale: locale)

        XCTAssertEqual(rows[1].label, "Tracked ref")
        XCTAssertEqual(rows[1].value, "d3cc757")
        XCTAssertEqual(rows[1].detail, "pinned")
        XCTAssertEqual(rows[1].separator, "•")
        XCTAssertEqual(rows[1].action, .copy(origin.installedCommit))
    }

    func testAuthoredSourceRowsInOrder() {
        let skill = Skill(name: "public-user-docs", directoryName: "public-user-docs")
        skill.createdAt = day(8, 9)
        skill.updatedAt = day(8, 19)

        let rows = SkillOverviewPresentation.sourceRows(skill: skill, provenance: nil, origin: nil,
                                                        homeDirectory: Constants.homeDirectory, now: now, locale: locale)

        XCTAssertEqual(rows.map(\.label), ["Local path", "Created", "Modified"])
        XCTAssertEqual(rows[0].value, "~/.pensieve/skills/public-user-docs")
        XCTAssertEqual(rows[1].value, "Aug 9, 2026")
        XCTAssertEqual(rows[1].detail, "1 month ago")
        XCTAssertEqual(rows[2].value, "Aug 19, 2026")
        XCTAssertEqual(rows[2].detail, "4 weeks ago")
    }

    func testContentsRowsSortByTokensThenPathWithShares() {
        let rows = SkillOverviewPresentation.contentsRows(inventory: inventory([
            file("c.md", 100, 25), file("b.sh", 40, 10), file("a.md", 100, 25), file("img.png", 5, nil)
        ]))

        XCTAssertEqual(rows.map(\.relativePath), ["a.md", "c.md", "b.sh"])
        XCTAssertEqual(rows.map(\.tokens), [25, 25, 10])
        XCTAssertEqual(rows.map(\.share), [1, 1, 0.4])
    }

    func testMoreFilesLabel() {
        XCTAssertNil(SkillOverviewPresentation.moreFilesLabel(total: 5, shown: 5))
        XCTAssertNil(SkillOverviewPresentation.moreFilesLabel(total: 3, shown: 3))
        XCTAssertEqual(SkillOverviewPresentation.moreFilesLabel(total: 6, shown: 5), "Show 1 more file")
        XCTAssertEqual(SkillOverviewPresentation.moreFilesLabel(total: 12, shown: 5), "Show 7 more files")
    }

    func testRelativeTextUsesFullUnits() {
        XCTAssertEqual(SkillOverviewPresentation.relativeText(day(9, 14), now: now, locale: locale), "2 days ago")
        XCTAssertEqual(SkillOverviewPresentation.relativeText(day(8, 19), now: now, locale: locale), "4 weeks ago")
        XCTAssertEqual(SkillOverviewPresentation.relativeText(day(8, 9), now: now, locale: locale), "1 month ago")
    }

    func testRelativeTextSaysJustNowUnderAMinuteAndInTheFuture() {
        func text(_ offset: TimeInterval) -> String {
            SkillOverviewPresentation.relativeText(now.addingTimeInterval(offset), now: now, locale: locale)
        }
        XCTAssertEqual(text(0.4), "just now")
        XCTAssertEqual(text(0), "just now")
        XCTAssertEqual(text(-59), "just now")
        XCTAssertEqual(text(-60), "1 minute ago")
    }

    func testDateTextAbbreviatesTheMonth() {
        XCTAssertEqual(SkillOverviewPresentation.dateText(day(9, 7), locale: locale), "Sep 7, 2026")
    }
}
