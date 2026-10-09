import XCTest
@testable import Pensieve

final class SkillExportModelTests: XCTestCase {
    private let fileService = FileService()
    private var root = ""
    private var skillsBase: String { root + "/skills" }
    private var source: String { skillsBase + "/export-skill/SKILL.md" }
    private var destination: String { root + "/exports/export-skill.md" }

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "SkillExportModelTests-" + UUID().uuidString
        try fileService.createDirectory(at: skillsBase + "/export-skill")
        try fileService.createDirectory(at: root + "/exports")
        // BOM, CRLF, a preserved frontmatter key, decomposed Unicode, and no final newline.
        let content = "\u{FEFF}---\r\nname: Export\r\ndescription: Original\r\nallowed-tools: Read\r\n---\r\nCafe\u{301}"
        try fileService.writeData(at: source, data: Data(content.utf8))
        try fileService.writeFile(at: skillsBase + "/export-skill/notes.txt", content: "Not exported")
    }

    override func tearDownWithError() throws {
        try fileService.deleteDirectory(at: root)
    }

    func testExportPreservesStoredBytesIncludingExtraFrontmatter() throws {
        let expected = try fileService.readData(at: source)
        let model = makeModel()

        try model.export(to: destination)
        XCTAssertEqual(try fileService.readData(at: destination), expected)
        XCTAssertEqual(try fileService.listDirectory(at: root + "/exports"), ["export-skill.md"])
        XCTAssertEqual(model.suggestedFileName, "export-skill.md")
    }

    func testExportReplacesAnExistingDestination() throws {
        try fileService.writeFile(at: destination, content: "Replace this")
        try makeModel().export(to: destination)
        XCTAssertEqual(try fileService.readData(at: destination), try fileService.readData(at: source))
    }

    func testMissingSourceSurfacesAnErrorAndWritesNothing() throws {
        try fileService.deleteFile(at: source)
        let model = makeModel()
        XCTAssertThrowsError(try model.export(to: destination))
        XCTAssertEqual(try fileService.listDirectory(at: root + "/exports"), [])
    }

    func testReadFailureLeavesExistingDestinationUntouched() throws {
        try fileService.writeFile(at: destination, content: "Keep this")
        // A regular file passes admission, but the actual read must report permission denied.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source) }
        let model = makeModel()
        XCTAssertThrowsError(try model.export(to: destination))
        XCTAssertEqual(try fileService.readFile(at: destination), "Keep this")
        XCTAssertEqual(try fileService.listDirectory(at: root + "/exports"), ["export-skill.md"])
    }

    func testWriteFailureSurfacesAnErrorAndLeavesNoPartialCopy() throws {
        try fileService.createDirectory(at: destination)
        try fileService.writeFile(at: destination + "/keep.txt", content: "Keep this")
        let model = makeModel()
        XCTAssertThrowsError(try model.export(to: destination))
        XCTAssertEqual(try fileService.readFile(at: destination + "/keep.txt"), "Keep this")
        XCTAssertEqual(try fileService.listDirectory(at: root + "/exports"), ["export-skill.md"])
        XCTAssertEqual(try fileService.listDirectory(at: destination), ["keep.txt"])
    }

    func testExportDoesNotRequireUTF8Decoding() throws {
        let bytes = Data([0xFF, 0xFE, 0x00, 0x61])
        try fileService.writeData(at: source, data: bytes)
        try makeModel().export(to: destination)
        XCTAssertEqual(try fileService.readData(at: destination), bytes)
    }

    func testUnsavedMessageTracksOnlyTheExportedSkillsDraft() throws {
        let store = SkillStore(fileService: fileService, baseDir: skillsBase, storeRoot: skillsBase)
        let library = SkillLibraryViewModel(
            skillStore: store,
            fileService: fileService, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: root
        )
        let skill = Skill(name: "Export", directoryName: "export-skill")
        let other = Skill(name: "Other", directoryName: "other")
        library.setLastWrittenBody("Saved", directoryName: skill.directoryName)
        XCTAssertFalse(SkillExportModel(skill: skill, library: library).message.contains("Unsaved"))
        library.noteEditorChanged(other, body: "Another skill's draft")
        XCTAssertFalse(SkillExportModel(skill: skill, library: library).message.contains("Unsaved"))
        library.noteEditorChanged(skill, body: "Unsaved draft")
        let dirtyModel = SkillExportModel(skill: skill, library: library)
        XCTAssertTrue(dirtyModel.message.contains("Unsaved changes aren't included."))
        try dirtyModel.export(to: destination)
        XCTAssertEqual(try fileService.readData(at: destination), try fileService.readData(at: source))
        XCTAssertTrue(library.hasUnsavedChanges(for: skill))
        library.noteEditorChanged(skill, body: "Saved")
        XCTAssertFalse(SkillExportModel(skill: skill, library: library).message.contains("Unsaved"))
    }

    @MainActor
    func testExportUsesTheRuntimeLibrarysRelocatedStore() throws {
        let paths = AppRuntimePaths(storeRoot: root + "/relocated", appSupportDir: root + "/support")
        let library = paths.makeLibrary(notifier: SyncStateNotifier.suppressed)
        let slug = try library.skillStore.createSkill(name: "Export Skill", description: "Relocated", body: "Right store")
        let relocatedFile = paths.skillsDir + "/" + slug + "/SKILL.md"
        let expected = Data("---\nname: Relocated\ndescription: d\nextra: preserved\n---\nRight store".utf8)
        try fileService.writeData(at: relocatedFile, data: expected)
        let model = SkillExportModel(skill: Skill(name: "Export", directoryName: slug), library: library)

        try model.export(to: destination)

        XCTAssertEqual(try fileService.readData(at: destination), expected)
        XCTAssertNotEqual(try fileService.readData(at: destination), try fileService.readData(at: source))
    }

    private func makeModel() -> SkillExportModel {
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: fileService, baseDir: skillsBase, storeRoot: skillsBase),
            fileService: fileService, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: root
        )
        return SkillExportModel(skill: Skill(name: "Export", directoryName: "export-skill"), library: library)
    }
}
