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
        XCTAssertTrue(library.updateBody(skill, body: "Body\n").succeeded)
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
        XCTAssertTrue(library.updateBody(skill, body: "Requested\nSecond").succeeded)
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

    func testNoOpSaveAppliesDescriptionFallbackWithoutWritingOrNudging() throws {
        for description in ["", " \t\n"] {
            for fromDraft in [false, true] {
                let files = PreviewImageFileSpy()
                let root = NSTemporaryDirectory() + "NoOpDescription-" + UUID().uuidString
                defer { try? files.files.deleteDirectory(at: root) }
                let store = SkillStore(fileService: files, baseDir: root)
                let slug = try store.createSkill(name: "Fallback", description: "D", body: "Old")
                let skill = Skill(name: "Fallback", skillDescription: description, directoryName: slug)
                var nudges = 0
                let library = SkillLibraryViewModel(skillStore: store, notifier: { nudges += 1 })
                let path = root + "/" + slug + "/SKILL.md"
                if fromDraft {
                    _ = library.editorBody(for: skill)
                    library.noteEditorChanged(skill, body: "Edited")
                    try files.files.writeFile(at: path, content: SkillSerializer.serialize(
                        name: "Fallback", description: "D", body: "Edited"
                    ))
                }
                let source = try files.files.readFile(at: path)
                let metadata = try XCTUnwrap(files.files.regularFileMetadata(at: path))
                let timestamp = skill.updatedAt
                let writes = files.writes.count
                let succeeded = fromDraft ? library.saveDraft(skill) : library.updateBody(skill, body: "Old").succeeded
                XCTAssertTrue(succeeded)
                XCTAssertEqual(skill.skillDescription, "Fallback", "A successful no-op save still fills the model description")
                XCTAssertEqual(files.writes.count, writes)
                XCTAssertEqual(files.files.regularFileMetadata(at: path), metadata)
                XCTAssertEqual(try files.files.readFile(at: path), source)
                XCTAssertEqual(skill.updatedAt, timestamp)
                XCTAssertEqual(nudges, 0)
            }
        }
    }

    func testStoreUsesTheSerializersUnchangedReportWithoutRederivingIt() throws {
        let store = try sourceFile("Pensieve/Services/SkillStore.swift")
        XCTAssertTrue(store.contains("SkillSerializer.rewriteResult("), "The serializer reports its unchanged branch")
        XCTAssertTrue(store.contains("guard !result.isUnchanged"), "The store writes unless the serializer reports unchanged")
        XCTAssertFalse(store.contains("preservedFile?.source ?? parsed.body"),
                       "The store must not copy the serializer's return rule")
        XCTAssertFalse(store.contains("content.utf8.elementsEqual"), "The store must not infer unchanged from content")
    }

    func testDraftAndSerializerShareOneLineEndingNormalizer() throws {
        let reads = try sourceFile("Pensieve/ViewModels/SkillLibraryViewModel+Reads.swift")
        let serializer = try sourceFile("Pensieve/Services/SkillSerializer.swift")
        XCTAssertTrue(reads.contains("SkillSerializer.normalizeLineEndings("), "Draft and echo checks use the shared helper")
        XCTAssertFalse(reads.contains("replacingOccurrences"), "Draft and echo checks must not duplicate normalization")
        XCTAssertEqual((reads + serializer).components(separatedBy: "func normalizeLineEndings(").count - 1, 1)
    }

    func testBodyUpdateReturnsItsOutcomeWithoutANotifierTypedCallback() throws {
        let write = try sourceFile("Pensieve/ViewModels/SkillLibraryViewModel+Write.swift")
        let draft = try sourceFile("Pensieve/ViewModels/SkillLibraryViewModel+Draft.swift")
        XCTAssertTrue(write.contains("func updateBody(_ skill: Skill, body: String) -> BodyUpdateOutcome"))
        XCTAssertFalse(write.contains("SyncStateNotifying"), "A write outcome is not a sync notifier")
        XCTAssertFalse(write.contains("onWrite"), "Return the outcome instead of invoking a report callback")
        XCTAssertTrue(draft.contains("let outcome = updateBody("))
        XCTAssertTrue(draft.contains("if outcome == .written { notifier() }"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try FileService().readFile(at: root.appendingPathComponent(relativePath).path)
    }
}
