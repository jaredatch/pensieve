import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillSaveRevisionTests: XCTestCase {
    func testUnchangedDescriptionSaveLeavesModelContextClean() throws {
        let files = FileService()
        let root = NSTemporaryDirectory() + "DescriptionGuard-" + UUID().uuidString
        defer { try? files.deleteDirectory(at: root) }
        let store = SkillStore(fileService: files, baseDir: root)
        let slug = try store.createSkill(name: "Test", description: "D", body: "Body")
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, IntentAssignment.self,
            DeployRecord.self, Pensieve.Category.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let skill = Skill(name: "Test", skillDescription: "D", directoryName: slug)
        context.insert(skill)
        try context.save()
        XCTAssertFalse(context.hasChanges)
        let library = SkillLibraryViewModel(skillStore: store)
        XCTAssertEqual(library.updateBody(skill, body: "Body"), .unchanged)
        XCTAssertFalse(context.hasChanges, "An equal model description must not be assigned again")
    }

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
        let files = PreviewImageFileSpy()
        let root = NSTemporaryDirectory() + "RewriteReport-" + UUID().uuidString
        defer { try? files.files.deleteDirectory(at: root) }
        let store = SkillStore(fileService: files, baseDir: root)
        let slug = try store.createSkill(name: "Test", description: "D", body: "Body")
        for body in ["Body\n", "Edited"] {
            let parsed = SkillParser.parse(try store.readBody(directoryName: slug))
            let serialized = SkillSerializer.rewrite(body: body, preserving: parsed,
                                                    fallbackName: "Test", fallbackDescription: "D")
            let before = files.writes.count
            let stored = try store.rewriteSkill(directoryName: slug, body: body, preserving: parsed,
                                                fallbackName: "Test", fallbackDescription: "D")
            XCTAssertEqual(stored.content, serialized.content)
            XCTAssertEqual(stored.didChange, serialized.didChange)
            XCTAssertEqual(stored.didChange, body == "Edited")
            XCTAssertEqual(files.writes.count - before, serialized.didChange ? 1 : 0)
        }
    }

    func testDraftAndSerializerShareOneLineEndingNormalizer() {
        let cases = [("First\r\nSecond", "\nFirst\nSecond\n", true),
                     ("First\rSecond", "First\nSecond", true),
                     ("Body", "Changed", false), ("\u{85}Body", "Body", true),
                     ("Body\u{2028}", "Body", true), ("Caf\u{e9}", "Cafe\u{301}", true)]
        for (original, draft, expected) in cases {
            let source = "---\nname: Test\ndescription: D\n---\n" + original + "\n"
            let parsed = SkillParser.parse(source)
            let serialized = SkillSerializer.rewrite(body: draft, preserving: parsed,
                                                    fallbackName: "Test", fallbackDescription: "D")
            let matches = SkillLibraryViewModel.bodiesMatch(draft, parsed.body)
            XCTAssertEqual(matches, expected)
            XCTAssertEqual(matches, !serialized.didChange)
            if matches { XCTAssertEqual(Data(serialized.content.utf8), Data(source.utf8)) }
        }
    }

    func testBodyUpdateReturnsItsOutcomeWithoutANotifierTypedCallback() throws {
        let files = FileService()
        let root = NSTemporaryDirectory() + "WriteOutcome-" + UUID().uuidString
        defer { try? files.deleteDirectory(at: root) }
        let store = SkillStore(fileService: files, baseDir: root)
        let slug = try store.createSkill(name: "Test", description: "D", body: "Body")
        let skill = Skill(name: "Test", skillDescription: "D", directoryName: slug)
        var publishedDirty: [Bool] = []
        var library: SkillLibraryViewModel!
        library = SkillLibraryViewModel(skillStore: store, notifier: { publishedDirty.append(library.hasUnsavedChanges) })
        XCTAssertEqual(library.updateBody(skill, body: "Body"), .unchanged)
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "Edited")
        XCTAssertTrue(library.saveDraft(skill))
        XCTAssertEqual(publishedDirty, [false], "The draft must be clean before a changed save notifies")
        XCTAssertEqual(library.updateBody(skill, body: "Another"), .written)
        XCTAssertEqual(try store.readBody(directoryName: slug),
                       SkillSerializer.serialize(name: "Test", description: "D", body: "Another"))
        try files.deleteFile(at: root + "/" + slug + "/SKILL.md")
        XCTAssertEqual(library.updateBody(skill, body: "Missing"), .failed)
    }
}
