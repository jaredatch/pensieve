import XCTest
@testable import Pensieve

extension SkillOverviewPresentationTests {
    private func contextCost(tokens: Int, mac: [PlatformTarget: Bool] = [.claudeCode: true],
                             projects: [UUID: [PlatformTarget: Bool]] = [:],
                             budgets: [PlatformTarget: Int] = [.claudeCode: 2_500],
                             locale: Locale = Locale(identifier: "en_US")) -> SkillOverviewPresentation.Stat {
        let snapshot = DetailContentSnapshot(tokenCount: tokens, macStatus: mac, projectStatus: projects)
        return SkillOverviewPresentation.stats(snapshot: snapshot, installedCount: 4, budgets: budgets, locale: locale)[0]
    }

    func testUndeployedSkillNeverWarns() {
        let stat = contextCost(tokens: 100_000, mac: [.claudeCode: false, .grok: false],
                               projects: [UUID(): [.claudeCode: false, .cursor: false]],
                               budgets: [.claudeCode: 2_500, .grok: 2_500, .cursor: 5_000])

        XCTAssertNil(stat.budgetWarning)
        XCTAssertEqual(stat.detail, "tokens when loaded")
        XCTAssertNil(contextCost(tokens: 100_000, mac: [:]).budgetWarning)
    }

    func testCodexOnlyDeploymentNeverWarns() {
        let stat = contextCost(tokens: 100_000, mac: [.codex: true], projects: [UUID(): [.codex: true]],
                               budgets: [.claudeCode: 2_500, .codex: 1])

        XCTAssertNil(stat.budgetWarning)
        XCTAssertEqual(stat.detail, "tokens when loaded")
    }

    func testJustUnderEightyPercentHasNoWarning() {
        let stat = contextCost(tokens: 1_999)

        XCTAssertNil(stat.budgetWarning)
        XCTAssertEqual(stat.detail, "tokens when loaded")
    }

    func testExactlyEightyPercentHasNoWarning() {
        let stat = contextCost(tokens: 2_000)

        XCTAssertNil(stat.budgetWarning)
        XCTAssertEqual(stat.detail, "tokens when loaded")
    }

    func testJustOverEightyPercentWarns() {
        let stat = contextCost(tokens: 2_001)

        XCTAssertEqual(stat.budgetWarning, .warning)
        XCTAssertEqual(stat.detail, "near Claude Code's 2,500 budget")
    }

    func testExactlyOneHundredPercentWarns() {
        let stat = contextCost(tokens: 2_500)

        XCTAssertEqual(stat.budgetWarning, .warning)
        XCTAssertEqual(stat.detail, "near Claude Code's 2,500 budget")
    }

    func testJustOverOneHundredPercentIsExceeded() {
        let stat = contextCost(tokens: 2_501)

        XCTAssertEqual(stat.budgetWarning, .exceeded)
        XCTAssertEqual(stat.detail, "over Claude Code's 2,500 budget")
    }

    func testExceededPlatformWinsOverWarning() {
        let stat = contextCost(tokens: 2_600, mac: [.claudeCode: true, .grok: true],
                               budgets: [.claudeCode: 3_000, .grok: 2_500])

        XCTAssertEqual(stat.budgetWarning, .exceeded)
        XCTAssertEqual(stat.detail, "over Grok's 2,500 budget")
    }

    func testSmallerBudgetWinsBetweenWarnings() {
        let stat = contextCost(tokens: 2_100, mac: [.claudeCode: true, .grok: true],
                               budgets: [.claudeCode: 2_500, .grok: 2_400])

        XCTAssertEqual(stat.budgetWarning, .warning)
        XCTAssertEqual(stat.detail, "near Grok's 2,400 budget")
    }

    func testSmallerBudgetWinsBetweenExceededPlatforms() {
        let stat = contextCost(tokens: 3_001, mac: [.claudeCode: true, .grok: true],
                               budgets: [.claudeCode: 3_000, .grok: 2_500])

        XCTAssertEqual(stat.budgetWarning, .exceeded)
        XCTAssertEqual(stat.detail, "over Grok's 2,500 budget")
    }

    func testEqualBudgetsUseSettingsRowOrder() {
        for tokens in [2_001, 2_501] {
            let stat = contextCost(tokens: tokens, mac: [.grok: true, .claudeCode: true, .cursor: true],
                                   budgets: [.cursor: 2_500, .grok: 2_500, .claudeCode: 2_500])
            let proximity = tokens > 2_500 ? "over" : "near"

            XCTAssertEqual(stat.detail, "\(proximity) Claude Code's 2,500 budget")
        }
    }

    func testProjectOnlyDeploymentCountsForBudget() {
        let stat = contextCost(tokens: 2_501, mac: [.claudeCode: false],
                               projects: [UUID(): [.claudeCode: false], UUID(): [.claudeCode: true]])

        XCTAssertEqual(stat.budgetWarning, .exceeded)
        XCTAssertEqual(stat.detail, "over Claude Code's 2,500 budget")
    }

    func testWarningCopyFormatsRawEstimateAndBudget() {
        let stat = contextCost(tokens: 2_001)

        XCTAssertEqual(stat.value, "2,001")
        XCTAssertEqual(stat.detail, "near Claude Code's 2,500 budget")
        XCTAssertEqual(stat.accessibilityLabel, "Context cost, 2,001, near Claude Code's 2,500 budget")
    }

    func testExceededCopyFormatsRawEstimateAndBudget() {
        let stat = contextCost(tokens: 2_501)

        XCTAssertEqual(stat.value, "2,501")
        XCTAssertEqual(stat.detail, "over Claude Code's 2,500 budget")
        XCTAssertEqual(stat.accessibilityLabel, "Context cost, 2,501, over Claude Code's 2,500 budget")
    }

    func testBudgetAndEstimateUseTheSameLocale() {
        let stat = contextCost(tokens: 2_501, locale: Locale(identifier: "de_DE"))

        XCTAssertEqual(stat.value, "2.501")
        XCTAssertEqual(stat.detail, "over Claude Code's 2.500 budget")
    }
}
