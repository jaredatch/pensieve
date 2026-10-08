import XCTest
@testable import Pensieve

@MainActor
final class SkillHistoryPresentationTests: XCTestCase {
    func testPreviewBodyStripsFrontmatter() {
        let document = "---\nname: Example\ndescription: Test\n---\nBody\n"

        XCTAssertEqual(SkillHistoryPresentation.previewBody(from: document), "Body")
        // A document with no frontmatter passes through in the store's canonical form — outer newlines trimmed,
        // as every read of a body is (SkillParser.canonicalBody; PLAN-33 batch Layer-2, round 4).
        XCTAssertEqual(SkillHistoryPresentation.previewBody(from: "Body only\n"), "Body only")
    }

    func testSelectionKeepsRawDocumentAndStripsPreview() {
        let document = "---\nname: Example\ndescription: Test\n---\nBody\n"
        let selection = SkillHistorySelection(sha: "abc123", document: document)

        XCTAssertEqual(selection.document, document)
        XCTAssertEqual(selection.previewBody, "Body")
    }

    func testRestoreThroughSelectionWritesRawDocument() throws {
        let document = "---\nname: Example\ndescription: Test\n---\nBody\n"
        let selection = SkillHistorySelection(sha: "abc123", document: document)
        let skill = Skill(name: "Example", directoryName: "example")
        let store = RecordingHistorySkillStore()
        var nudgeCount = 0

        try restoreSkillHistoryVersion(
            skill: skill,
            body: selection.document,
            store: store,
            library: nil,
            notifier: { nudgeCount += 1 }
        )

        XCTAssertEqual(store.writtenBodies[skill.directoryName], document)
        XCTAssertEqual(nudgeCount, 1)
    }

    func testARefusedRestoreKeepsTheDraft() throws {
        let skill = Skill(name: "Example", directoryName: "example")
        let store = RecordingHistorySkillStore()
        try store.writeBody(directoryName: skill.directoryName, body: "A")
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "B")
        store.writeBodyFails = true
        let reloadToken = library.reloadToken

        XCTAssertThrowsError(try restoreSkillHistoryVersion(
            skill: skill, body: "Restored", store: store,
            library: library, notifier: {}
        ))

        XCTAssertEqual(library.drafts[skill.directoryName]?.body, "B")
        XCTAssertTrue(library.hasUnsavedChanges(for: skill))
        XCTAssertEqual(library.reloadToken, reloadToken)
    }

    func testRowTitleIsFormattedDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let commit = GitCommit(sha: "abc123", author: "A. User", date: date, subject: "Update")

        XCTAssertEqual(
            SkillHistoryPresentation.rowTitle(for: commit),
            date.formatted(date: .abbreviated, time: .shortened)
        )
    }

    func testRowSubtitleIsSubjectAndAuthor() {
        let commit = GitCommit(
            sha: "abc123",
            author: "A. User",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "Update documentation"
        )

        XCTAssertEqual(
            SkillHistoryPresentation.rowSubtitle(for: commit),
            "Update documentation · A. User"
        )
    }
}

private final class RecordingHistorySkillStore: SkillStoreProtocol {
    private(set) var writtenBodies: [String: String] = [:]
    var writeBodyFails = false

    func createSkill(name: String, description: String, body: String) throws -> String {
        SkillStore.slugify(name)
    }

    func readBody(directoryName: String) throws -> String { writtenBodies[directoryName] ?? "" }

    func rewriteSkill(directoryName: String, body: String, preserving parsed: ParsedSkill,
                      fallbackName: String, fallbackDescription: String) throws -> SkillRewriteResult {
        writtenBodies[directoryName] = SkillSerializer.rewrite(
            body: body,
            preserving: parsed,
            fallbackName: fallbackName,
            fallbackDescription: fallbackDescription
        ).content
        return SkillRewriteResult(content: writtenBodies[directoryName] ?? body, didChange: true)
    }

    func writeBody(directoryName: String, body: String) throws {
        if writeBodyFails { throw RecordingHistoryWriteFailure() }
        writtenBodies[directoryName] = body
    }

    func deleteSkill(directoryName: String) throws { writtenBodies[directoryName] = nil }
    func listSkills() throws -> [String] { Array(writtenBodies.keys) }
}

private struct RecordingHistoryWriteFailure: Error {}
