import SwiftData
import XCTest
@testable import Pensieve

/// Explicit save (PLAN-33): the draft owner on the library view model — a keystroke is a draft,
/// nothing reaches disk until Save, Revert drops it, and every way out passes `confirmLeaving`.
final class SkillLibrarySaveTests: XCTestCase {
    @MainActor
    func testCRLFEditorSaveIsAnEchoWithoutReloadOrOutsideChange() throws {
        let files = FileService()
        let root = TestTemporaryDirectory.path + "CRLFSave-" + UUID().uuidString
        defer { try? files.deleteDirectory(at: root) }
        let store = SkillStore(fileService: files, baseDir: root)
        let slug = try store.createSkill(name: "Test", description: "D", body: "Old")
        try files.writeFile(at: root + "/" + slug + "/SKILL.md",
                            content: "---\r\nname: Test\r\ndescription: D\r\n---\r\n\r\nOld\r\n")
        let watcher = RecordingWatcher()
        let library = SkillLibraryViewModel(skillStore: store, fileService: files, fileWatchService: watcher)
        let skill = Skill(name: "Test", directoryName: slug)
        library.startWatching()
        _ = library.editorBody(for: skill)
        let token = library.reloadToken
        library.noteEditorChanged(skill, body: "Edited\nSecond")
        XCTAssertTrue(library.saveDraft(skill))
        let body = library.currentOnDiskBody(directoryName: slug)
        XCTAssertEqual(body, "Edited\r\nSecond")
        XCTAssertTrue(library.wasLastWrittenByApp(directoryName: slug, currentBody: body))
        watcher.emit(slug)
        XCTAssertEqual(library.reloadToken, token)
        XCTAssertTrue(library.externallyModified.isEmpty)
    }

    private func makeSkill() -> Skill { Skill(name: "Test Skill", directoryName: "test-skill") }

    func testLoadIsCleanAndSeedsTheFingerprint() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let skill = makeSkill()

        XCTAssertEqual(library.editorBody(for: skill), "A")

        XCTAssertFalse(library.hasUnsavedChanges(for: skill))
        XCTAssertFalse(library.hasUnsavedChanges)
        XCTAssertNil(library.unsavedDirectoryName)
        XCTAssertTrue(library.wasLastWrittenByApp(directoryName: skill.directoryName, currentBody: "A"))
    }

    func testAChangeMakesTheDraftDirtyAndWritesNothing() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let skill = makeSkill()
        _ = library.editorBody(for: skill)

        library.noteEditorChanged(skill, body: "B")

        XCTAssertTrue(library.hasUnsavedChanges(for: skill))
        XCTAssertEqual(library.unsavedDirectoryName, "test-skill")
        XCTAssertEqual(store.writeCount, 0)
    }

    func testAChangeBackToTheFileIsClean() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let skill = makeSkill()
        _ = library.editorBody(for: skill)

        library.noteEditorChanged(skill, body: "B")
        library.noteEditorChanged(skill, body: "A")

        XCTAssertFalse(library.hasUnsavedChanges(for: skill))
        XCTAssertTrue(library.drafts.isEmpty)
        XCTAssertEqual(store.writeCount, 0)
    }

    func testTypingBackToTheFileWithATrailingNewlineIsClean() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let skill = makeSkill()
        _ = library.editorBody(for: skill)

        library.noteEditorChanged(skill, body: "A\n")

        XCTAssertFalse(library.hasUnsavedChanges(for: skill))
        XCTAssertTrue(library.drafts.isEmpty)
        library.noteEditorChanged(skill, body: "A\nB")
        XCTAssertTrue(library.hasUnsavedChanges(for: skill))
    }

    func testEditorBodyReturnsTheDraftWhileDirty() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")

        XCTAssertEqual(library.editorBody(for: skill), "B")
        XCTAssertTrue(library.wasLastWrittenByApp(directoryName: skill.directoryName, currentBody: "A"))
    }

    func testSaveWritesOnceRecordsTheFingerprintAndNotifies() {
        let store = CountingSkillStore(body: "A")
        var nudges = 0
        let library = SkillLibraryViewModel(skillStore: store, notifier: { nudges += 1 })
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")

        XCTAssertTrue(library.saveDraft(skill))

        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(store.lastWrittenBody, "B")
        XCTAssertFalse(library.hasUnsavedChanges(for: skill))
        XCTAssertTrue(library.wasLastWrittenByApp(directoryName: skill.directoryName, currentBody: "B"))
        XCTAssertEqual(nudges, 1)
    }

    func testSaveWithNoDraftWritesNothing() {
        let store = CountingSkillStore(body: "A")
        var nudges = 0
        let library = SkillLibraryViewModel(skillStore: store, notifier: { nudges += 1 })
        let skill = makeSkill()
        _ = library.editorBody(for: skill)

        XCTAssertTrue(library.saveDraft(skill))

        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(nudges, 0)
    }

    func testAnEmptyDraftOverAVanishedFileReadsCleanAndSaveStillRefuses() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "")
        store.filesGone = true
        library.acceptExternalChange(directoryName: skill.directoryName, currentBody: "", shouldNotify: false)

        XCTAssertFalse(library.hasUnsavedChanges(for: skill))
        XCTAssertNotNil(library.drafts[skill.directoryName])
        XCTAssertFalse(library.saveDraft(skill))
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertNotNil(library.error)
    }

    func testRevertDropsTheDraftWithoutWritingAndAsksTheEditorToReload() {
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")
        let before = library.reloadToken

        library.discardDraft(skill)

        XCTAssertFalse(library.hasUnsavedChanges(for: skill))
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(library.reloadToken, before + 1)

        library.discardDraft(skill)                        // nothing to drop: no reload signal either
        XCTAssertEqual(library.reloadToken, before + 1)
    }

    func testAFailedSaveKeepsTheDraftAndSurfacesTheError() {
        var nudges = 0
        let library = SkillLibraryViewModel(skillStore: ThrowingSkillStore(), notifier: { nudges += 1 })
        let skill = makeSkill()
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")

        XCTAssertFalse(library.saveDraft(skill))

        XCTAssertTrue(library.hasUnsavedChanges(for: skill))
        XCTAssertEqual(library.drafts[skill.directoryName]?.body, "B")
        XCTAssertNotNil(library.error)
        XCTAssertEqual(nudges, 0)
    }

    func testSaveUnsavedDraftsSavesEveryDirtySkill() {
        // ⌘S with two dirty drafts (reachable: an entry kept clean by a file that caught up, made dirty again
        // by an external change while another skill was edited) writes both, first by name.
        let store = CountingSkillStore(body: "A")
        let library = SkillLibraryViewModel(skillStore: store)
        let skillX = Skill(name: "Skill X", directoryName: "skill-x")
        let skillY = Skill(name: "Skill Y", directoryName: "skill-y")
        _ = library.editorBody(for: skillX)
        _ = library.editorBody(for: skillY)
        library.noteEditorChanged(skillY, body: "Y edited")
        XCTAssertTrue(library.saveUnsavedDrafts())
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(store.lastWrittenBody, "Y edited")
        XCTAssertFalse(library.hasUnsavedChanges)

        library.noteEditorChanged(skillX, body: "X edited")
        library.noteEditorChanged(skillY, body: "Y again")
        XCTAssertTrue(library.saveUnsavedDrafts())
        XCTAssertEqual(store.writeCount, 3)
        XCTAssertEqual(store.lastWrittenBody, "Y again")            // X first by name, then Y
        XCTAssertFalse(library.hasUnsavedChanges)
    }

    @MainActor
    func testDeletingASkillDiscardsItsDraftSoItIsNotResurrected() throws {
        // Edit a skill, then delete it. The draft must go with the row — a later Save of a surviving
        // draft would write an orphan SKILL.md back onto disk.
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, IntentAssignment.self,
            MachineDeployIntent.self, ScenarioAssignment.self, DeployRecord.self, Category.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let store = CountingSkillStore(body: "original")
        let library = SkillLibraryViewModel(skillStore: store)
        let skill = Skill(name: "Doomed", directoryName: "doomed")
        context.insert(skill)
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "edited")
        XCTAssertTrue(SkillDeletionFlow.delete(
            skill: skill, library: library,
            platformVM: PlatformViewModel(agentDetection: ZeroInstalledAgentDetection(), deployStateStore: .memoryBacked),
            projects: [], context: context
        ))

        XCTAssertFalse(library.hasUnsavedChanges(for: skill))
        XCTAssertTrue(library.saveDraft(skill))            // nothing left to save
        XCTAssertEqual(store.writeCount, 0)
    }
}

