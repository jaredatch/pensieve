import XCTest
@testable import Pensieve

/// File › Delete Skill (⌘⌫) stands down while a sheet holds the keyboard (PLAN-34 / 34.2-m).
final class DeleteSkillCommandRuleTests: XCTestCase {
    func testEnabledWhileTheSkillsWindowIsKey() {
        XCTAssertTrue(DeleteSkillCommandRule.isEnabled(hasAction: true, windowIsKey: true))
    }

    func testDisabledWhileASheetHoldsTheKeyboard() {
        XCTAssertFalse(DeleteSkillCommandRule.isEnabled(hasAction: true, windowIsKey: false),
                       "⌘⌫ in a sheet's text field deletes to the line's start, not the skill behind the sheet")
    }

    func testDisabledWithNoSkillShown() {
        XCTAssertFalse(DeleteSkillCommandRule.isEnabled(hasAction: false, windowIsKey: true))
        XCTAssertFalse(DeleteSkillCommandRule.isEnabled(hasAction: true, windowIsKey: nil))
    }
}
