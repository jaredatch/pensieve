import XCTest
@testable import Pensieve

extension SkillOverviewPresentationTests {
    func agentContext(_ snapshot: DetailContentSnapshot, budget: Int = 0,
                      locale: Locale = Locale(identifier: "en_US")) -> SkillOverviewPresentation.Stat {
        SkillOverviewPresentation.stats(snapshot: snapshot, installedCount: 6, budget: budget, locale: locale)[0]
    }

    func allLimitsSnapshot() -> DetailContentSnapshot {
        DetailContentSnapshot(tokenCount: 6_001, frontmatterName: String(repeating: "n", count: 65),
                              frontmatterDescription: String(repeating: "d", count: 1_537), cursorAlwaysApply: true)
    }

    func testCodexNameAtAndPast64Characters() {
        var snapshot = DetailContentSnapshot(tokenCount: 10, macStatus: [.codex: true])
        snapshot.frontmatterName = String(repeating: "n", count: 64)
        XCTAssertNil(agentContext(snapshot).warningSeverity)
        XCTAssertNil(agentContext(snapshot).tooltip)
        snapshot.frontmatterName += "n"
        let stat = agentContext(snapshot)
        XCTAssertEqual(stat.detail, "Codex skips it: name too long")
        XCTAssertEqual(stat.warningSeverity, .exceeded)
        XCTAssertEqual(stat.value, "10")
        XCTAssertEqual(stat.tooltip, "Codex skips this skill: its name is over 64 characters.")
        XCTAssertEqual(stat.accessibilityLabel, "Context cost, 10, Codex skips it: name too long")
        // Two scalars per composed character: match the loader's count, rather than Swift's grapheme count.
        snapshot.frontmatterName = String(repeating: "e\u{301}", count: 32)
        XCTAssertNil(agentContext(snapshot).warningSeverity)
        snapshot.frontmatterName += "n"
        XCTAssertEqual(agentContext(snapshot).warningSeverity, .exceeded)
    }

    func testClaudeDescriptionAtAndPast1536WithoutWhenToUse() {
        var snapshot = DetailContentSnapshot(macStatus: [.claudeCode: true])
        snapshot.frontmatterDescription = String(repeating: "d", count: 1_536)
        XCTAssertNil(agentContext(snapshot).warningSeverity)
        snapshot.frontmatterDescription += "d"
        let stat = agentContext(snapshot)
        XCTAssertEqual(stat.detail, "Claude Code cuts the description")
        XCTAssertEqual(stat.warningSeverity, .warning)
        XCTAssertEqual(stat.tooltip,
                       "Claude Code cuts off descriptions over 1,536 characters (description plus when_to_use).")
    }

    func testClaudeCombinedDescriptionAtAndPast1536() {
        var snapshot = DetailContentSnapshot(macStatus: [.claudeCode: true])
        snapshot.frontmatterDescription = String(repeating: "d", count: 1_500)
        snapshot.frontmatterWhenToUse = String(repeating: "w", count: 36)
        XCTAssertNil(agentContext(snapshot).warningSeverity)
        snapshot.frontmatterWhenToUse += "w"
        XCTAssertEqual(agentContext(snapshot).detail, "Claude Code cuts the description")
        XCTAssertEqual(agentContext(snapshot).warningSeverity, .warning)
    }

    func testClaudeCompactionAtAndPast5000WithBudgetDisabled() {
        var snapshot = DetailContentSnapshot(tokenCount: 5_000, macStatus: [.claudeCode: true])
        XCTAssertNil(agentContext(snapshot).warningSeverity)
        snapshot.tokenCount = 5_001
        for budget in [0, -1, 10_000] {
            let stat = agentContext(snapshot, budget: budget)
            XCTAssertEqual(stat.detail, "past Claude Code's 5,000-token cutoff")
            XCTAssertEqual(stat.warningSeverity, .warning)
            XCTAssertEqual(stat.value, "5,001")
            XCTAssertEqual(stat.tooltip, "After compaction, Claude Code keeps only the first 5,000 tokens.")
        }
    }

