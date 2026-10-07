import XCTest
@testable import Pensieve

extension SkillOverviewPresentationTests {
    func testWarningPriorityAndTooltipRetainEveryApplicableWarning() {
        var snapshot = allLimitsSnapshot()
        snapshot.macStatus = [.codex: true, .claudeCode: true, .cursor: true]
        let tooltip = [
            "Codex skips this skill: its name is over 64 characters.",
            "Over the 5,000-token budget.",
            "Claude Code cuts off descriptions over 1,536 characters (description plus when_to_use).",
            "After compaction, Claude Code keeps only the first 5,000 tokens.",
            "Cursor loads this always-on rule into every chat."
        ]
        let stat = agentContext(snapshot, budget: 5_000)
        XCTAssertEqual(stat.detail, "Codex skips it: name too long")
        XCTAssertEqual(stat.warningSeverity, .exceeded)
        XCTAssertEqual(stat.value, "6,001")
        XCTAssertEqual(stat.tooltip, tooltip.joined(separator: "\n"))
        snapshot.frontmatterName = "short"
        XCTAssertEqual(agentContext(snapshot, budget: 5_000).detail, "over the 5,000-token budget")
        XCTAssertEqual(agentContext(snapshot, budget: 5_000).warningSeverity, .exceeded)
        XCTAssertEqual(agentContext(snapshot, budget: 5_000).tooltip, tooltip.dropFirst().joined(separator: "\n"))
        XCTAssertEqual(agentContext(snapshot).detail, "Claude Code cuts the description")
        XCTAssertEqual(agentContext(snapshot).warningSeverity, .warning)
        snapshot.frontmatterDescription = "short"
        XCTAssertEqual(agentContext(snapshot).detail, "past Claude Code's 5,000-token cutoff")
        snapshot.macStatus[.claudeCode] = false
        XCTAssertEqual(agentContext(snapshot, budget: 7_500).detail, "loads into every Cursor chat")
        snapshot.cursorAlwaysApply = false
        XCTAssertEqual(agentContext(snapshot, budget: 7_500).detail, "near the 7,500-token budget")
    }

    func testBudgetNearSuppressesCompactionLineButKeepsItsTooltip() {
        let snapshot = DetailContentSnapshot(tokenCount: 6_001, macStatus: [.claudeCode: true])
        let stat = agentContext(snapshot, budget: 7_500)
        XCTAssertEqual(stat.detail, "near the 7,500-token budget")
        XCTAssertEqual(stat.warningSeverity, .warning)
        XCTAssertEqual(stat.tooltip, "After compaction, Claude Code keeps only the first 5,000 tokens.\n"
                       + "Near the 7,500-token budget.")
        XCTAssertEqual(stat.accessibilityLabel, "Context cost, 6,001, near the 7,500-token budget")
    }

    func testBudgetTooltipsFormatBothSeveritiesForLocale() {
        for (tokens, detail, tooltip) in [
            (4_001, "near the 5.000-token budget", "Near the 5.000-token budget."),
            (5_001, "over the 5.000-token budget", "Over the 5.000-token budget.")
        ] {
            let snapshot = DetailContentSnapshot(tokenCount: tokens, macStatus: [.grok: true])
            let stat = agentContext(snapshot, budget: 5_000, locale: Locale(identifier: "de_DE"))
            XCTAssertEqual(stat.detail, detail)
            XCTAssertEqual(stat.tooltip, tooltip)
        }
    }
}