/// The sheet as a recorder: `answer` nil holds the question open for the test to resolve.
final class RecordingPresenter {
    var prompts: [UnsavedChangesPrompt] = []
    var answer: UnsavedChangesChoice?
    var pending: ((UnsavedChangesChoice) -> Void)?

    func present(_ prompt: UnsavedChangesPrompt, resolve: @escaping (UnsavedChangesChoice) -> Void) {
        prompts.append(prompt)
        if let answer { resolve(answer) } else { pending = resolve }
    }
}

private struct ZeroInstalledAgentDetection: AgentDetectionServiceProtocol {
    func isInstalled(_ platform: PlatformTarget) -> Bool { false }
    func installedPlatforms() -> [PlatformTarget] { [] }
}

private struct SaveFailure: Error {}
private struct FilesGone: Error {}

/// A store whose canonical writer refuses every write; reads answer "A".
final class ThrowingSkillStore: SkillStoreProtocol {
    func createSkill(name: String, description: String, body: String) throws -> String { "created-skill" }
    func readBody(directoryName: String) throws -> String { "A" }
    func rewriteSkill(directoryName: String, body: String, preserving parsed: ParsedSkill,
                      fallbackName: String, fallbackDescription: String) throws -> SkillRewriteResult { throw SaveFailure() }
    func writeBody(directoryName: String, body: String) throws { throw SaveFailure() }
    func deleteSkill(directoryName: String) throws {}
    func listSkills() throws -> [String] { [] }
}

final class CountingSkillStore: SkillStoreProtocol {
    private(set) var writeCount = 0
    private(set) var lastWrittenBody: String?
    /// The skill's files removed from under the app: every read fails, as `FileService` would.
    var filesGone = false
    var rewriteOverride: String?

    init(body: String? = nil) {
        lastWrittenBody = body
    }

    func createSkill(name: String, description: String, body: String) throws -> String {
        "created-skill"
    }

    func readBody(directoryName: String) throws -> String {
        if filesGone { throw FilesGone() }
        return lastWrittenBody ?? ""
    }

    func rewriteSkill(directoryName: String, body: String, preserving parsed: ParsedSkill,
                      fallbackName: String, fallbackDescription: String) throws -> SkillRewriteResult {
        writeCount += 1
        lastWrittenBody = rewriteOverride ?? body
        return SkillRewriteResult(content: lastWrittenBody ?? body, didChange: true)
    }

    func writeBody(directoryName: String, body: String) throws {
        writeCount += 1
        lastWrittenBody = body
    }

    func deleteSkill(directoryName: String) throws {}

    func listSkills() throws -> [String] {
        []
    }
}