    func testCursorAlwaysOnAtAndPast500Tokens() {
        var snapshot = DetailContentSnapshot(tokenCount: 500, cursorAlwaysApply: true, macStatus: [.cursor: true])
        XCTAssertNil(agentContext(snapshot).warningSeverity)
        snapshot.tokenCount = 501
        let stat = agentContext(snapshot)
        XCTAssertEqual(stat.detail, "loads into every Cursor chat")
        XCTAssertEqual(stat.warningSeverity, .warning)
        XCTAssertEqual(stat.tooltip, "Cursor loads this always-on rule into every chat.")
    }

    func testConditionalCursorRuleNeverGetsAlwaysOnWarning() {
        let snapshot = DetailContentSnapshot(tokenCount: 100_000, cursorAlwaysApply: false, macStatus: [.cursor: true])
        XCTAssertNil(agentContext(snapshot).warningSeverity)
        XCTAssertNil(agentContext(snapshot).tooltip)
        XCTAssertEqual(agentContext(snapshot).detail, "tokens when loaded")
    }

    func testUndeployedAndUnlimitedAgentsHaveNoAgentWarnings() {
        var snapshot = allLimitsSnapshot()
        XCTAssertNil(agentContext(snapshot).tooltip)
        for platform in PlatformTarget.allCases {
            snapshot.macStatus = [platform: false]
            snapshot.projectStatus = [UUID(): [platform: false]]
            XCTAssertNil(agentContext(snapshot).warningSeverity, platform.displayName)
            XCTAssertNil(agentContext(snapshot).tooltip, platform.displayName)
        }
        for platform in [PlatformTarget.grok, .openClaw, .hermes] {
            snapshot.macStatus = [platform: true]
            snapshot.projectStatus = [:]
            XCTAssertNil(agentContext(snapshot).tooltip, platform.displayName)
        }
    }

    func testEachAgentChecksOnlyItsOwnLimits() {
        var snapshot = allLimitsSnapshot()
        for (platform, tooltip) in [
            (PlatformTarget.codex, "Codex skips this skill: its name is over 64 characters."),
            (.claudeCode, "Claude Code cuts off descriptions over 1,536 characters (description plus when_to_use).\n"
                + "After compaction, Claude Code keeps only the first 5,000 tokens."),
            (.cursor, "Cursor loads this always-on rule into every chat.")
        ] {
            snapshot.macStatus = [platform: true]
            XCTAssertEqual(agentContext(snapshot).tooltip, tooltip, platform.displayName)
        }
    }

    func testEachAgentLimitAppliesInAnyRegisteredProject() {
        var snapshot = allLimitsSnapshot()
        for (platform, detail, severity) in [
            (PlatformTarget.codex, "Codex skips it: name too long", SkillOverviewPresentation.WarningSeverity.exceeded),
            (.claudeCode, "Claude Code cuts the description", .warning),
            (.cursor, "loads into every Cursor chat", .warning)
        ] {
            snapshot.macStatus = [platform: false]
            snapshot.projectStatus = [UUID(): [platform: false], UUID(): [platform: true]]
            XCTAssertEqual(agentContext(snapshot).detail, detail, platform.displayName)
            XCTAssertEqual(agentContext(snapshot).warningSeverity, severity, platform.displayName)
            snapshot.projectStatus = [:]
        }
    }

    func testNoWarningMeansNoTooltipOnAnyCard() {
        let snapshot = DetailContentSnapshot(tokenCount: 500, cursorAlwaysApply: true,
                                             macStatus: [.claudeCode: true, .codex: true, .cursor: true])
        let stats = SkillOverviewPresentation.stats(snapshot: snapshot, installedCount: 3, budget: 5_000)
        XCTAssertTrue(stats.allSatisfy { $0.tooltip == nil })
        XCTAssertTrue(stats.allSatisfy { $0.warningSeverity == nil })
        XCTAssertEqual(stats[0].detail, "tokens when loaded")
    }
}
