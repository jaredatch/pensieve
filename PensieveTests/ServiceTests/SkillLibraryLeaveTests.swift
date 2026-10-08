import XCTest
@testable import Pensieve

/// The gate every way out passes: `confirmLeaving` and the sheet's three answers, a refused save, a
/// second question while one is open, the default presenter, and a file that vanishes under a draft. The
/// draft rules themselves are `SkillLibrarySaveTests`, the loops over several drafts `SkillLibraryLeaveLoopTests`;
/// the doubles are shared from the first.
@MainActor
final class SkillLibraryLeaveTests: XCTestCase {
    private func makeSkill() -> Skill { Skill(name: "Test Skill", directoryName: "test-skill") }

    func testConfirmLeavingProceedsAtOnceWhenClean() {
        let library = SkillLibraryViewModel(
            skillStore: CountingSkillStore(body: "A"), fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestRoot: TestPaths.storeRoot
        )
        let presenter = RecordingPresenter()
        library.unsavedChangesPresenter = presenter.present
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        var answered: Bool?

        library.confirmLeaving(skill) { answered = $0 }

        XCTAssertEqual(answered, true)
        XCTAssertTrue(presenter.prompts.isEmpty)
    }

    func testConfirmLeavingSaveWritesThenProceeds() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        let presenter = RecordingPresenter()
        presenter.answer = .save
        library.unsavedChangesPresenter = presenter.present
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")
        var answered: Bool?

        library.confirmLeaving(skill) { answered = $0 }

        XCTAssertEqual(answered, true)
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertFalse(library.hasUnsavedChanges(for: skill))
        XCTAssertNil(library.pendingUnsavedChanges)
        XCTAssertEqual(presenter.prompts.count, 1)
        XCTAssertEqual(presenter.prompts.first?.reason, .leaving)
        XCTAssertEqual(presenter.prompts.first?.fileName, "test-skill/SKILL.md")
        XCTAssertEqual(presenter.prompts.first?.directoryName, "test-skill")
    }

    func testConfirmLeavingDontSaveDiscardsThenProceeds() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        let presenter = RecordingPresenter()
        presenter.answer = .discard
        library.unsavedChangesPresenter = presenter.present
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")
        var answered: Bool?

        library.confirmLeaving(skill) { answered = $0 }

        XCTAssertEqual(answered, true)
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertFalse(library.hasUnsavedChanges(for: skill))
        XCTAssertNil(library.pendingUnsavedChanges)
    }

    func testConfirmLeavingCancelKeepsTheDraftAndRefuses() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        let presenter = RecordingPresenter()
        presenter.answer = .cancel
        library.unsavedChangesPresenter = presenter.present
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")
        var answered: Bool?

        library.confirmLeaving(skill) { answered = $0 }

        XCTAssertEqual(answered, false)
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertTrue(library.hasUnsavedChanges(for: skill))
        XCTAssertNil(library.pendingUnsavedChanges)
    }

    func testConfirmLeavingSaveFailureRefuses() {
        let library = SkillLibraryViewModel(
            skillStore: ThrowingSkillStore(), fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestRoot: TestPaths.storeRoot
        )
        let presenter = RecordingPresenter()
        presenter.answer = .save
        library.unsavedChangesPresenter = presenter.present
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")
        var answered: Bool?

        library.confirmLeaving(skill) { answered = $0 }

        XCTAssertEqual(answered, false)
        XCTAssertTrue(library.hasUnsavedChanges(for: skill))
        XCTAssertNotNil(library.error)
    }

    func testASecondQuestionWhileOneIsOpenIsRefused() {
        let library = SkillLibraryViewModel(
            skillStore: CountingSkillStore(body: "A"), fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestRoot: TestPaths.storeRoot
        )
        let presenter = RecordingPresenter()   // answer nil: the first question stays open
        library.unsavedChangesPresenter = presenter.present
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")
        var first: Bool?
        var second: Bool?

        library.confirmLeaving(skill) { first = $0 }
        XCTAssertNil(first)
        XCTAssertNotNil(library.pendingUnsavedChanges)

        library.confirmLeaving(skill) { second = $0 }
        XCTAssertEqual(second, false)
        XCTAssertNil(first)

        presenter.pending?(.cancel)
        XCTAssertEqual(first, false)
        XCTAssertNil(library.pendingUnsavedChanges)
        XCTAssertTrue(library.hasUnsavedChanges(for: skill))
    }

    func testSaveRefusesWhenTheFileIsGoneAndKeepsTheDraft() {
        // A sync pull or a terminal removed the skill's files while it was being edited (Context, route 12): the
        // row goes with the next rebuild, but the draft is the user's — Save must not re-create the file.
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")
        store.filesGone = true

        XCTAssertFalse(library.saveDraft(skill))
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertTrue(library.hasUnsavedChanges(for: skill))
        XCTAssertNotNil(library.error)
    }

    func testAQuestionAnsweredSaveAfterTheFileVanishedRefusesAndKeepsTheDraft() {
        // The files vanish while the sheet is up: Save is refused (nothing re-created), the draft stays, and
        // the leaving continuation reads "did not proceed", as after any refused save.
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        let presenter = RecordingPresenter()   // holds the question open
        library.unsavedChangesPresenter = presenter.present
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")
        var proceeded: Bool?
        library.confirmLeaving(skill) { proceeded = $0 }
        store.filesGone = true

        presenter.pending?(.save)

        XCTAssertEqual(proceeded, false)
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertTrue(library.hasUnsavedChanges(for: skill))
        XCTAssertNil(library.pendingUnsavedChanges)
    }

    func testTheDefaultPresenterAnswersCancel() {
        let library = SkillLibraryViewModel(
            skillStore: CountingSkillStore(body: "A"), fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestRoot: TestPaths.storeRoot
        )
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")
        var answered: Bool?

        library.confirmLeaving(skill) { answered = $0 }

        XCTAssertEqual(answered, false)
        XCTAssertTrue(library.hasUnsavedChanges(for: skill))
    }
}
