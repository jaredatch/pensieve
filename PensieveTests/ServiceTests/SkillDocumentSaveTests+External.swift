import SwiftData
import XCTest
@testable import Pensieve

extension SkillDocumentSaveTests {
    func testFrontmatterOnlyWatcherChangesRefreshIdentityAndPreserveDirtyDraft() throws {
        let fixture = try DocumentSaveFixture()
        defer { fixture.cleanup() }
        let source = "---\nname: Test\ndescription: Before\n---\nBody"
        try fixture.write(source)
        _ = fixture.library.editorBody(for: fixture.skill)
        let outside = source.replacingOccurrences(of: "Before", with: "Outside")
        try fixture.write(outside)
        let token = fixture.library.reloadToken
        fixture.watcher.emit("test")
        XCTAssertEqual(fixture.library.reloadToken, token + 1)
        XCTAssertEqual(fixture.library.editorBody(for: fixture.skill), outside)
        XCTAssertEqual(fixture.skill.skillDescription, "Outside")
        XCTAssertTrue(fixture.presenter.prompts.isEmpty)
        let draft = outside + " draft"
        fixture.library.noteEditorChanged(fixture.skill, body: draft)
        let second = outside.replacingOccurrences(of: "Outside", with: "Second outside")
        try fixture.write(second)
        fixture.watcher.emit("test")
        XCTAssertEqual(fixture.library.drafts["test"]?.body, draft)
        XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, .externalChange)
        XCTAssertEqual(fixture.skill.skillDescription, "Second outside")
        fixture.library.resolveUnsavedChanges(.cancel)
        XCTAssertEqual(try fixture.read(), second)
        XCTAssertEqual(fixture.library.drafts["test"]?.body, draft)
        XCTAssertFalse(fixture.library.saveDraft(fixture.skill))
        fixture.library.resolveUnsavedChanges(.discard)
        XCTAssertEqual(fixture.library.editorBody(for: fixture.skill), second)
        XCTAssertFalse(fixture.library.hasUnsavedChanges)
    }

    func testFrontmatterOnlySyncPullAsksAgainstFinalWholeFile() async throws {
        let fixture = try DocumentSaveFixture()
        defer { fixture.cleanup() }
        let source = "---\nname: Test\ndescription: Before\n---\nBody"
        try fixture.write(source)
        _ = fixture.library.editorBody(for: fixture.skill)
        fixture.library.noteEditorChanged(fixture.skill, body: source + " draft")
        fixture.library.beginCoordinatorChanges()
        let pulled = source.replacingOccurrences(of: "Before", with: "Pulled")
        try fixture.write(pulled)
        fixture.watcher.emit("test")
        XCTAssertTrue(fixture.presenter.prompts.isEmpty, "Intermediate sync events do not ask")
        await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)
        XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, .externalChange)
        XCTAssertEqual(fixture.library.drafts["test"]?.body, source + " draft")
        XCTAssertEqual(try fixture.read(), pulled)
        XCTAssertEqual(fixture.skill.skillDescription, "Pulled")
    }

    func testWriteBracketsKeepFailedAndRacingFrontmatterChangesOutside() throws {
        let fixture = try DocumentSaveFixture()
        defer { fixture.cleanup() }
        let source = "---\nname: Test\ndescription: Before\n---\nBody"
        let app = source.replacingOccurrences(of: "Before", with: "App")
        let outside = source.replacingOccurrences(of: "Before", with: "Outside")
        for success in [false, true] {
            try fixture.write(source)
            _ = fixture.library.editorBody(for: fixture.skill)
            fixture.library.beginAppAuthoredBodyWrite(directoryName: "test", expectedBody: app)
            _ = fixture.library.editorBody(for: fixture.skill)
            if success { try fixture.write(app) }
            try fixture.write(outside)
            fixture.library.finishAppAuthoredBodyWrite(directoryName: "test", succeeded: success)
            XCTAssertFalse(fixture.library.wasLastWrittenByApp(directoryName: "test", currentBody: outside))
            XCTAssertTrue(fixture.library.wasLastWrittenByApp(directoryName: "test", currentBody: success ? app : source))
            let token = fixture.library.reloadToken
            fixture.watcher.emit("test")
            XCTAssertEqual(fixture.library.reloadToken, token + 1)
            XCTAssertEqual(fixture.skill.skillDescription, "Outside")
        }
    }

    func testSaveAndHistoryWriteFailuresLeaveStateAndCanRetry() throws {
        let files = MemoryDeployFileService()
        let root = TestTemporaryDirectory.path + "RefusedDocument-" + UUID().uuidString
        let store = SkillStore(fileService: files, baseDir: root, storeRoot: root)
        let skill = Skill(name: "Test", skillDescription: "Before", directoryName: "test")
        let path = skill.canonicalPath(skillsDirectory: root)
        let source = "---\nname: Test\ndescription: Before\n---\nBody"
        let draft = source.replacingOccurrences(of: "Before", with: "After")
        let library = SkillLibraryViewModel(skillStore: store, fileService: files,
            fileWatchService: RecordingWatcher(), manifestRoot: root)
        for restore in [false, true] {
            files.files[path] = source
            _ = library.editorBody(for: skill)
            library.noteEditorChanged(skill, body: draft)
            let timestamp = skill.updatedAt
            files.failingWrites.insert(path)
            if restore {
                XCTAssertThrowsError(try restoreSkillHistoryVersion(skill: skill, body: draft, store: store,
                    library: library, notifier: {}))
            } else { XCTAssertFalse(library.saveDraft(skill)) }
            XCTAssertEqual(files.files[path], source)
            XCTAssertEqual(library.drafts["test"]?.body, draft)
            XCTAssertEqual(skill.name, "Test")
            XCTAssertEqual(skill.skillDescription, "Before")
            XCTAssertEqual(skill.updatedAt, timestamp)
            XCTAssertTrue(library.wasLastWrittenByApp(directoryName: "test", currentBody: source))
            XCTAssertNotNil(library.error)
            files.failingWrites.remove(path)
            if restore {
                try restoreSkillHistoryVersion(skill: skill, body: draft, store: store, library: library, notifier: {})
            } else { XCTAssertTrue(library.saveDraft(skill)) }
            XCTAssertEqual(files.files[path], draft)
            XCTAssertEqual(skill.skillDescription, "After")
            XCTAssertFalse(library.hasUnsavedChanges)
            XCTAssertTrue(library.wasLastWrittenByApp(directoryName: "test", currentBody: draft))
        }
    }
}
