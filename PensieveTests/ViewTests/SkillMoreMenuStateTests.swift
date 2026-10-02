import XCTest
@testable import Pensieve

/// What the More menu offers (PLAN-34 / 34.2), from the skill's link and its provenance.
final class SkillMoreMenuStateTests: XCTestCase {
    private let repo = URL(string: "https://github.com/basecamp/basecamp-cli")
    private let skillPage = URL(string: "https://github.com/basecamp/basecamp-cli/tree/main/skills/basecamp")

    private func linkedSkill() -> Skill {
        let skill = Skill(name: "basecamp", directoryName: "basecamp")
        skill.installedOrigin = InstalledOrigin(repo: "https://github.com/basecamp/basecamp-cli", path: "skills/basecamp",
                                                ref: "main", installedCommit: "d3cc757", installedTree: "",
                                                contentHash: "", installedAt: Date(), updatedAt: Date())
        return skill
    }

    private func provenance(skillURL: URL?, repositoryURL: URL?) -> SkillProvenance {
        SkillProvenance(installedAt: nil, updatedAt: nil, trackedRef: "main", shortCommit: "d3cc757",
                        repositoryURL: repositoryURL, skillURL: skillURL, localEditNote: nil, checkError: nil,
                        updateAvailable: false)
    }

    func testLinkedSkillOffersGitHubAndUpdates() {
        let state = SkillMoreMenuState(skill: linkedSkill(), provenance: provenance(skillURL: skillPage, repositoryURL: repo),
                                       isChecking: false)

        XCTAssertTrue(state.isLinked)
        XCTAssertTrue(state.canViewOnGitHub)
        XCTAssertFalse(state.isChecking)
    }

    func testUnlinkedSkillOffersConnectInstead() {
        let state = SkillMoreMenuState(skill: Skill(name: "authored", directoryName: "authored"), provenance: nil,
                                       isChecking: false)

        XCTAssertFalse(state.isLinked)
        XCTAssertFalse(state.canViewOnGitHub)
    }

    func testCheckingDisablesCheckForUpdates() {
        let state = SkillMoreMenuState(skill: linkedSkill(), provenance: provenance(skillURL: nil, repositoryURL: repo),
                                       isChecking: true)

        XCTAssertTrue(state.isChecking)
        XCTAssertTrue(state.canViewOnGitHub)
    }

    func testNoURLDisablesViewOnGitHub() {
        let state = SkillMoreMenuState(skill: linkedSkill(), provenance: provenance(skillURL: nil, repositoryURL: nil),
                                       isChecking: false)

        XCTAssertTrue(state.isLinked)
        XCTAssertFalse(state.canViewOnGitHub)
    }
}
