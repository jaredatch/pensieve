import XCTest
@testable import Pensieve

/// The gate over several drafts at once: a global way out (quit, the window's close, the Updates
/// sheet) asking about every dirty draft in turn, and leaving several skills together — each loop re-reading
/// what is dirty after every answer, so a draft that turned dirty during another's question is reached. The
/// single-skill gate is `SkillLibraryLeaveTests`; the doubles are shared from `SkillLibrarySaveTests`.
@MainActor
final class SkillLibraryLeaveLoopTests: XCTestCase {

    func testAGlobalWayOutSettlesAnEntryTheFileCaughtUpWith() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let skill = Skill(name: "Skill", directoryName: "skill")
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")
        library.acceptExternalChange(directoryName: skill.directoryName, currentBody: "B", shouldNotify: false)
        XCTAssertFalse(library.hasUnsavedChanges(for: skill))
        XCTAssertNotNil(library.drafts[skill.directoryName])
        var proceeded: Bool?

        library.confirmLeavingAnyDraft { proceeded = $0 }

        XCTAssertEqual(proceeded, true)
        XCTAssertNil(library.pendingUnsavedChanges)
        XCTAssertTrue(library.drafts.isEmpty)

        let cycleLibrary = SkillLibraryViewModel(skillStore: CountingSkillStore(body: "A"))
        let cycleSkill = Skill(name: "Cycle Skill", directoryName: "cycle-skill")
        _ = cycleLibrary.editorBody(for: cycleSkill)
        cycleLibrary.noteEditorChanged(cycleSkill, body: "B")
        cycleLibrary.acceptExternalChange(
            directoryName: cycleSkill.directoryName, currentBody: "B", shouldNotify: false
        )
        cycleLibrary.beginCoordinatorChanges()
        cycleLibrary.confirmLeavingAnyDraft { proceeded = $0 }
        XCTAssertNotNil(cycleLibrary.drafts[cycleSkill.directoryName])
    }

    func testAGlobalLeaveAsksAboutEveryDirtyDraft() {
        // Two dirty drafts at once (an entry kept clean by a file that caught up, made dirty again by an external
        // change while another skill was edited): quit, the window's close, and the Updates sheet ask about each
        // in turn and proceed only once both were answered — round 2 found the quit asking about one.
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let presenter = RecordingPresenter()
        presenter.answer = .save
        library.unsavedChangesPresenter = presenter.present
        let alpha = Skill(name: "Alpha", directoryName: "alpha")
        let beta = Skill(name: "Beta", directoryName: "beta")
        _ = library.editorBody(for: alpha)
        _ = library.editorBody(for: beta)
        library.noteEditorChanged(alpha, body: "B")
        library.noteEditorChanged(beta, body: "C")
        var proceeded: Bool?

        library.confirmLeavingAnyDraft { proceeded = $0 }

        XCTAssertEqual(presenter.prompts.map(\.directoryName), ["alpha", "beta"])
        XCTAssertEqual(store.writeCount, 2)
        XCTAssertEqual(proceeded, true)
        XCTAssertFalse(library.hasUnsavedChanges)
    }

    func testAGlobalLeaveStopsAtTheFirstCancel() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let presenter = RecordingPresenter()   // holds each question open
        library.unsavedChangesPresenter = presenter.present
        let alpha = Skill(name: "Alpha", directoryName: "alpha")
        let beta = Skill(name: "Beta", directoryName: "beta")
        _ = library.editorBody(for: alpha)
        _ = library.editorBody(for: beta)
        library.noteEditorChanged(alpha, body: "B")
        library.noteEditorChanged(beta, body: "C")
        var proceeded: Bool?

        library.confirmLeavingAnyDraft { proceeded = $0 }
        XCTAssertEqual(presenter.prompts.map(\.directoryName), ["alpha"])
        XCTAssertNil(proceeded)                                     // the first question is open
        presenter.pending?(.save)
        XCTAssertEqual(presenter.prompts.map(\.directoryName), ["alpha", "beta"])
        XCTAssertNil(proceeded)                                     // now the second
        presenter.pending?(.cancel)

        XCTAssertEqual(proceeded, false)
        XCTAssertEqual(store.writeCount, 1)                         // alpha written, beta kept
        XCTAssertFalse(library.hasUnsavedChanges(for: alpha))
        XCTAssertTrue(library.hasUnsavedChanges(for: beta))
        XCTAssertNil(library.pendingUnsavedChanges)
    }

    func testAnExternalChangeWhileAQuestionIsOpenIsAskedAtTheNextTurnOfTheLoop() {
        // Beta's entry reads clean (the file caught up with it) when alpha's question opens; beta's file then
        // moves on under it — a second question is refused, beta is dirty now, and the global loop must reach
        // it once alpha is answered: a loop over the drafts dirty at the start would not (round 3).
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let presenter = RecordingPresenter()
        library.unsavedChangesPresenter = presenter.present
        let alpha = Skill(name: "Alpha", directoryName: "alpha")
        let beta = Skill(name: "Beta", directoryName: "beta")
        _ = library.editorBody(for: alpha)
        _ = library.editorBody(for: beta)
        library.noteEditorChanged(beta, body: "C")
        library.acceptExternalChange(directoryName: "beta", currentBody: "C", shouldNotify: false)
        XCTAssertFalse(library.hasUnsavedChanges(for: beta))       // clean, the entry retained
        XCTAssertEqual(library.drafts["beta"]?.body, "C")
        library.noteEditorChanged(alpha, body: "B")
        var proceeded: Bool?
        library.confirmLeavingAnyDraft { proceeded = $0 }
        XCTAssertEqual(presenter.prompts.map(\.directoryName), ["alpha"])

        library.acceptExternalChange(directoryName: "beta", currentBody: "X", shouldNotify: false)

        XCTAssertEqual(presenter.prompts.count, 1)                 // refused while alpha's is open
        XCTAssertTrue(library.hasUnsavedChanges(for: beta))        // dirty now
        presenter.pending?(.save)                                   // alpha
        XCTAssertEqual(presenter.prompts.map(\.directoryName), ["alpha", "beta"])
        presenter.pending?(.discard)                                // beta
        XCTAssertEqual(proceeded, true)
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertFalse(library.hasUnsavedChanges)
    }

    func testLeavingSeveralSkillsAsksAboutEachDirtyOneInTurn() {
        // A multi-selection moving on: the dirty ones are asked about in turn, the clean one is not.
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let presenter = RecordingPresenter()
        presenter.answer = .discard
        library.unsavedChangesPresenter = presenter.present
        let alpha = Skill(name: "Alpha", directoryName: "alpha")
        let beta = Skill(name: "Beta", directoryName: "beta")
        let gamma = Skill(name: "Gamma", directoryName: "gamma")
        for skill in [alpha, beta, gamma] { _ = library.editorBody(for: skill) }
        library.noteEditorChanged(alpha, body: "B")
        library.noteEditorChanged(gamma, body: "D")
        var proceeded: Bool?

        library.confirmLeaving([alpha, beta, gamma]) { proceeded = $0 }

        XCTAssertEqual(presenter.prompts.map(\.directoryName), ["alpha", "gamma"])
        XCTAssertEqual(proceeded, true)
        XCTAssertFalse(library.hasUnsavedChanges)
        XCTAssertEqual(store.writeCount, 0)
    }

    func testLeavingSeveralSkillsStopsAtTheFirstCancel() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let presenter = RecordingPresenter()   // holds each question open
        library.unsavedChangesPresenter = presenter.present
        let alpha = Skill(name: "Alpha", directoryName: "alpha")
        let gamma = Skill(name: "Gamma", directoryName: "gamma")
        _ = library.editorBody(for: alpha)
        _ = library.editorBody(for: gamma)
        library.noteEditorChanged(alpha, body: "B")
        library.noteEditorChanged(gamma, body: "D")
        var proceeded: Bool?

        library.confirmLeaving([alpha, gamma]) { proceeded = $0 }
        presenter.pending?(.save)                                   // alpha
        XCTAssertNil(proceeded)
        presenter.pending?(.cancel)                                 // gamma

        XCTAssertEqual(proceeded, false)
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertFalse(library.hasUnsavedChanges(for: alpha))
        XCTAssertTrue(library.hasUnsavedChanges(for: gamma))
    }

    func testLeavingSeveralSkillsRevisitsOneAnsweredSaveWhoseFileMovedOnAgain() {
        // Alpha's file catches up while alpha's question is open, so Save writes nothing and keeps the entry;
        // during gamma's question alpha's file moves on again — alpha is dirty once more, its own question
        // refused, and the gate must ask about alpha again before proceeding: a loop that drops answered
        // skills would not (round 5).
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let presenter = RecordingPresenter()   // holds each question open
        library.unsavedChangesPresenter = presenter.present
        let alpha = Skill(name: "Alpha", directoryName: "alpha")
        let gamma = Skill(name: "Gamma", directoryName: "gamma")
        _ = library.editorBody(for: alpha)
        _ = library.editorBody(for: gamma)
        library.noteEditorChanged(alpha, body: "B")
        library.noteEditorChanged(gamma, body: "D")
        var proceeded: Bool?

        library.confirmLeaving([alpha, gamma]) { proceeded = $0 }
        XCTAssertEqual(presenter.prompts.map(\.directoryName), ["alpha"])
        library.acceptExternalChange(directoryName: "alpha", currentBody: "B", shouldNotify: false)
        presenter.pending?(.save)                                   // nothing to write: alpha reads clean
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(presenter.prompts.map(\.directoryName), ["alpha", "gamma"])
        library.acceptExternalChange(directoryName: "alpha", currentBody: "X", shouldNotify: false)
        XCTAssertTrue(library.hasUnsavedChanges(for: alpha))       // dirty again, its question refused
        XCTAssertEqual(presenter.prompts.count, 2)
        presenter.pending?(.discard)                                // gamma
        XCTAssertNil(proceeded)                                     // alpha is asked again first
        XCTAssertEqual(presenter.prompts.map(\.directoryName), ["alpha", "gamma", "alpha"])
        presenter.pending?(.discard)                                // alpha

        XCTAssertEqual(proceeded, true)
        XCTAssertFalse(library.hasUnsavedChanges)
    }

    func testLeavingSeveralSkillsRevisitsOneThatTurnedDirtyDuringAnotherQuestion() {
        // Alpha's entry reads clean when the departing set is asked about (gamma first, alpha skipped); alpha's
        // file moves on while gamma's question is open — its own question refused — and the gate must reach
        // alpha after gamma is answered: a snapshot of the dirty departures would not (round 4).
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let presenter = RecordingPresenter()   // holds each question open
        library.unsavedChangesPresenter = presenter.present
        let alpha = Skill(name: "Alpha", directoryName: "alpha")
        let gamma = Skill(name: "Gamma", directoryName: "gamma")
        _ = library.editorBody(for: alpha)
        _ = library.editorBody(for: gamma)
        library.noteEditorChanged(alpha, body: "B")
        library.acceptExternalChange(directoryName: "alpha", currentBody: "B", shouldNotify: false)
        XCTAssertFalse(library.hasUnsavedChanges(for: alpha))      // clean, the entry retained
        library.noteEditorChanged(gamma, body: "D")
        var proceeded: Bool?

        library.confirmLeaving([alpha, gamma]) { proceeded = $0 }
        XCTAssertEqual(presenter.prompts.map(\.directoryName), ["gamma"])
        library.acceptExternalChange(directoryName: "alpha", currentBody: "X", shouldNotify: false)
        XCTAssertEqual(presenter.prompts.count, 1)                 // refused while gamma's is open
        XCTAssertTrue(library.hasUnsavedChanges(for: alpha))
        presenter.pending?(.save)                                   // gamma
        XCTAssertEqual(presenter.prompts.map(\.directoryName), ["gamma", "alpha"])
        presenter.pending?(.discard)                                // alpha

        XCTAssertEqual(proceeded, true)
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertFalse(library.hasUnsavedChanges)
    }
}
