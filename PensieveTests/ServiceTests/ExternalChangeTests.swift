import Observation
import SwiftData
import XCTest
@testable import Pensieve

final class ExternalChangeTests: XCTestCase {
    /// A stub watcher: records the registered handler and lets the test fire a synthetic change.
    private final class StubWatcher: FileWatchServiceProtocol {
        var onChange: (String) -> Void = { _ in }
        private(set) var startCount = 0
        func start() -> Bool {
            startCount += 1
            return true
        }
        func stop() {}
        func fire(_ directoryName: String) {
            onChange(directoryName)
        }
    }

    private var tempRoot: String!

    override func setUpWithError() throws {
        tempRoot = NSTemporaryDirectory() + "PensieveExternalChangeTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot) {
            try FileManager.default.removeItem(atPath: tempRoot)
        }
    }

    private func writeSkill(_ directoryName: String, body: String) throws {
        let dir = tempRoot + "/" + directoryName
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try body.write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
    }

    private func makeViewModel(watcher: StubWatcher) -> SkillLibraryViewModel {
        let store = SkillStore(fileService: FileService(), baseDir: tempRoot)
        return SkillLibraryViewModel(skillStore: store, fileWatchService: watcher)
    }

    /// A real external edit (on-disk body differs from the last app-written/loaded fingerprint)
    /// marks the skill externally-modified, bumps reloadToken, and the new body is readable.
    func testExternalEditMarksSkillModifiedAndReloadsBody() throws {
        let directoryName = "external-skill"
        try writeSkill(directoryName, body: "Original body")

        let watcher = StubWatcher()
        let viewModel = makeViewModel(watcher: watcher)
        let skill = Skill(name: "External Skill", directoryName: directoryName)
        viewModel.startWatching()

        // The app loaded "Original body" → fingerprint == "Original body".
        XCTAssertEqual(viewModel.editorBody(for: skill), "Original body")

        // Someone edits the file outside the app:
        try writeSkill(directoryName, body: "Edited outside the app")
        watcher.fire(directoryName)

        XCTAssertTrue(viewModel.externallyModified.contains(directoryName))
        XCTAssertEqual(viewModel.reloadToken, 1)
        XCTAssertEqual(viewModel.readBody(skill), "Edited outside the app")
    }

    func testAnExternalDeletionIsAnExternalChangeToAnEmptyBodyWhoseRepeatIsAnEcho() throws {
        let directoryName = "deleted-skill"
        try writeSkill(directoryName, body: "Original body")
        let watcher = StubWatcher()
        let store = SkillStore(fileService: FileService(), baseDir: tempRoot)
        var nudges = 0
        let viewModel = SkillLibraryViewModel(
            skillStore: store, fileWatchService: watcher, notifier: { nudges += 1 }
        )
        let skill = Skill(name: "Deleted Skill", directoryName: directoryName)
        XCTAssertEqual(viewModel.editorBody(for: skill), "Original body")
        viewModel.startWatching()

        try store.deleteSkill(directoryName: directoryName)
        watcher.fire(directoryName)

        XCTAssertEqual(viewModel.reloadToken, 1)
        XCTAssertEqual(nudges, 1)
        XCTAssertTrue(viewModel.externallyModified.contains(directoryName))
        XCTAssertTrue(viewModel.wasLastWrittenByApp(directoryName: directoryName, currentBody: ""))
        XCTAssertEqual(viewModel.readBody(skill), "")

        watcher.fire(directoryName)

        XCTAssertEqual(viewModel.reloadToken, 1)
        XCTAssertEqual(nudges, 1)
    }

    /// The app's OWN write (on-disk body equals the last-written fingerprint) is suppressed:
    /// no externallyModified entry, no reloadToken bump. THIS is the self-gating test —
    /// dropping the wasLastWrittenByApp suppression check makes this fail.
    func testAppOwnWriteIsSuppressedAndDoesNotMarkModified() throws {
        let directoryName = "self-write-skill"
        try writeSkill(directoryName, body: "App wrote this exact body")

        let watcher = StubWatcher()
        let viewModel = makeViewModel(watcher: watcher)
        let skill = Skill(name: "Self Write Skill", directoryName: directoryName)
        viewModel.startWatching()

        // The app itself last wrote exactly this body (fingerprint == on-disk content).
        XCTAssertEqual(viewModel.editorBody(for: skill), "App wrote this exact body")
        watcher.fire(directoryName)

        XCTAssertTrue(viewModel.externallyModified.isEmpty)
        XCTAssertEqual(viewModel.reloadToken, 0)
    }

    func testAFileRewrittenWithoutFrontmatterReadsCanonically() throws {
        // An admitted skill's file rewritten outside without its frontmatter (the rebuild rejects it on its next
        // pass; the row stands until then): the read is still the store's canonical form, so typing back to the
        // file's exact text is clean (batch Layer-2, round 4: the raw "A\n" fingerprint left a phantom draft).
        let directoryName = "bare-skill"
        try writeSkill(directoryName, body: "A")
        let store = SkillStore(fileService: FileService(), baseDir: tempRoot)
        let viewModel = SkillLibraryViewModel(skillStore: store, fileWatchService: StubWatcher())
        let skill = Skill(name: "Bare Skill", directoryName: directoryName)
        try store.writeBody(directoryName: directoryName, body: "A\n")

        XCTAssertEqual(viewModel.editorBody(for: skill), "A")
        viewModel.noteEditorChanged(skill, body: "A\n")
        XCTAssertFalse(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertTrue(viewModel.drafts.isEmpty)
        viewModel.noteEditorChanged(skill, body: "A\nB")
        XCTAssertTrue(viewModel.hasUnsavedChanges(for: skill))
    }

    func testABodyEndingInANewlineSavesCleanAndReadsBackAsTheAppsOwn() throws {
        let directoryName = "newline-skill"
        try writeSkill(directoryName, body: "A")
        let watcher = StubWatcher()
        let viewModel = makeViewModel(watcher: watcher)
        let skill = Skill(name: "Newline Skill", directoryName: directoryName)
        XCTAssertEqual(viewModel.editorBody(for: skill), "A")
        viewModel.noteEditorChanged(skill, body: "B\n")
        XCTAssertTrue(viewModel.hasUnsavedChanges(for: skill))

        XCTAssertTrue(viewModel.saveDraft(skill))

        XCTAssertFalse(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertEqual(viewModel.readBody(skill), "B")
        XCTAssertTrue(viewModel.wasLastWrittenByApp(directoryName: directoryName, currentBody: "B"))
        let reloadToken = viewModel.reloadToken
        XCTAssertEqual(viewModel.editorBody(for: skill), "B")
        XCTAssertTrue(viewModel.externallyModified.isEmpty)
        XCTAssertEqual(viewModel.reloadToken, reloadToken)
        viewModel.startWatching()
        watcher.fire(directoryName)
        XCTAssertTrue(viewModel.externallyModified.isEmpty)
    }

    /// An external edit landing on a DIRTY editor keeps the draft and asks — never reloads over the user's text.
    /// The question is the view model's: in the default Preview mode no editor is mounted (PLAN-02 / 02.3), and a
    /// sync pull reaches this path the same way a terminal edit does.
    func testExternalEditWhileDirtyKeepsTheDraftAndAsks() throws {
        let slug = "race-skill"
        let watcher = StubWatcher()
        let presenter = RecordingPresenter()   // holds the question open
        let (viewModel, skill) = try makeDirtyViewModel(slug: slug, watcher: watcher, presenter: presenter)

        try writeSkill(slug, body: "C")
        watcher.fire(slug)

        XCTAssertEqual(viewModel.readBody(skill), "C")
        XCTAssertTrue(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertEqual(viewModel.drafts[slug]?.body, "B")
        XCTAssertTrue(viewModel.externallyModified.contains(slug))
        XCTAssertEqual(presenter.prompts.map(\.reason), [.externalChange])
        XCTAssertEqual(presenter.prompts.first?.fileName, "race-skill/SKILL.md")

        presenter.pending?(.save)                          // Save overwrites the external version with the draft
        XCTAssertEqual(viewModel.readBody(skill), "B")
        XCTAssertFalse(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertFalse(viewModel.externallyModified.contains(slug))
    }

    func testExternalEditWhileDirtyDontSaveReloadsTheFile() throws {
        let slug = "race-skill"
        let watcher = StubWatcher()
        let presenter = RecordingPresenter()
        let (viewModel, skill) = try makeDirtyViewModel(slug: slug, watcher: watcher, presenter: presenter)

        try writeSkill(slug, body: "C")
        watcher.fire(slug)
        presenter.pending?(.discard)

        XCTAssertFalse(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertEqual(viewModel.readBody(skill), "C")
        XCTAssertEqual(viewModel.reloadToken, 2)           // the change, then the discard: a clean editor reloads
    }

    func testExternalEditWhileDirtyCancelKeepsEditing() throws {
        let slug = "race-skill"
        let watcher = StubWatcher()
        let presenter = RecordingPresenter()
        let (viewModel, skill) = try makeDirtyViewModel(slug: slug, watcher: watcher, presenter: presenter)

        try writeSkill(slug, body: "C")
        watcher.fire(slug)
        presenter.pending?(.cancel)

        XCTAssertTrue(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertEqual(viewModel.drafts[slug]?.body, "B")
        XCTAssertTrue(viewModel.externallyModified.contains(slug))
        XCTAssertEqual(viewModel.readBody(skill), "C")
    }

    func testExternalEditMatchingTheDraftReadsCleanKeepsTheEntryAndReadsDirtyWhenTheFileMovesOn() throws {
        let slug = "race-skill"
        let watcher = StubWatcher()
        let presenter = RecordingPresenter()
        let (viewModel, skill) = try makeDirtyViewModel(slug: slug, watcher: watcher, presenter: presenter)
        viewModel.noteEditorChanged(skill, body: "C")

        try writeSkill(slug, body: "C")                    // the same text arrived from outside
        watcher.fire(slug)

        XCTAssertFalse(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertTrue(presenter.prompts.isEmpty)
        XCTAssertTrue(viewModel.externallyModified.contains(slug))
        XCTAssertEqual(viewModel.drafts[slug]?.body, "C")   // clean, not gone

        try writeSkill(slug, body: "D")                    // the file moves on: the same entry is dirty again
        watcher.fire(slug)

        XCTAssertTrue(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertEqual(viewModel.drafts[slug]?.body, "C")
        XCTAssertEqual(presenter.prompts.map(\.reason), [.externalChange])
    }

    func testARemountAfterTheFileCaughtUpReadsCleanAndAsksNothing() throws {
        // The same text arrives from outside and the editor remounts (a selection change and back) before the
        // watcher delivers: the remount re-seeds the fingerprint to "B", so the draft reads clean at once, and
        // the later event is the echo of a body the fingerprint already holds.
        let slug = "remount-skill"
        let watcher = StubWatcher()
        let presenter = RecordingPresenter()
        let (viewModel, skill) = try makeDirtyViewModel(slug: slug, watcher: watcher, presenter: presenter)

        try writeSkill(slug, body: "B")
        XCTAssertEqual(viewModel.editorBody(for: skill), "B")
        XCTAssertFalse(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertFalse(viewModel.hasUnsavedChanges)

        watcher.fire(slug)

        XCTAssertFalse(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertTrue(presenter.prompts.isEmpty)
        XCTAssertEqual(viewModel.drafts[slug]?.body, "B")   // clean, not gone

        try writeSkill(slug, body: "D")                    // the file moves on: the same entry is dirty again
        watcher.fire(slug)

        XCTAssertTrue(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertEqual(viewModel.drafts[slug]?.body, "B")
        XCTAssertEqual(presenter.prompts.map(\.reason), [.externalChange])
    }

    func testARemountOverADivergentExternalChangeAsks() throws {
        // A different body arrives from outside while no editor is mounted (the bulk placeholder, another
        // section), and the skill is selected again before the watcher delivers: the remount must classify the
        // body as an external change — the mark, the question — not adopt it as the fingerprint and let the
        // later event pass as an echo (round 2).
        let slug = "divergent-remount"
        let watcher = StubWatcher()
        let presenter = RecordingPresenter()   // holds the question open
        let (viewModel, skill) = try makeDirtyViewModel(slug: slug, watcher: watcher, presenter: presenter)

        try writeSkill(slug, body: "C")
        XCTAssertEqual(viewModel.editorBody(for: skill), "B")     // the draft, over the changed file

        XCTAssertTrue(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertTrue(viewModel.externallyModified.contains(slug))
        XCTAssertEqual(presenter.prompts.map(\.reason), [.externalChange])
        watcher.fire(slug)                                          // the echo of a body already known
        XCTAssertEqual(presenter.prompts.count, 1)
        XCTAssertTrue(viewModel.hasUnsavedChanges(for: skill))
    }

    /// A skill loaded as "A" and edited to "B", with the recorder as the sheet.
    private func makeDirtyViewModel(slug: String, watcher: StubWatcher,
                                    presenter: RecordingPresenter) throws -> (SkillLibraryViewModel, Skill) {
        try writeSkill(slug, body: "A")
        let viewModel = makeViewModel(watcher: watcher)
        viewModel.unsavedChangesPresenter = presenter.present
        let skill = Skill(name: "Race Skill", directoryName: slug)
        viewModel.startWatching()
        XCTAssertEqual(viewModel.editorBody(for: skill), "A")
        viewModel.noteEditorChanged(skill, body: "B")
        XCTAssertTrue(viewModel.hasUnsavedChanges(for: skill))
        return (viewModel, skill)
    }

    /// The sheet as a recorder: `answer` nil holds the question open for the test to resolve.
    private final class RecordingPresenter {
        var prompts: [UnsavedChangesPrompt] = []
        var answer: UnsavedChangesChoice?
        var pending: ((UnsavedChangesChoice) -> Void)?

        func present(_ prompt: UnsavedChangesPrompt, resolve: @escaping (UnsavedChangesChoice) -> Void) {
            prompts.append(prompt)
            if let answer { resolve(answer) } else { pending = resolve }
        }
    }
}

// MARK: - A bundle file's change (PLAN-34 / 34.2)

extension ExternalChangeTests {
    /// A change to a bundle file other than SKILL.md reaches the app only as a watcher event whose body check
    /// reads an echo: nothing is accepted — no mark, no token, no nudge — but the event advances the observed
    /// `watcherEventSequence`, which the detail's snapshot and the Content tab re-read the bundle on (PLAN-34 / 34.2).
    func testABundleFileChangeIsAnObservedEventThatAcceptsNothing() throws {
        let directoryName = "bundle-skill"
        try writeSkill(directoryName, body: "Original body")
        let watcher = StubWatcher()
        let store = SkillStore(fileService: FileService(), baseDir: tempRoot)
        var nudges = 0
        let viewModel = SkillLibraryViewModel(skillStore: store, fileWatchService: watcher, notifier: { nudges += 1 })
        let skill = Skill(name: "Bundle Skill", directoryName: directoryName)
        XCTAssertEqual(viewModel.editorBody(for: skill), "Original body")
        viewModel.startWatching()
        let sequence = viewModel.watcherEventSequence
        var observed = false
        withObservationTracking { _ = viewModel.watcherEventSequence } onChange: { observed = true }

        let references = tempRoot + "/" + directoryName + "/references"
        try FileManager.default.createDirectory(atPath: references, withIntermediateDirectories: true)
        try "A new reference".write(toFile: references + "/a.md", atomically: true, encoding: .utf8)
        watcher.fire(directoryName)

        XCTAssertTrue(observed, "the detail observes the watcher's event sequence")
        XCTAssertEqual(viewModel.watcherEventSequence, sequence &+ 1)
        XCTAssertEqual(viewModel.reloadToken, 0)
        XCTAssertFalse(viewModel.externallyModified.contains(directoryName))
        XCTAssertEqual(nudges, 0)
    }
}
