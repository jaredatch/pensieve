import XCTest
@testable import Pensieve

extension SkillInstallViewModelTests {
    func testConfirmButtonTitleMatchesSelectedCount() async {
        let model = SkillInstallViewModel(service: ScriptedInstallService(candidates: [candidate("alpha"), candidate("beta")]))
        model.urlText = "https://github.com/acme/skills"
        await model.fetchAndReport()
        XCTAssertEqual(model.state, .picking)

        model.selectAll()
        XCTAssertEqual(model.confirmButtonTitle, "Install 2 Skills")

        model.toggleSelection(candidate("beta"))
        XCTAssertEqual(model.selectedCount, 1)
        XCTAssertEqual(model.confirmButtonTitle, "Install 1 Skill")
    }

    func testConfirmButtonTitleIsSingularForASingleSkillLink() async {
        let model = SkillInstallViewModel(service: ScriptedInstallService(candidates: [candidate("brand-guidelines")]))
        model.urlText = "https://github.com/anthropics/skills/tree/main/skills/brand-guidelines"
        await model.fetchAndReport()

        XCTAssertEqual(model.state, .picking)
        XCTAssertEqual(model.confirmButtonTitle, "Install 1 Skill")
    }
}
