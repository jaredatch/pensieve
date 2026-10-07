import SwiftData
import XCTest
@testable import Pensieve

extension SkillOverviewPresentationTests {
    @MainActor
    func testAgentLimitWarningsNeverBlockDeploy() throws {
        let physicalFiles = FileService()
        let root = TestTemporaryDirectory.path + "AgentAdvisory-\(UUID().uuidString)"
        defer { try? physicalFiles.deleteDirectory(at: root) }
        // The existing adapter confines canonical skills and all agent artifacts to this temporary root.
        let files = LinkServiceCanonicalDirectoryFileService(wrapped: physicalFiles, pathMappings: [
            (Constants.pensieveSkillsDir, root + "/skills"),
            (Constants.codexUserSkillsDir, root + "/codex"),
            (Constants.claudeCodeUserSkillsDir, root + "/claude"),
            (Constants.cursorUserRulesDir, root + "/cursor")
        ], physicalSandbox: root)
        let skill = Skill(name: String(repeating: "n", count: 65), skillDescription: String(repeating: "d", count: 1_537),
                          directoryName: "advisory-\(UUID().uuidString)", cursorConfig: CursorAdapterConfig(alwaysApply: true))
        let document = "---\nname: " + skill.name + "\ndescription: " + skill.skillDescription
            + "\n---\n" + String(repeating: "b", count: 24_004)
        try files.writeFile(at: skill.canonicalPath, content: document)
        let agents: [PlatformTarget] = [.codex, .claudeCode, .cursor]
        let platformVM = PlatformViewModel(fileService: files, agentDetection: DeployStubDetection(installed: agents),
                                           deployStateStore: .memoryBacked)
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: files), fileService: files,
                                            manifestRoot: root)
        let container = try ModelContainer(for: Skill.self, DeployRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.insert(skill)
        for agent in agents {
            platformVM.deploy(skill: skill, platform: agent, context: context)
            XCTAssertNil(platformVM.error, "Warnings must leave \(agent.displayName) deployable")
        }
        let snapshot = DetailContentSnapshot.load(skill: skill, projects: [], library: library, platformVM: platformVM)
        XCTAssertEqual(agentContext(snapshot, budget: 5_000).detail, "Codex skips it: name too long")
        XCTAssertTrue(agentContext(snapshot, budget: 5_000).tooltip?.contains("Claude Code cuts off descriptions") == true)
        XCTAssertTrue(agentContext(snapshot, budget: 5_000).tooltip?.contains("Cursor loads this always-on rule") == true)
        for agent in agents {
            platformVM.deploy(skill: skill, platform: agent, context: context)
            XCTAssertNil(platformVM.error, "Shown warnings must also allow redeploying to \(agent.displayName)")
        }
        XCTAssertTrue(physicalFiles.isSymlink(at: root + "/codex/" + skill.directoryName))
        XCTAssertTrue(physicalFiles.isSymlink(at: root + "/claude/" + skill.directoryName))
        XCTAssertTrue(physicalFiles.fileExists(at: root + "/cursor/" + skill.directoryName + ".mdc"))
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<DeployRecord>()).map(\.platform)), Set(agents))
    }
}
