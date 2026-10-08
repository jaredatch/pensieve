import XCTest
@testable import Pensieve

/// Pins the editor-save premise that identity comes from the existing file, never from its model row.
final class SkillEditorIdentityPreservationTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var store: SkillStore!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveEditorIdentityTests-\(UUID().uuidString)"
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
    func testSaveNeverCopiesModelNameOrDescriptionIntoExistingFrontmatter() throws {
        let original = """
        ---
        name: "Identity From Disk"
        description: "Description From Disk"
        license: Apache-2.0
        ---

        Original body
        """ + "\n"
        let skill = Skill(
            name: "Different Model Name",
            skillDescription: "Different model description",
            directoryName: "identity"
        )
        try writeSkillFile(original, directoryName: skill.directoryName)
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )

        XCTAssertEqual(library.editorBody(for: skill), "Original body")
        library.noteEditorChanged(skill, body: "Edited body")
        XCTAssertTrue(library.saveDraft(skill))

        let saved = try readSkillFile(directoryName: skill.directoryName)
        XCTAssertEqual(saved, original.replacingOccurrences(of: "Original body", with: "Edited body"))
        XCTAssertEqual(skill.name, "Different Model Name")
        XCTAssertEqual(skill.skillDescription, "Different model description")
    }

    @MainActor
    func testEmptyModelDescriptionRepairDoesNotRewriteExistingFileIdentity() throws {
        let original = """
        ---
        name: "Identity From Disk"
        description: "Non-empty description from disk"
        metadata:
          owner: upstream
        ---

        Original body
        """ + "\n"
        let skill = Skill(name: "Model Fallback Name", skillDescription: "", directoryName: "repair")
        try writeSkillFile(original, directoryName: skill.directoryName)
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )

        XCTAssertEqual(library.editorBody(for: skill), "Original body")
        library.noteEditorChanged(skill, body: "Edited body")
        XCTAssertTrue(library.saveDraft(skill))

        let saved = try readSkillFile(directoryName: skill.directoryName)
        XCTAssertEqual(saved, original.replacingOccurrences(of: "Original body", with: "Edited body"))
        XCTAssertEqual(skill.skillDescription, "Model Fallback Name")
    }

    private func writeSkillFile(_ content: String, directoryName: String) throws {
        try fileService.createDirectory(at: tempDir + "/" + directoryName)
        try fileService.writeFile(at: tempDir + "/" + directoryName + "/SKILL.md", content: content)
    }

    private func readSkillFile(directoryName: String) throws -> String {
        try fileService.readFile(at: tempDir + "/" + directoryName + "/SKILL.md")
    }
}
