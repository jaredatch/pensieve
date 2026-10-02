import XCTest
@testable import Pensieve

final class DeploymentsPresentationTests: XCTestCase {
    func testMacRowsFollowTheInstalledOrder() {
        let platforms: [PlatformTarget] = [.claudeCode, .codex, .cursor, .grok]
        let rows = DeploymentsPresentation.macRows(installed: platforms, status: [.claudeCode: true])

        XCTAssertEqual(rows.map(\.platform), platforms)
        XCTAssertEqual(rows.map(\.isOn), [true, false, false, false])
        XCTAssertTrue(rows.allSatisfy { !$0.inherited })
    }

    func testThisMacSectionCarriesItsEmptyCopyOnlyWhenItHasNoRows() {
        let empty = DeploymentsPresentation.macSection(installed: [], status: [:])
        let populated = DeploymentsPresentation.macSection(installed: [.codex], status: [:])
        let computedEmpty = DeploymentsPresentation.macSection(rows: [])

        XCTAssertEqual(empty.emptyText, "No supported agents detected")
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertNil(populated.emptyText)
        XCTAssertEqual(populated.rows.map(\.platform), [.codex])
        XCTAssertEqual(computedEmpty.emptyText, "No supported agents detected")
    }

    func testAProjectRowListsTheProjectCapablePlatformsOnly() {
        let project = Project(name: "Pensieve", path: "/tmp/pensieve")
        let platforms: [PlatformTarget] = [.claudeCode, .grok, .codex, .cursor]

        let row = DeploymentsPresentation.projectRows(
            projects: [project], projectPlatforms: platforms, macStatus: [:], projectStatus: [:], homeDirectory: "/Users/x"
        )[0]

        XCTAssertEqual(row.platforms.map(\.platform), platforms)
        XCTAssertFalse(row.platforms.contains { $0.platform == .openClaw || $0.platform == .hermes })
    }

    func testInheritedPlatformIsOnAndDisabledWithTheNote() {
        let project = Project(name: "Pensieve", path: "/tmp/pensieve")

        let row = DeploymentsPresentation.projectRows(
            projects: [project], projectPlatforms: [.claudeCode], macStatus: [.claudeCode: true],
            projectStatus: [project.id: [.claudeCode: false]], homeDirectory: "/Users/x"
        )[0].platforms[0]

        XCTAssertTrue(row.isOn)
        XCTAssertTrue(row.inherited)
        XCTAssertEqual(row.note, "On for every project on this Mac")
    }

    func testRowEnabledStateRequiresCurrentStatusAndNoInheritance() {
        let direct = DeploymentsPresentation.macRows(installed: [.codex], status: [:])[0]
        let project = Project(name: "Pensieve", path: "/tmp/pensieve")
        let inherited = DeploymentsPresentation.projectRows(
            projects: [project], projectPlatforms: [.codex], macStatus: [.codex: true],
            projectStatus: [:], homeDirectory: "/Users/x"
        )[0].platforms[0]

        XCTAssertFalse(DeploymentsPresentation.macRows(
            installed: [.codex], status: [:], statusIsCurrent: false
        )[0].isEnabled)
        XCTAssertFalse(inherited.isEnabled)
        XCTAssertTrue(direct.isEnabled)
    }

    func testTurningTheMacSwitchOffReturnsTheProjectRowToItsOwnState() {
        let project = Project(name: "Pensieve", path: "/tmp/pensieve")

        var row = DeploymentsPresentation.projectRows(
            projects: [project], projectPlatforms: [.claudeCode], macStatus: [.claudeCode: false],
            projectStatus: [project.id: [.claudeCode: true]], homeDirectory: "/Users/x"
        )[0].platforms[0]
        XCTAssertTrue(row.isOn)
        XCTAssertFalse(row.inherited)

        row = DeploymentsPresentation.projectRows(
            projects: [project], projectPlatforms: [.claudeCode], macStatus: [.claudeCode: false],
            projectStatus: [project.id: [.claudeCode: false]], homeDirectory: "/Users/x"
        )[0].platforms[0]
        XCTAssertFalse(row.isOn)
        XCTAssertFalse(row.inherited)
    }

    func testCollapsedRowShowsMarksOrNotDeployed() {
        let project = Project(name: "Pensieve", path: "/tmp/pensieve")
        let row = DeploymentsPresentation.projectRows(
            projects: [project], projectPlatforms: [.claudeCode, .grok, .codex], macStatus: [.grok: true],
            projectStatus: [project.id: [.claudeCode: true]], homeDirectory: "/Users/x"
        )[0]

        XCTAssertEqual(row.deployedPlatforms, [.claudeCode, .grok])
        XCTAssertNil(row.summary)

        let empty = DeploymentsPresentation.projectRows(
            projects: [project], projectPlatforms: [.claudeCode], macStatus: [:], projectStatus: [:],
            homeDirectory: "/Users/x"
        )[0]
        XCTAssertEqual(empty.summary, "Not deployed")
    }

    func testPathsAbbreviateUnderTheHome() {
        let project = Project(name: "A", path: "/Users/x/Projects/a")

        let row = DeploymentsPresentation.projectRows(
            projects: [project], projectPlatforms: [], macStatus: [:], projectStatus: [:], homeDirectory: "/Users/x"
        )[0]

        XCTAssertEqual(row.caption, "~/Projects/a")
    }

    func testCopyIsTheDesignsCopy() {
        XCTAssertEqual(
            DeploymentsPresentation.thisMacDescription,
            "Turn on a platform to make this skill available in every project on this Mac."
        )
        XCTAssertEqual(
            DeploymentsPresentation.projectsDescription,
            "Turn on a platform for one project only. Works alongside This Mac."
        )
        XCTAssertEqual(DeploymentsPresentation.noProjects, "No projects yet.")
        XCTAssertEqual(DeploymentsPresentation.machineDeploySummary(everyProject: 2, oneProject: 3),
                       "2 skills for every project · 3 for one project")
        XCTAssertEqual(DeploymentsPresentation.machineDeploySummary(everyProject: 1, oneProject: 1),
                       "1 skill for every project · 1 for one project")
        XCTAssertEqual(DeploymentsPresentation.everyProjectTitle, "Deployed to Every Project")
        XCTAssertEqual(DeploymentsPresentation.oneProjectTitle, "Deployed to One Project")
        XCTAssertEqual(DeploymentsPresentation.noSkillsDeployed, "No skills deployed")
    }
}
