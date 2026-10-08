import SwiftData
import XCTest
@testable import Pensieve

final class SkillPreservingWriteTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var store: SkillStore!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensievePreservingWriteTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        store = SkillStore(fileService: fileService, baseDir: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    func testEditPreservesUpstreamFrontmatterAndSecondSaveIsByteIdentical() throws {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self, Category.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let vm = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        let original = """
        ---
        # upstream comment
        name: Installed
        description: Installed description
        license: Apache-2.0
        allowed-tools:
          - Read
        metadata:
          owner: upstream
        ---

        Old body
        """ + "\n"
        try fileService.createDirectory(at: tempDir + "/installed")
        try fileService.writeFile(at: tempDir + "/installed/SKILL.md", content: original)
        let skill = Skill(
            name: "Installed",
            skillDescription: "Installed description",
            directoryName: "installed"
        )
        context.insert(skill)
        let beforeFrontmatter = try XCTUnwrap(SkillParser.parse(original).preservedFrontmatter?.source)

        _ = vm.editorBody(for: skill)
        vm.noteEditorChanged(skill, body: "Edited body")
        XCTAssertTrue(vm.saveDraft(skill))
        let first = try fileService.readFile(at: tempDir + "/installed/SKILL.md")
        XCTAssertEqual(SkillParser.parse(first).preservedFrontmatter?.source, beforeFrontmatter)
        XCTAssertEqual(SkillParser.parse(first).body, "Edited body")
        XCTAssertEqual(SkillParser.parse(first).trailingLineBreaks, "\n")
        XCTAssertTrue(vm.wasLastWrittenByApp(directoryName: "installed", currentBody: "Edited body"))

        vm.noteEditorChanged(skill, body: "Edited body\n")
        XCTAssertTrue(vm.saveDraft(skill))
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/installed/SKILL.md"), first)
    }

    func testCreateStillWritesTheExactCanonicalBytes() throws {
        let slug = try store.createSkill(name: "Canonical", description: "Only two keys", body: "Body")
        XCTAssertEqual(
            try fileService.readFile(at: tempDir + "/\(slug)/SKILL.md"),
            SkillSerializer.serialize(name: "Canonical", description: "Only two keys", body: "Body")
        )
    }
}
