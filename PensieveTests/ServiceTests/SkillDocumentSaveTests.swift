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
            ("---\nname: test\ndescription: After\n---\nBody", "change the name back to \"Test\"")
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
                let entries = scenario == "cancel before cycle" ? ["direct", "command"] : ["direct", "command", "leaving"]
                for entry in entries {
                    try await checkSaveQuestion(source: source, outside: outside, scenario: scenario, entry: entry)
                }
            }
        }
        try await checkQueuedSaves(source: source)
        try checkQuestionSnapshot(source: source)
    }

    private func checkSaveQuestion(source: String, outside: String, scenario: String, entry: String) async throws {
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
        if scenario == "cancel before cycle" {
            XCTAssertTrue(attemptSave(fixture, entry: entry), "Cancel acknowledges that outside text")
            XCTAssertEqual(try fixture.read(), draft)
            XCTAssertEqual(fixture.presenter.prompts.count, promptCount)
            await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)
            return
        }
        XCTAssertFalse(attemptSave(fixture, entry: entry), "\(scenario), \(entry)")
        if entry == "leaving" { XCTAssertNil(fixture.leaveResult, "The leave waits for its Save answer") }
        XCTAssertEqual(try fixture.read(), outside)
        XCTAssertEqual(fixture.library.drafts["test"]?.body, draft)
        if scenario != "no cycle" {
            XCTAssertNil(fixture.library.pendingUnsavedChanges, "Wait for the cycle's final text")
            fixture.watcher.emit("test") // The delayed watcher echo must not swallow the question.
            if scenario == "returns to baseline" { try fixture.write(source) }
            await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)
        }
        checkFinalQuestion(fixture, scenario: scenario, entry: entry, promptCount: promptCount)
        XCTAssertEqual(try fixture.read(), draft)
        XCTAssertFalse(fixture.library.hasUnsavedChanges)
        if entry == "leaving" { XCTAssertEqual(fixture.leaveResult, true) }
    }

    private func checkFinalQuestion(_ fixture: DocumentSaveFixture, scenario: String, entry: String, promptCount: Int) {
        if scenario == "returns to baseline" {
            XCTAssertNil(fixture.library.pendingUnsavedChanges)
            XCTAssertFalse(fixture.library.externallyModified.contains("test"))
        } else {
            XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, .externalChange, "\(scenario), \(entry)")
        }
        let questions = (entry == "leaving" ? 1 : 0) + (scenario == "returns to baseline" ? 0 : 1)
        XCTAssertEqual(fixture.presenter.prompts.count, promptCount + questions)
        fixture.library.resolveUnsavedChanges(.save)
    }

    private func checkQueuedSaves(source: String) async throws {
        for cycle in [false, true] {
            let fixture = try DocumentSaveFixture()
            defer { fixture.cleanup() }
            try fixture.write(source)
            _ = fixture.library.editorBody(for: fixture.skill)
            let draft = source + " draft"
            fixture.library.noteEditorChanged(fixture.skill, body: draft)
            let other = Skill(name: "Other", skillDescription: "Other", directoryName: "other")
            try fixture.files.writeFile(at: fixture.root + "/skills/other/SKILL.md", content: source)
            _ = fixture.library.editorBody(for: other)
            fixture.library.noteEditorChanged(other, body: source + " other draft")
            fixture.library.confirmLeaving(other) { _ in }
            if cycle { fixture.library.beginCoordinatorChanges() }
            try fixture.write(source.replacingOccurrences(of: "Before", with: "Outside"))
            let nudges = fixture.counter.value
            let sequence = fixture.library.coordinatorWatcherEventSequence
            XCTAssertFalse(fixture.library.saveDraft(fixture.skill))
            XCTAssertGreaterThan(fixture.library.coordinatorWatcherEventSequence, sequence)
            XCTAssertEqual(fixture.counter.value, nudges + (cycle ? 0 : 1))
            let accepted = fixture.library.acceptedChangeSequence
            XCTAssertFalse(fixture.library.saveDraft(fixture.skill))
            XCTAssertEqual(fixture.library.acceptedChangeSequence, accepted, "Repeated Save observes one change")
            fixture.watcher.emit("test")
            XCTAssertEqual(fixture.counter.value, nudges + (cycle ? 0 : 1), "An echo and repeated Save do not nudge sync again")
            if cycle { await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false) }
            XCTAssertEqual(fixture.library.pendingUnsavedChanges?.directoryName, "other")
            // The deferred question must use the latest text, not the text at the refused Save.
            let latest = source.replacingOccurrences(of: "Before", with: "Latest outside")
            try fixture.write(latest)
            fixture.library.resolveUnsavedChanges(.cancel)
            XCTAssertEqual(fixture.library.pendingUnsavedChanges?.directoryName, "test")
            XCTAssertEqual(fixture.presenter.prompts.count, 2)
            fixture.library.resolveUnsavedChanges(.cancel)
            XCTAssertTrue(fixture.library.saveDraft(fixture.skill), "Cancel acknowledged the text shown by the queued question")
            XCTAssertEqual(try fixture.read(), draft)
            fixture.library.noteEditorChanged(fixture.skill, body: draft + " again")
            try fixture.write(latest + " newer")
            XCTAssertFalse(fixture.library.saveDraft(fixture.skill), "A further change needs another answer")
            fixture.library.resolveUnsavedChanges(.save)
            XCTAssertEqual(try fixture.read(), draft + " again")
        }
    }

    private func checkQuestionSnapshot(source: String) throws {
        let fixture = try DocumentSaveFixture()
        defer { fixture.cleanup() }
        try fixture.write(source)
        _ = fixture.library.editorBody(for: fixture.skill)
        let draft = source + " draft"
        fixture.library.noteEditorChanged(fixture.skill, body: draft)
        fixture.library.confirmLeaving(fixture.skill) { fixture.leaveResult = $0 }
        try fixture.write(source + " outside")
        fixture.library.resolveUnsavedChanges(.save)
        XCTAssertNil(fixture.leaveResult)
        XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, .externalChange)
        let newer = source + " newer outside"
        try fixture.write(newer)
        fixture.library.resolveUnsavedChanges(.save)
        XCTAssertEqual(try fixture.read(), newer, "An answer cannot overwrite text that arrived after its question")
        XCTAssertNil(fixture.leaveResult)
        XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, .externalChange)
        XCTAssertEqual(fixture.presenter.prompts.count, 3)
        fixture.library.resolveUnsavedChanges(.save)
        XCTAssertEqual(try fixture.read(), draft)
        XCTAssertEqual(fixture.leaveResult, true)
    }

    private func attemptSave(_ fixture: DocumentSaveFixture, entry: String) -> Bool {
        switch entry {
        case "command": return fixture.library.saveUnsavedDrafts()
        case "leaving":
            fixture.library.confirmLeaving(fixture.skill) { fixture.leaveResult = $0 }
            fixture.library.resolveUnsavedChanges(.save)
            return fixture.leaveResult == true
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
    let counter = Counter()
    var leaveResult: Bool?

    init(registerSkill: Bool = true) throws {
        container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        if registerSkill { context.insert(skill); try context.save() }
        store = SkillStore(fileService: files, baseDir: root + "/skills", storeRoot: root)
        library = SkillLibraryViewModel(skillStore: store, fileService: files, fileWatchService: watcher,
                                       manifestRoot: root, notifier: counter.notify)
        library.onSkillDocumentObserved = { [weak library] directoryName, document in
            try library?.refreshSkillIdentity(directoryName: directoryName, document: document, context: context)
        }
        library.unsavedChangesPresenter = presenter.present
        library.startWatching()
        try files.createDirectory(at: root + "/skills/test")
    }

    func write(_ content: String) throws {
        try files.writeFile(at: root + "/skills/test/SKILL.md", content: content)
    }
    func read() throws -> String {
        try XCTUnwrap(String(validating: store.readData(directoryName: "test"), as: UTF8.self))
    }
    func cleanup() { try? files.deleteDirectory(at: root) }
}
