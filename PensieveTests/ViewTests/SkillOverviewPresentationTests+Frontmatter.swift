import XCTest
@testable import Pensieve

extension SkillOverviewPresentationTests {
    private func loadedSnapshot(_ document: String, alwaysApply: Bool = false) throws -> DetailContentSnapshot {
        let files = FileService()
        let root = TestTemporaryDirectory.path + "AgentLimits-\(UUID().uuidString)"
        defer { try? files.deleteDirectory(at: root) }
        try files.writeFile(at: root + "/skills/fixture/SKILL.md", content: document)
        // The real store owns the file read. Other probes use a neutral fixture and no detected agents.
        let neutralFiles = DeployRecordingFileService()
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: files, baseDir: root + "/skills"),
                                            fileService: neutralFiles, manifestRoot: root)
        let platformVM = PlatformViewModel(fileService: neutralFiles, agentDetection: DeployStubDetection(installed: []),
                                           deployStateStore: .memoryBacked)
        let skill = Skill(name: String(repeating: "x", count: 65), skillDescription: String(repeating: "x", count: 10_000),
                          directoryName: "fixture", cursorConfig: CursorAdapterConfig(alwaysApply: alwaysApply))
        return DetailContentSnapshot.load(skill: skill, projects: [], library: library, platformVM: platformVM)
    }

    func testLoadedFrontmatterNameAndCombinedDescriptionDriveWarnings() throws {
        let document = "---\nname: '" + String(repeating: "n", count: 65)
            + "'\ndescription: '" + String(repeating: "d", count: 1_500)
            + "'\nwhen_to_use: |-\n  " + String(repeating: "w", count: 37) + "\n---\nSmall body"
        var snapshot = try loadedSnapshot(document)
        snapshot.macStatus = [.codex: true, .claudeCode: true]
        XCTAssertEqual(agentContext(snapshot).detail, "Codex skips it: name too long")
        snapshot.macStatus[.codex] = false
        XCTAssertEqual(agentContext(snapshot).detail, "Claude Code cuts the description")
        XCTAssertEqual(agentContext(snapshot).value, "2")
        XCTAssertEqual(snapshot.body, "Small body")
        snapshot = try loadedSnapshot("---\nname: Short file name\ndescription: File description\n---\nSmall body")
        snapshot.macStatus = [.codex: true]
        XCTAssertNil(agentContext(snapshot).warningSeverity, "The long database name must not replace the file's name")
    }

    func testMissingFrontmatterDoesNotUseDatabaseMetadataForLimits() throws {
        var snapshot = try loadedSnapshot("A body without frontmatter")
        snapshot.macStatus = [.claudeCode: true, .codex: true]
        XCTAssertNil(agentContext(snapshot).warningSeverity)
        XCTAssertNil(agentContext(snapshot).tooltip)
    }

    func testLoadedCursorConfigControlsAlwaysOnWarning() throws {
        let document = "---\nname: Fixture\ndescription: Small description\n---\n" + String(repeating: "b", count: 2_004)
        for alwaysApply in [false, true] {
            var snapshot = try loadedSnapshot(document, alwaysApply: alwaysApply)
            snapshot.macStatus = [.cursor: true]
            XCTAssertEqual(agentContext(snapshot).warningSeverity, alwaysApply ? .warning : nil)
            XCTAssertEqual(agentContext(snapshot).detail,
                           alwaysApply ? "loads into every Cursor chat" : "tokens when loaded")
            XCTAssertEqual(agentContext(snapshot).value, "501")
        }
    }
}
