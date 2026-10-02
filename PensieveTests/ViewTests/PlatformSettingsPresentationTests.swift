import XCTest
@testable import Pensieve

final class PlatformSettingsPresentationTests: XCTestCase {
    func testGrokBudgetRowFollowsClaudeCodeAndUsesItsOwnStorageKey() {
        XCTAssertEqual(
            PlatformTokenBudgetSetting.rows.map(\.platform),
            [.claudeCode, .grok, .cursor, .codex]
        )

        guard let grok = PlatformTokenBudgetSetting.rows.first(where: { $0.platform == .grok }) else {
            return XCTFail("Grok is missing from Token Budgets")
        }
        XCTAssertEqual(
            grok.budget,
            .editable(storageKey: "grokTokenBudget", defaultValue: Constants.defaultGrokTokenBudget)
        )
    }

    func testGrokPathRowFollowsClaudeCodeAndShowsItsUserSkillsFolder() {
        XCTAssertEqual(
            PlatformPathSetting.rows.map(\.platform),
            [.claudeCode, .grok, .cursor]
        )

        guard let grok = PlatformPathSetting.rows.first(where: { $0.platform == .grok }) else {
            return XCTFail("Grok is missing from Platform Paths")
        }
        XCTAssertEqual(grok.label, "Grok Skills")
        XCTAssertEqual(grok.path, Constants.grokUserSkillsDir)
    }

    func testGrokDefaultBudgetIs2500Tokens() {
        XCTAssertEqual(Constants.defaultGrokTokenBudget, 2_500)
    }
}
