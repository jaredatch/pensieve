import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillDocumentSaveTests: XCTestCase {
    func testEditorLoadsWholeFileAndSavesDescriptionAndAdditionalKeysExactly() throws {
        let fixture = try DocumentSaveFixture()
        defer { fixture.cleanup() }
        let source = "---\nname: Test\ndescription: Before\n---\n\nBody\n"
        try fixture.write(source)
        XCTAssertEqual(fixture.library.editorBody(for: fixture.skill), source)
        let draft = source.replacingOccurrences(of: "Before", with: "After\nlicense: MIT")
        fixture.library.noteEditorChanged(fixture.skill, body: draft)
        XCTAssertTrue(fixture.library.saveDraft(fixture.skill))
        XCTAssertEqual(try fixture.read(), draft)
        XCTAssertEqual(fixture.skill.name, "Test")
        XCTAssertEqual(fixture.skill.skillDescription, "After")
        XCTAssertEqual(DetailContentSnapshot.load(skill: fixture.skill, projects: [], library: fixture.library,
            platformVM: PlatformViewModel(linkService: TestPaths.linkService(fileService: fixture.files),
                cursorCompiler: TestPaths.cursorCompiler(fileService: fixture.files),
                agentDetection: DeletionTestDetection(installed: []),
                deployStateStore: .memoryBacked, skillsDirectory: fixture.store.baseDir)).frontmatterDescription, "After")
        XCTAssertFalse(fixture.library.hasUnsavedChanges)
        let token = fixture.library.reloadToken
        fixture.watcher.emit("test")
        XCTAssertEqual(fixture.library.reloadToken, token)
        XCTAssertTrue(fixture.library.externallyModified.isEmpty)
    }

    func testInvalidFrontmatterKeepsFileDraftIdentityAndFingerprint() throws {
        let fixture = try DocumentSaveFixture()
        defer { fixture.cleanup() }
        let source = "---\nname: Test\ndescription: Before\n---\nBody\n"
        let cases = [
            ("---\nname: Test\ndescription: After\nBody", "can't be read"),
            ("---\nname: Test\ndescription: [\n---\nBody", "can't be read"),
            ("---\nname: Test\ndescription: before---after\n---\nBody", "can't be read"),
            ("---\n? [a, b]\n: value\nname: Test\ndescription: After\n---\nBody", "can't be read"),
            ("---\ndescription: After\n---\nBody", "name"),
            ("---\nname: Test\n---\nBody", "description"),
            ("---\nname: ''\ndescription: After\n---\nBody", "name"),
            ("---\nname: Test\ndescription: ''\n---\nBody", "description"),
            ("---\nname: Test\ndescription: 123\n---\nBody", "description"),
            ("---\nname: 123\ndescription: After\n---\nBody", "name"),
            ("---\nname: Other\ndescription: After\n---\nBody", "has to match its folder")
        ]
        for (draft, message) in cases {
            try fixture.write(source)
            _ = fixture.library.editorBody(for: fixture.skill)
            fixture.library.noteEditorChanged(fixture.skill, body: draft)
            XCTAssertFalse(fixture.library.saveDraft(fixture.skill), draft)
            XCTAssertEqual(try fixture.read(), source, draft)
            XCTAssertEqual(fixture.library.drafts["test"]?.body, draft)
            XCTAssertEqual(fixture.skill.skillDescription, "Before")
            XCTAssertTrue(fixture.library.wasLastWrittenByApp(directoryName: "test", currentBody: source))
            XCTAssertTrue(fixture.library.error?.contains(message) == true, fixture.library.error ?? "no error")
            fixture.library.discardDraft(fixture.skill)
        }
    }

    func testSaveBeforeWatcherAsksForFrontmatterAndBodyChangesAndSaveAnswerOverwrites() throws {
        let fixture = try DocumentSaveFixture()
        defer { fixture.cleanup() }
        let source = "---\nname: Test\ndescription: Before\n---\nBody\n"
        for outside in [source.replacingOccurrences(of: "Before", with: "Outside"),
                        source.replacingOccurrences(of: "Body", with: "Outside body")] {
            try fixture.write(source)
            _ = fixture.library.editorBody(for: fixture.skill)
            let draft = source.replacingOccurrences(of: "Body", with: "My draft")
            fixture.library.noteEditorChanged(fixture.skill, body: draft)
            try fixture.write(outside)
            XCTAssertFalse(fixture.library.saveDraft(fixture.skill))
            XCTAssertEqual(try fixture.read(), outside)
            XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, .externalChange)
            XCTAssertEqual(fixture.library.drafts["test"]?.body, draft)
            fixture.library.resolveUnsavedChanges(.save)
            XCTAssertEqual(try fixture.read(), draft)
            XCTAssertFalse(fixture.library.hasUnsavedChanges)
        }
    }
}

@MainActor
final class DocumentSaveFixture {
    let files = FileService()
    let root = TestTemporaryDirectory.path + "WholeDocument-" + UUID().uuidString
    let store: SkillStore
    let watcher = RecordingWatcher()
    let library: SkillLibraryViewModel
    let skill = Skill(name: "Test", skillDescription: "Before", directoryName: "test")
    let presenter = RecordingPresenter()

    init() throws {
        store = SkillStore(fileService: files, baseDir: root + "/skills", storeRoot: root)
        library = SkillLibraryViewModel(skillStore: store, fileService: files, fileWatchService: watcher,
                                       manifestRoot: root)
        library.unsavedChangesPresenter = presenter.present
        library.startWatching()
        try files.createDirectory(at: root + "/skills/test")
    }

    func write(_ content: String) throws {
        try files.writeFile(at: root + "/skills/test/SKILL.md", content: content)
    }
    func read() throws -> String { try store.readBody(directoryName: "test") }
    func cleanup() { try? files.deleteDirectory(at: root) }
}
