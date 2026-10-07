import XCTest
@testable import Pensieve

extension SkillOverviewPresentationTests {
    private func contextCost(tokens: Int, mac: [PlatformTarget: Bool] = [.claudeCode: true],
                             projects: [UUID: [PlatformTarget: Bool]] = [:], budget: Int = 5_000,
                             locale: Locale = Locale(identifier: "en_US")) -> SkillOverviewPresentation.Stat {
        let snapshot = DetailContentSnapshot(tokenCount: tokens, macStatus: mac, projectStatus: projects)
        return SkillOverviewPresentation.stats(snapshot: snapshot, installedCount: 4, budget: budget, locale: locale)[0]
    }

    func testUndeployedSkillNeverWarns() {
        let stat = contextCost(tokens: 100_000, mac: [.claudeCode: false, .grok: false],
                               projects: [UUID(): [.claudeCode: false, .cursor: false]])
        XCTAssertNil(stat.budgetWarning)
        XCTAssertEqual(stat.detail, "tokens when loaded")
        XCTAssertNil(contextCost(tokens: 100_000, mac: [:]).budgetWarning)
    }

    func testEveryUserWidePlatformUsesTheSharedBudget() {
        for platform in PlatformTarget.allCases {
            let stat = contextCost(tokens: 5_001, mac: [platform: true])
            XCTAssertEqual(stat.budgetWarning, .exceeded, platform.displayName)
            XCTAssertEqual(stat.detail, "over the 5,000-token budget", platform.displayName)
        }
    }

    func testJustUnderEightyPercentHasNoWarning() {
        let stat = contextCost(tokens: 3_999)
        XCTAssertNil(stat.budgetWarning)
        XCTAssertEqual(stat.detail, "tokens when loaded")
    }

    func testExactlyEightyPercentHasNoWarning() {
        let stat = contextCost(tokens: 4_000)
        XCTAssertNil(stat.budgetWarning)
        XCTAssertEqual(stat.detail, "tokens when loaded")
    }

    func testJustOverEightyPercentWarns() {
        let stat = contextCost(tokens: 4_001)
        XCTAssertEqual(stat.budgetWarning, .warning)
        XCTAssertEqual(stat.detail, "near the 5,000-token budget")
    }

    func testExactlyOneHundredPercentWarns() {
        let stat = contextCost(tokens: 5_000)
        XCTAssertEqual(stat.budgetWarning, .warning)
        XCTAssertEqual(stat.detail, "near the 5,000-token budget")
    }

    func testJustOverOneHundredPercentIsExceeded() {
        let stat = contextCost(tokens: 5_001)
        XCTAssertEqual(stat.budgetWarning, .exceeded)
        XCTAssertEqual(stat.detail, "over the 5,000-token budget")
    }

    func testZeroAndNegativeBudgetsTurnWarningOff() {
        for budget in [0, -5_000] {
            let stat = contextCost(tokens: 100_000, budget: budget)
            XCTAssertNil(stat.budgetWarning)
            XCTAssertEqual(stat.detail, "tokens when loaded")
        }
    }

    func testCustomBudgetControlsBothThresholds() {
        for (tokens, warning) in [(80, nil), (81, SkillOverviewPresentation.BudgetWarning.warning), (101, .exceeded)] {
            XCTAssertEqual(contextCost(tokens: tokens, budget: 100).budgetWarning, warning)
        }
    }

    func testEveryProjectPlatformUsesTheSharedBudget() {
        for platform in PlatformTarget.allCases where platform.supportsProjectScope {
            let stat = contextCost(tokens: 5_001, mac: [platform: false],
                                   projects: [UUID(): [platform: false], UUID(): [platform: true]])
            XCTAssertEqual(stat.budgetWarning, .exceeded, platform.displayName)
            XCTAssertEqual(stat.detail, "over the 5,000-token budget", platform.displayName)
        }
    }

    func testWarningCopyFormatsEstimateAndBudgetForAccessibility() {
        let stat = contextCost(tokens: 4_001)
        XCTAssertEqual(stat.value, "4,001")
        XCTAssertEqual(stat.accessibilityLabel, "Context cost, 4,001, near the 5,000-token budget")
    }

    func testExceededCopyFormatsEstimateAndBudgetForAccessibility() {
        let stat = contextCost(tokens: 5_001)
        XCTAssertEqual(stat.value, "5,001")
        XCTAssertEqual(stat.accessibilityLabel, "Context cost, 5,001, over the 5,000-token budget")
    }

    func testBudgetAndEstimateUseTheSameLocale() {
        let stat = contextCost(tokens: 5_001, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(stat.value, "5.001")
        XCTAssertEqual(stat.detail, "over the 5.000-token budget")
    }

    func testLongFrontmatterDoesNotInflateContextCost() throws {
        let files = FileService()
        let root = TestTemporaryDirectory.path + "SkillSizeBudget-\(UUID().uuidString)"
        defer { try? files.deleteDirectory(at: root) }
        let body = String(repeating: "😀", count: 403)
        let document = "---\nname: Small body\ndescription: " + String(repeating: "x", count: 24_000) + "\n---\n" + body
        try files.writeFile(at: root + "/skills/small/SKILL.md", content: document)
        // Only the injected store reads disk; inventory and platform probes use an empty fixture.
        let neutralFiles = DeployRecordingFileService()
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: files, baseDir: root + "/skills"),
                                            fileService: neutralFiles, manifestRoot: root)
        let platformVM = PlatformViewModel(fileService: neutralFiles, agentDetection: DeployStubDetection(installed: []),
                                           deployStateStore: .memoryBacked)
        let skill = Skill(name: "Small body", directoryName: "small")
        var snapshot = DetailContentSnapshot.load(skill: skill, projects: [], library: library, platformVM: platformVM)
        snapshot.macStatus = [.codex: true]
        let stat = SkillOverviewPresentation.stats(snapshot: snapshot, installedCount: 1,
                                                   budget: 5_000, locale: Locale(identifier: "en_US"))[0]
        XCTAssertEqual(stat.value, "100", "Context cost counts body characters divided by four, excluding frontmatter")
        XCTAssertNil(stat.budgetWarning, "Long frontmatter must not push a short deployed body over its budget")
        XCTAssertEqual(stat.detail, "tokens when loaded")
    }
}
