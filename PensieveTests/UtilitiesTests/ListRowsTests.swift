import XCTest
@testable import Pensieve

final class ListRowsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Chicago")!
        value.locale = Locale(identifier: "en_US")
        return value
    }

    func testSkillRowGlyphDateAndPlaceholders() {
        let skill = Skill(name: "Alpha", directoryName: "alpha")
        skill.installedOrigin = origin()
        skill.createdAt = date(2026, 9, 7, 11, 31)
        skill.updatedAt = date(2026, 9, 8, 10, 0)
        let dates = ListDates(now: date(2026, 9, 8, 12, 0), calendar: calendar,
                              locale: Locale(identifier: "en_US"))

        var row = ListRows.skill(skill, deployIndex: .empty, sortKey: .created,
                                 isConflicted: false, dates: dates)
        XCTAssertEqual(row.glyph, .gitHub)
        XCTAssertEqual(row.trailingText, "Yesterday")
        XCTAssertEqual(row.line2, "Not deployed")
        XCTAssertEqual(row.line3, "No description")

        skill.updateAvailable = true
        row = ListRows.skill(skill, deployIndex: .empty, sortKey: .updated,
                             isConflicted: false, dates: dates)
        XCTAssertEqual(row.glyph, .updateAvailable)
        XCTAssertEqual(row.trailingText, "10:00\u{202F}AM")
    }

    func testSkillRowConflictTakesGlyphSlot() {
        let skill = Skill(name: "Alpha", directoryName: "alpha")
        skill.installedOrigin = origin()
        skill.updateAvailable = true
        let dates = ListDates(now: date(2026, 9, 8, 12, 0), calendar: calendar,
                              locale: Locale(identifier: "en_US"))

        XCTAssertEqual(ListRows.skill(skill, deployIndex: .empty, sortKey: .name,
                                      isConflicted: true, dates: dates).glyph, .conflict)
    }

    func testAFailedCheckWithdrawsTheUpdateGlyph() {
        let skill = Skill(name: "Alpha", directoryName: "alpha")
        skill.installedOrigin = origin()
        skill.updateAvailable = true
        skill.checkError = "offline"
        let dates = ListDates(now: date(2026, 9, 8, 12, 0), calendar: calendar,
                              locale: Locale(identifier: "en_US"))

        XCTAssertEqual(ListRows.skill(skill, deployIndex: .empty, sortKey: .name,
                                      isConflicted: false, dates: dates).glyph, .gitHub)
        skill.checkError = nil
        XCTAssertEqual(ListRows.skill(skill, deployIndex: .empty, sortKey: .name,
                                      isConflicted: false, dates: dates).glyph, .updateAvailable)
    }

    func testProjectRowAbbreviatesHomeAndCountsSkills() {
        let project = Project(name: "Pensieve", path: "/Users/k/Projects/pensieve")
        project.identityKey = "key"
        project.identityKind = ProjectIdentity.Kind.remote.rawValue
        let index = DeployIndex(records: [
            record(slug: "alpha", key: "key", path: "/a"),
            record(slug: "beta", key: "key", path: "/b")
        ])
        let row = ListRows.project(project, deployIndex: index, homeDirectory: "/Users/k")

        XCTAssertEqual(row.trailingText, "2 skills")
        XCTAssertEqual(row.line2, "~/Projects/pensieve")
        XCTAssertEqual(row.line3, "key")
        XCTAssertTrue(row.line2TruncatesMiddle)
    }

    func testProjectRowUnavailableIndexSaysSo() {
        let project = Project(name: "Pensieve", path: "/tmp/pensieve")

        XCTAssertEqual(ListRows.project(project, deployIndex: .unavailable,
                                        homeDirectory: "/Users/k").trailingText,
                       "Deploy state unavailable")
    }

    func testAbbreviatePathRejectsPrefixTrap() {
        XCTAssertEqual(ListRows.abbreviatePath("/Users/kk/y", homeDirectory: "/Users/k"), "/Users/kk/y")
        XCTAssertEqual(ListRows.abbreviatePath("/Volumes/X/y", homeDirectory: "/Users/k"), "/Volumes/X/y")
        XCTAssertEqual(ListRows.abbreviatePath("/Users/k", homeDirectory: "/Users/k"), "~")
        XCTAssertEqual(ListRows.abbreviatePath("/Users/k/a/../b", homeDirectory: "/Users/k"), "~/a/../b")
        XCTAssertEqual(
            ListRows.abbreviatePath("/Users/k/../../Volumes/X", homeDirectory: "/Users/k"),
            "/Users/k/../../Volumes/X"
        )
    }

    func testHomeContainmentIsPureLexicalForPrivateAndTildePaths() {
        let missing = "pensieve-missing-" + UUID().uuidString

        XCTAssertEqual(HomePath.normalizedAbbreviation("/private/tmp", homeDirectory: "/private"), "~/tmp")
        XCTAssertEqual(
            HomePath.normalizedAbbreviation("/private/" + missing, homeDirectory: "/private"),
            "~/" + missing
        )
        XCTAssertEqual(
            HomePath.normalizedAbbreviation("/Users/k//Projects/", homeDirectory: "/Users/k/"),
            "~/Projects"
        )
        XCTAssertNil(
            HomePath.normalizedAbbreviation("~/Projects", homeDirectory: PathConstants.homeDirectory)
        )
    }

    func testCategoryRowNamesCountsAndUnregisteredPlaceholder() {
        let project = Project(name: "Pensieve", path: "/tmp/pensieve")
        project.identityKey = "known"
        let skill = Skill(name: "Alpha", directoryName: "alpha")
        let category = Category(name: "Tools")
        category.projectKeys = ["known"]
        category.skillSlugs = ["alpha"]

        var row = ListRows.category(category, projects: [project], skills: [skill])
        XCTAssertEqual(row.trailingText, "1 project · 1 skill")
        XCTAssertEqual(row.line2, "Pensieve")
        XCTAssertEqual(row.line3, "Alpha")

        category.projectKeys = ["missing"]
        category.skillSlugs = ["remote-slug"]
        row = ListRows.category(category, projects: [project], skills: [skill])
        XCTAssertEqual(row.line2, "Not registered on this Mac")
        XCTAssertEqual(row.line3, "remote-slug")
    }

    func testTagRowHasNoThirdLine() {
        let alpha = Skill(name: "Alpha", tags: ["swift"], directoryName: "alpha")
        let row = ListRows.tag("swift", skills: [alpha])

        XCTAssertEqual(row.trailingText, "1 skill")
        XCTAssertEqual(row.line2, "Alpha")
        XCTAssertNil(row.line3)
    }

    func testMachineRowThisMacAgentsAndDeployCounts() {
        let published = date(2026, 9, 8, 10, 0)
        let dates = ListDates(now: date(2026, 9, 8, 12, 0), calendar: calendar,
                              locale: Locale(identifier: "en_US"))
        var state = machineState(
            publishedAt: published,
            agents: [PlatformTarget.claudeCode.rawValue, "z\u{200B}ed"],
            projects: [MachineStateProject(identityKey: "key", kind: "remote", name: "Project")],
            userDeploys: [MachineStateUserDeploy(slug: "alpha", platform: "codex"),
                          MachineStateUserDeploy(slug: "alpha", platform: "claudeCode")],
            projectDeploys: []
        )
        var row = ListRows.machine(state, isThisMac: true, dates: dates)
        XCTAssertEqual(row.title, "mini (This Mac)")
        XCTAssertEqual(row.line2, "Claude Code, zed")
        XCTAssertEqual(row.line3, "1 skill for every project · 0 for one project")

        state = machineState(
            publishedAt: published,
            projectDeploys: [MachineStateProjectDeploy(slug: "alpha", platform: "codex", projectKey: "a"),
                             MachineStateProjectDeploy(slug: "beta", platform: "codex", projectKey: "b")]
        )
        row = ListRows.machine(state, isThisMac: false, dates: dates)
        XCTAssertEqual(row.line3, "0 skills for every project · 2 for one project")
    }

    func testMachineSearchUsesTheSanitizedPublishedName() {
        let state = MachineState(
            schemaVersion: 1, machineID: "5A9C2E31-8F04-4D2B-9C61-0B7A43F1D002",
            name: "M\u{200B}ac", appVersion: "test", publishedAt: Date(),
            agents: [], projects: [], userDeploys: [], projectDeploys: []
        )

        XCTAssertTrue(ListRows.machineMatchesSearch(state, query: "mac"))
    }

    func testMachineRowSanitizesPublishedNameBeforeAddingThisMacSuffix() {
        let dates = ListDates(now: date(2026, 9, 8, 12, 0), calendar: calendar,
                              locale: Locale(identifier: "en_US"))
        var state = machineState(publishedAt: date(2026, 9, 8, 10, 0))
        state = MachineState(
            schemaVersion: state.schemaVersion, machineID: state.machineID,
            name: "\n\u{200F}" + String(repeating: "M", count: 100), appVersion: state.appVersion,
            publishedAt: state.publishedAt, agents: state.agents, projects: state.projects,
            userDeploys: state.userDeploys, projectDeploys: state.projectDeploys
        )

        let row = ListRows.machine(state, isThisMac: true, dates: dates)

        XCTAssertEqual(row.title.count, 91)
        XCTAssertTrue(row.title.hasSuffix("… (This Mac)"))
        XCTAssertFalse(row.title.contains("\n"))
        XCTAssertFalse(row.title.contains("\u{200F}"))
    }

    func testScenarioRowActiveAndAgents() {
        let skill = Skill(name: "Alpha", directoryName: "alpha")
        let scenario = Scenario(name: "Writing")
        scenario.skillSlugs = ["alpha"]
        scenario.agentRawValues = [PlatformTarget.codex.rawValue, "zed"]
        let row = ListRows.scenario(scenario, skills: [skill], isActive: true)

        XCTAssertEqual(row.trailingText, "Active")
        XCTAssertEqual(row.line2, "Alpha")
        XCTAssertEqual(row.line3, "Codex, zed")
    }

    func testSubtitleForms() {
        XCTAssertEqual(ListSubtitle.text(total: 0, shown: 0, singular: "skill", plural: "skills"), "No skills")
        XCTAssertEqual(ListSubtitle.text(total: 1, shown: 1, singular: "category", plural: "categories"),
                       "1 category")
        XCTAssertEqual(ListSubtitle.text(total: 4, shown: 2, singular: "skill", plural: "skills"), "2 of 4 skills")
        XCTAssertEqual(ListSubtitle.text(total: 4, shown: 4, singular: "skill", plural: "skills"), "4 skills")
    }

    func testMailStyleDates() {
        let dates = ListDates(now: date(2026, 9, 8, 12, 0), calendar: calendar,
                              locale: Locale(identifier: "en_US"))

        XCTAssertEqual(dates.mailStyle(date(2026, 9, 8, 11, 31)), "11:31\u{202F}AM")
        XCTAssertEqual(dates.mailStyle(date(2026, 9, 7, 16, 0)), "Yesterday")
        XCTAssertEqual(dates.mailStyle(date(2026, 9, 5, 16, 0)), "9/5/26")
    }

    func testLineTitlesPerSection() {
        XCTAssertEqual(ListLineTitles.titles(for: .skills).line2, "Show Deployments")
        XCTAssertEqual(ListLineTitles.titles(for: .skills).line3, "Show Description")
        XCTAssertEqual(ListLineTitles.titles(for: .projects).line3, "Show Identity")
        XCTAssertEqual(ListLineTitles.titles(for: .categories).line3, "Show Skills")
        XCTAssertEqual(ListLineTitles.titles(for: .scenarios).line3, "Show Agents")
        XCTAssertEqual(ListLineTitles.titles(for: .machines).line3, "Show Deployments")
        XCTAssertEqual(ListLineTitles.titles(for: .tags).line2, "Show Skills")
        XCTAssertNil(ListLineTitles.titles(for: .tags).line3)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func origin() -> InstalledOrigin {
        InstalledOrigin(repo: "https://github.com/example/skills", path: "alpha", ref: "main",
                        installedCommit: "commit", installedTree: "tree", contentHash: "hash",
                        installedAt: Date(), updatedAt: Date())
    }

    private func record(slug: String, key: String, path: String) -> DeployStateRecord {
        DeployStateRecord(slug: slug, platform: PlatformTarget.claudeCode.rawValue, scope: "project",
                          projectIdentityKey: key, artifactPath: path, recordedAt: "2026-09-07T00:00:00Z")
    }

    private func machineState(
        publishedAt: Date,
        agents: [String] = [],
        projects: [MachineStateProject] = [],
        userDeploys: [MachineStateUserDeploy] = [],
        projectDeploys: [MachineStateProjectDeploy] = []
    ) -> MachineState {
        MachineState(schemaVersion: 1, machineID: "machine", name: "mini", appVersion: "1.0",
                     publishedAt: publishedAt, agents: agents, projects: projects,
                     userDeploys: userDeploys, projectDeploys: projectDeploys)
    }
}
