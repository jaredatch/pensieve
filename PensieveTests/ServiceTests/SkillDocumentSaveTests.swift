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

    func testSaveBeforeWatcherAsksForFrontmatterAndBodyChangesAndSaveAnswerOverwrites() async throws {
        let source = "---\nname: Test\ndescription: Before\n---\nBody\n"
        let scenarios = ["no cycle", "change during cycle", "change before cycle", "cancel before cycle", "returns to baseline"]
        for scenario in scenarios {
            for outside in [source.replacingOccurrences(of: "Before", with: "Outside"),
                            source.replacingOccurrences(of: "Body", with: "Outside body")] {
                // A leaving question after Cancel already authorizes overwrite; the other entries defer a new question.
                let entries = scenario == "cancel before cycle" ? ["direct", "command"] : ["direct", "command", "leaving"]
                for entry in entries {
                    let fixture = try DocumentSaveFixture()
                    defer { fixture.cleanup() }
                    try fixture.write(source)
                    _ = fixture.library.editorBody(for: fixture.skill)
                    let draft = source.replacingOccurrences(of: "Body", with: "My draft")
                    fixture.library.noteEditorChanged(fixture.skill, body: draft)
                    let beforeCycle = scenario == "change before cycle" || scenario == "cancel before cycle"
                    if scenario != "no cycle", !beforeCycle { fixture.library.beginCoordinatorChanges() }
                    try fixture.write(outside)
                    if scenario == "cancel before cycle" {
                        fixture.watcher.emit("test")
                        XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, .externalChange)
                        fixture.library.resolveUnsavedChanges(.cancel)
                    }
                    if beforeCycle { fixture.library.beginCoordinatorChanges() }
                    let promptCount = fixture.presenter.prompts.count
                    XCTAssertFalse(attemptSave(fixture, entry: entry), "\(scenario), \(entry)")
                    XCTAssertEqual(try fixture.read(), outside)
                    XCTAssertEqual(fixture.library.drafts["test"]?.body, draft)
                    if scenario != "no cycle" {
                        XCTAssertNil(fixture.library.pendingUnsavedChanges, "Wait for the cycle's final text")
                        fixture.watcher.emit("test") // The delayed watcher echo must not swallow the question.
                        if scenario == "returns to baseline" { try fixture.write(source) }
                        await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)
                    }
                    XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, .externalChange, "\(scenario), \(entry)")
                    XCTAssertEqual(fixture.presenter.prompts.count, promptCount + (entry == "leaving" ? 2 : 1))
                    fixture.library.resolveUnsavedChanges(.save)
                    XCTAssertEqual(try fixture.read(), draft)
                    XCTAssertFalse(fixture.library.hasUnsavedChanges)
                }
            }
        }
    }

    private func attemptSave(_ fixture: DocumentSaveFixture, entry: String) -> Bool {
        switch entry {
        case "command": return fixture.library.saveUnsavedDrafts()
        case "leaving":
            var proceeded = true
            fixture.library.confirmLeaving(fixture.skill) { proceeded = $0 }
            fixture.library.resolveUnsavedChanges(.save)
            return proceeded
        default: return fixture.library.saveDraft(fixture.skill)
        }
    }
}

@MainActor
final class DocumentSaveFixture {
    let files = FileService()
    let container: ModelContainer
    let root = TestTemporaryDirectory.path + "WholeDocument-" + UUID().uuidString
    let store: SkillStore
    let watcher = RecordingWatcher()
    let library: SkillLibraryViewModel
    let skill = Skill(name: "Test", skillDescription: "Before", directoryName: "test")
    let presenter = RecordingPresenter()

    init(registerSkill: Bool = true) throws {
        container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        if registerSkill { context.insert(skill); try context.save() }
        store = SkillStore(fileService: files, baseDir: root + "/skills", storeRoot: root)
        library = SkillLibraryViewModel(skillStore: store, fileService: files, fileWatchService: watcher,
                                       manifestRoot: root)
        library.onSkillDocumentObserved = { [weak library] directoryName, document in
            library?.refreshSkillIdentity(directoryName: directoryName, document: document, context: context)
        }
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
