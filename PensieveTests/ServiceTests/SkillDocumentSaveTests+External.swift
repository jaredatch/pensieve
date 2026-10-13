import SwiftData
import XCTest
@testable import Pensieve

extension SkillDocumentSaveTests {
    func testFrontmatterOnlyWatcherChangesRefreshIdentityAndPreserveDirtyDraft() throws {
        let fixture = try DocumentSaveFixture(registerSkill: false)
        defer { fixture.cleanup() }
        let source = "---\nname: Test\ndescription: Before\n---\nBody"
        try fixture.write(source)
        let container = fixture.container
        let context = container.mainContext
        let live = try checkUnopenedAndReplacementRows(fixture, source: source, context: context)
        _ = fixture.library.editorBody(for: live)
        let outside = source.replacingOccurrences(of: "Before", with: "Outside")
        try fixture.write(outside)
        let token = fixture.library.reloadToken
        fixture.watcher.emit("test")
        XCTAssertEqual(fixture.library.reloadToken, token + 1)
        XCTAssertEqual(fixture.library.editorBody(for: live), outside)
        XCTAssertEqual(live.skillDescription, "Outside")
        XCTAssertTrue(fixture.presenter.prompts.isEmpty)
        let draft = outside + " draft"
        fixture.library.noteEditorChanged(live, body: draft)
        let second = outside.replacingOccurrences(of: "Outside", with: "Second outside")
        try fixture.write(second)
        fixture.watcher.emit("test")
        XCTAssertEqual(fixture.library.drafts["test"]?.body, draft)
        XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, .externalChange)
        XCTAssertEqual(live.skillDescription, "Second outside")
        fixture.library.resolveUnsavedChanges(.cancel)
        XCTAssertEqual(try fixture.read(), second)
        XCTAssertEqual(fixture.library.drafts["test"]?.body, draft)
        try fixture.write(second + " further")
        XCTAssertFalse(fixture.library.saveDraft(live))
        fixture.library.resolveUnsavedChanges(.discard)
        XCTAssertEqual(fixture.library.editorBody(for: live), second + " further")
        XCTAssertFalse(fixture.library.hasUnsavedChanges)
        try checkDiskCatchingDraft(fixture)
    }

    private func checkDiskCatchingDraft(_ fixture: DocumentSaveFixture) throws {
        let source = try fixture.read()
        let caughtUp = source + " caught up"
        fixture.library.noteEditorChanged(fixture.skill, body: caughtUp)
        try fixture.write(caughtUp)
        fixture.watcher.emit("test")
        XCTAssertNil(fixture.library.pendingUnsavedChanges)
        XCTAssertEqual(fixture.library.drafts["test"]?.body, caughtUp, "Keep the retained draft")
        XCTAssertEqual(fixture.library.drafts["test"]?.baseline, caughtUp)
        fixture.library.noteEditorChanged(fixture.skill, body: caughtUp + " next edit")
        XCTAssertTrue(fixture.library.saveDraft(fixture.skill), "Unchanged caught-up disk needs no new question")
        XCTAssertEqual(try fixture.read(), caughtUp + " next edit")
        fixture.library.noteEditorChanged(fixture.skill, body: caughtUp + " another edit")
        try fixture.write(caughtUp + " real outside change")
        XCTAssertFalse(fixture.library.saveDraft(fixture.skill), "A real outside change still asks")
        XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, .externalChange)
        fixture.library.resolveUnsavedChanges(.cancel)
    }

    private func checkUnopenedAndReplacementRows(_ fixture: DocumentSaveFixture, source: String,
                                                 context: ModelContext) throws -> Skill {
        fixture.library.refreshQuarantine(context: context) // Launch snapshot predates the added row.
        context.insert(fixture.skill)
        try context.save()
        let unopenedOutside = source.replacingOccurrences(of: "Before", with: "Added after launch")
        try fixture.write(unopenedOutside)
        fixture.watcher.emit("test")
        XCTAssertEqual(fixture.skill.skillDescription, "Added after launch", "An unopened new row follows the watcher")
        _ = fixture.library.editorBody(for: fixture.skill)
        try fixture.write(source)
        let live = Skill(name: "Test", skillDescription: "Before", directoryName: "test")
        context.insert(live)
        try context.save()
        context.delete(fixture.skill) // Both rows were persisted before the old row became a pending deletion.
        let replacementOutside = source.replacingOccurrences(of: "Before", with: "Replacement outside")
        try fixture.write(replacementOutside)
        fixture.watcher.emit("test")
        XCTAssertEqual(live.skillDescription, "Replacement outside", "Refresh the replacement that the window displays")
        XCTAssertEqual(fixture.skill.skillDescription, "Added after launch", "The held deleted row is retired")
        try context.save()
        fixture.library.error = "An earlier refused Save"
        fixture.library.onSkillDocumentObserved = { _, _ in throw CocoaError(.fileReadUnknown) }
        try fixture.write(source)
        fixture.watcher.emit("test")
        XCTAssertEqual(fixture.library.error, "An earlier refused Save",
                       "Passive refresh failures do not replace actionable errors")
        fixture.library.onSkillDocumentObserved = { [weak library = fixture.library] slug, document in
            try library?.refreshSkillIdentity(directoryName: slug, document: document, context: context)
        }
        return live
    }

    func testFrontmatterOnlySyncPullAsksAgainstFinalWholeFile() async throws {
        for saveBeforeWatcher in [false, true] {
            let fixture = try DocumentSaveFixture()
            defer { fixture.cleanup() }
            let source = "---\nname: Test\ndescription: Before\n---\nBody"
            try fixture.write(source)
            _ = fixture.library.editorBody(for: fixture.skill)
            fixture.library.noteEditorChanged(fixture.skill, body: source + " draft")
            fixture.library.beginCoordinatorChanges()
            let pulled = source.replacingOccurrences(of: "Before", with: "Pulled")
            try fixture.write(pulled)
            if saveBeforeWatcher { XCTAssertFalse(fixture.library.saveDraft(fixture.skill)) }
            fixture.watcher.emit("test")
            XCTAssertTrue(fixture.presenter.prompts.isEmpty, "Intermediate sync events do not ask")
            await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)
            XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, .externalChange)
            XCTAssertEqual(fixture.library.drafts["test"]?.body, source + " draft")
            XCTAssertEqual(try fixture.read(), pulled)
            XCTAssertEqual(fixture.skill.skillDescription, "Pulled")
        }
        try await checkFinalDiskCatchingDraft()
    }

    private func checkFinalDiskCatchingDraft() async throws {
        let fixture = try DocumentSaveFixture()
        defer { fixture.cleanup() }
        let source = "---\nname: Test\ndescription: Before\n---\nBody"
        let draft = source + " caught up"
        try fixture.write(source)
        _ = fixture.library.editorBody(for: fixture.skill)
        fixture.library.noteEditorChanged(fixture.skill, body: draft)
        fixture.library.beginCoordinatorChanges()
        try fixture.write(source + " intermediate")
        fixture.watcher.emit("test")
        try fixture.write(draft)
        await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)
        XCTAssertNil(fixture.library.pendingUnsavedChanges)
        XCTAssertEqual(fixture.library.drafts["test"]?.body, draft)
        XCTAssertEqual(fixture.library.drafts["test"]?.baseline, draft)
        fixture.library.noteEditorChanged(fixture.skill, body: draft + " next edit")
        XCTAssertTrue(fixture.library.saveDraft(fixture.skill))
        XCTAssertEqual(try fixture.read(), draft + " next edit")
        fixture.library.noteEditorChanged(fixture.skill, body: draft + " more")
        try fixture.write(draft + " real outside change")
        XCTAssertFalse(fixture.library.saveDraft(fixture.skill))
        XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, .externalChange)
        fixture.library.resolveUnsavedChanges(.cancel)
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
            if restore {
                XCTAssertEqual(library.error, "Couldn't restore this version: \(DeletionTestError().localizedDescription)")
            }
            files.failingWrites.remove(path)
            if restore {
                try restoreSkillHistoryVersion(skill: skill, body: draft, store: store, library: library, notifier: {})
            } else { XCTAssertTrue(library.saveDraft(skill)) }
            XCTAssertNil(library.error, "A successful retry clears its own failure")
            if restore {
                library.error = "Another skill's refused Save"
                try restoreSkillHistoryVersion(skill: skill, body: draft, store: store, library: library, notifier: {})
                XCTAssertEqual(library.error, "Another skill's refused Save")
            }
            XCTAssertEqual(files.files[path], draft)
            XCTAssertEqual(skill.skillDescription, "After")
            XCTAssertFalse(library.hasUnsavedChanges)
            XCTAssertTrue(library.wasLastWrittenByApp(directoryName: "test", currentBody: draft))
        }
    }
}
