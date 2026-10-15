import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class BundledSkillModelTests: XCTestCase {
    func testSettingsAddsBundledBytesThroughImportAndDeploysTheLibrarySkill() async throws {
        let fixture = try CLILibraryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let model = fixture.runtime.bundledSkill
        model.refresh(context: fixture.context)
        XCTAssertEqual(model.state, .absent)
        model.add(context: fixture.context)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.state, .installed)
        let skills = try fixture.context.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(skills.map(\.directoryName), ["pensieve"])
        let source = try fixture.files.readData(at: Bundle.main.bundlePath + "/Contents/Resources/pensieve/SKILL.md")
        XCTAssertEqual(try fixture.files.readData(at: fixture.paths.skillsDir + "/pensieve/SKILL.md"), source)
        XCTAssertEqual(try fixture.files.listDirectory(at: fixture.paths.skillsDir + "/pensieve"), ["SKILL.md"])
        _ = try await fixture.run(["deploy", "pensieve", "-a", "claude", "-g"])
        XCTAssertEqual(try fixture.files.symlinkTarget(at: fixture.root + "/home/.claude/skills/pensieve"),
                       fixture.paths.skillsDir + "/pensieve")
        model.add(context: fixture.context)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Skill>()), 1)
    }

    func testBundledUpdatePreservesEditsUntilReplacementAndRefusesUnsavedDraft() async throws {
        let fixture = try CLILibraryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let source = fixture.root + "/bundled"
        let original = try fixture.files.readFile(at: Bundle.main.bundlePath + "/Contents/Resources/pensieve/SKILL.md")
        try fixture.files.writeFile(at: source + "/SKILL.md", content: original)
        let library = fixture.runtime.library
        let model = BundledSkillModel(files: fixture.files, bundledDirectory: source,
            receiptPath: fixture.paths.appSupportDir + "/bundled-receipt.json", lockPath: fixture.paths.syncLockPath,
            library: library, importer: fixture.paths.makeImportViewModel(
                notifier: { library.notifySyncedStateMutation() },
                echoRegistrar: { library.noteAppAuthoredBodies(directoryNames: $0) }))
        model.add(context: fixture.context)
        XCTAssertNil(model.error)
        let skill = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<Skill>()).first)
        let path = fixture.paths.skillsDir + "/pensieve/SKILL.md"
        let updated = original + "\nBundled update one.\n"
        try fixture.files.writeFile(at: source + "/SKILL.md", content: updated)
        model.refresh(context: fixture.context)
        XCTAssertEqual(model.state, .update)
        model.update(context: fixture.context)
        XCTAssertNil(model.error)
        XCTAssertEqual(try fixture.files.readFile(at: path), updated)
        XCTAssertEqual(library.editorBody(for: skill), updated)
        XCTAssertEqual(model.state, .installed)
        let edited = updated + "\nMy saved edits.\n"
        try fixture.files.writeFile(at: path, content: edited)
        model.refresh(context: fixture.context)
        XCTAssertEqual(model.state, .installed, "Local edits alone must not advertise a newer bundled skill")
        let next = original + "\nBundled update two.\n"
        try fixture.files.writeFile(at: source + "/SKILL.md", content: next)
        model.refresh(context: fixture.context)
        XCTAssertEqual(model.state, .edited)
        model.update(context: fixture.context)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try fixture.files.readFile(at: path), edited)
        model.update(context: fixture.context, replaceEdits: true)
        XCTAssertNil(model.error)
        XCTAssertEqual(try fixture.files.readFile(at: path), next)
        XCTAssertEqual(model.state, .installed)
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: next + "unsaved draft")
        model.update(context: fixture.context, replaceEdits: true)
        XCTAssertTrue(model.error?.contains("draft") == true)
        XCTAssertEqual(try fixture.files.readFile(at: path), next)
    }
}
