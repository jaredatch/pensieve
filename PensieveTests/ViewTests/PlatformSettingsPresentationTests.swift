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

    func testBudgetValuesUseSettingsDefaultsAndOmitUnlimited() throws {
        let suite = "PlatformSettingsPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(PlatformTokenBudgetSetting.values(defaults: defaults), [
            .claudeCode: Constants.defaultClaudeCodeTokenBudget,
            .grok: Constants.defaultGrokTokenBudget,
            .cursor: Constants.defaultCursorTokenBudget
        ])
    }

    func testBudgetValuesReadSettingsKeysAgainAfterAnEdit() throws {
        let suite = "PlatformSettingsPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for setting in PlatformTokenBudgetSetting.rows {
            guard case let .editable(storageKey, defaultValue) = setting.budget else { continue }
            defaults.set(defaultValue + 100, forKey: storageKey)
            XCTAssertEqual(PlatformTokenBudgetSetting.values(defaults: defaults)[setting.platform], defaultValue + 100)
            defaults.set(defaultValue + 200, forKey: storageKey)
            XCTAssertEqual(PlatformTokenBudgetSetting.values(defaults: defaults)[setting.platform], defaultValue + 200)
        }
    }

    func testZeroBudgetIsOmitted() throws {
        try assertBudgetIsOmitted(0)
    }

    func testNegativeBudgetIsOmitted() throws {
        try assertBudgetIsOmitted(-2_500)
    }

    func testStringBudgetIsOmitted() throws {
        try assertBudgetIsOmitted("not a number")
        try assertBudgetIsOmitted("2500")
    }

    private func assertBudgetIsOmitted(_ value: Any, file: StaticString = #filePath, line: UInt = #line) throws {
        let suite = "PlatformSettingsPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for setting in PlatformTokenBudgetSetting.rows {
            guard case let .editable(storageKey, _) = setting.budget else { continue }
            defaults.set(value, forKey: storageKey)
            XCTAssertNil(PlatformTokenBudgetSetting.values(defaults: defaults)[setting.platform],
                         "Invalid budget must omit \(setting.platform.displayName)", file: file, line: line)
            defaults.removeObject(forKey: storageKey)
        }
    }
}
