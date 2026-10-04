import XCTest
@testable import Pensieve

@MainActor
final class SkillSaveRevisionTests: XCTestCase {
    func testSavedCRLFDraftAndLFEditorEchoStayCleanAndLeaveWithoutPrompt() throws {
        let files = FileService()
        let root = NSTemporaryDirectory() + "CleanCRLF-" + UUID().uuidString
        defer { try? files.deleteDirectory(at: root) }
        let store = SkillStore(fileService: files, baseDir: root)
        let slug = try store.createSkill(name: "Test", description: "D", body: "Old")
        try files.writeFile(at: root + "/" + slug + "/SKILL.md",
                            content: "---\r\nname: Test\r\ndescription: D\r\n---\r\n\r\nOld\r\n")
        let presenter = RecordingPresenter()
        let watcher = RecordingWatcher()
        let library = SkillLibraryViewModel(skillStore: store, fileWatchService: watcher)
        library.unsavedChangesPresenter = presenter.present
        let skill = Skill(name: "Test", directoryName: slug)
        _ = library.editorBody(for: skill)
        library.startWatching()
        library.noteEditorChanged(skill, body: "Edited\nSecond")
        XCTAssertTrue(library.saveDraft(skill))
        library.noteEditorChanged(skill, body: "Edited\nSecond")
        XCTAssertFalse(library.hasUnsavedChanges(for: skill), "The LF editor echo must match the CRLF saved body")
        XCTAssertTrue(library.drafts.isEmpty)
        XCTAssertTrue(library.wasLastWrittenByApp(directoryName: slug, currentBody: "Edited\nSecond"))
        let token = library.reloadToken
        watcher.emit(slug)
        XCTAssertEqual(library.reloadToken, token)
        var left = false
        library.confirmLeaving(skill) { left = $0 }
        XCTAssertTrue(left)
        XCTAssertTrue(presenter.prompts.isEmpty)
    }

    func testByteIdenticalSaveKeepsFileAndSkillTimestampsAndWritesNothing() throws {
        let files = PreviewImageFileSpy()
        let root = NSTemporaryDirectory() + "NoOpSave-" + UUID().uuidString
        defer { try? files.files.deleteDirectory(at: root) }
        let store = SkillStore(fileService: files, baseDir: root)
        let slug = try store.createSkill(name: "Test", description: "D", body: "Body")
        let path = root + "/" + slug + "/SKILL.md"
        try files.files.touchRegularFile(at: path, date: Date(timeIntervalSince1970: 1_000))
        let before = try XCTUnwrap(files.files.regularFileMetadata(at: path))
        let source = try files.files.readFile(at: path)
        let skill = Skill(name: "Test", skillDescription: "D", directoryName: slug)
        let timestamp = skill.updatedAt
        var nudges = 0
        let library = SkillLibraryViewModel(skillStore: store, notifier: { nudges += 1 })
        let writes = files.writes.count
        XCTAssertTrue(library.updateBody(skill, body: "Body\n"))
        XCTAssertEqual(files.writes.count, writes, "Byte-identical saves must not write the file")
        XCTAssertEqual(files.files.regularFileMetadata(at: path), before)
        XCTAssertEqual(skill.updatedAt, timestamp)
        XCTAssertEqual(try files.files.readFile(at: path), source)
        XCTAssertEqual(nudges, 0)
    }

    func testSaveSerializesOnlyInStoreAndFingerprintsTheStoresActualContent() throws {
        let source = try sourceFile("Pensieve/ViewModels/SkillLibraryViewModel+Write.swift")
        XCTAssertFalse(source.contains("SkillSerializer.rewrite"), "The store owns the single serialization")
        let store = CountingSkillStore(body: "Old")
        store.rewriteOverride = "Stored\r\nSecond"
        let skill = Skill(name: "Test", directoryName: "test")
        let library = SkillLibraryViewModel(skillStore: store)
        XCTAssertTrue(library.updateBody(skill, body: "Requested\nSecond"))
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertTrue(library.wasLastWrittenByApp(directoryName: "test", currentBody: "Stored\r\nSecond"),
                      "The fingerprint must describe the content returned by the store")
        XCTAssertFalse(library.wasLastWrittenByApp(directoryName: "test", currentBody: "Requested\nSecond"))
    }

    func testDraftAlreadyOnDiskClearsWithoutWriteTimestampOrSyncNudge() throws {
        let files = PreviewImageFileSpy()
        let root = NSTemporaryDirectory() + "CaughtUpSave-" + UUID().uuidString
        defer { try? files.files.deleteDirectory(at: root) }
        let store = SkillStore(fileService: files, baseDir: root)
        let slug = try store.createSkill(name: "Test", description: "D", body: "Old")
        let path = root + "/" + slug + "/SKILL.md"
        let skill = Skill(name: "Test", skillDescription: "D", directoryName: slug)
        var nudges = 0
        let library = SkillLibraryViewModel(skillStore: store, notifier: { nudges += 1 })
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "Edited")
        try files.files.writeFile(at: path, content: SkillSerializer.serialize(name: "Test", description: "D", body: "Edited"))
        let before = try XCTUnwrap(files.files.regularFileMetadata(at: path))
        let timestamp = skill.updatedAt
        let writes = files.writes.count
        XCTAssertTrue(library.saveDraft(skill))
        XCTAssertEqual(files.writes.count, writes, "A draft already on disk must not write again")
        XCTAssertEqual(files.files.regularFileMetadata(at: path), before)
        XCTAssertEqual(skill.updatedAt, timestamp)
        XCTAssertEqual(nudges, 0, "A byte-identical save must not nudge sync")
        XCTAssertTrue(library.drafts.isEmpty)
        XCTAssertTrue(library.wasLastWrittenByApp(directoryName: slug, currentBody: "Edited"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try FileService().readFile(at: root.appendingPathComponent(relativePath).path)
    }
}
