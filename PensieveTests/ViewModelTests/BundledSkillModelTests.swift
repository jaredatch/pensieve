import CryptoKit
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
        model.error = "Stale error"
        await model.refresh(context: fixture.context)
        XCTAssertEqual(model.error, "Stale error", "Unchanged skill state must preserve its error")
        XCTAssertEqual(model.state, .absent)
        await model.add(context: fixture.context)
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
        await model.add(context: fixture.context)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Skill>()), 1)
        try await assertUserNamedSkillIsPreserved()
        try await assertManifestFailureStillRecordsTheAddedSkill()
    }

    func testBundledUpdatePreservesEditsUntilReplacementAndRefusesUnsavedDraft() async throws {
        let fixture = try CLILibraryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let source = fixture.root + "/bundled"
        let original = try fixture.files.readFile(at: Bundle.main.bundlePath + "/Contents/Resources/pensieve/SKILL.md")
        try fixture.files.writeFile(at: source + "/SKILL.md", content: original)
        let library = fixture.runtime.library
        let observed = SettingsReadFiles(base: fixture.files)
        let model = BundledSkillModel(files: observed, bundledDirectory: source,
            receiptPath: fixture.paths.appSupportDir + "/bundled-receipt.json", lockPath: fixture.paths.syncLockPath,
            library: library, importer: fixture.paths.makeImportViewModel(
                notifier: { library.notifySyncedStateMutation() },
                echoRegistrar: { library.noteAppAuthoredBodies(directoryNames: $0) }))
        await model.add(context: fixture.context)
        XCTAssertNil(model.error)
        let skill = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<Skill>()).first)
        let path = fixture.paths.skillsDir + "/pensieve/SKILL.md"
        // A synced copy has its content but no receipt on this Mac.
        try fixture.files.deleteFile(at: fixture.paths.appSupportDir + "/bundled-receipt.json")
        let updated = Self.version(original, adding: "Bundled update one.")
        try fixture.files.writeFile(at: source + "/SKILL.md", content: updated)
        await model.refresh(context: fixture.context)
        XCTAssertEqual(model.state, .update)
        await assertUpdateWinsRefresh(model, observed: observed, context: fixture.context)
        XCTAssertNil(model.error)
        XCTAssertEqual(try fixture.files.readFile(at: path), updated)
        XCTAssertEqual(library.editorBody(for: skill), updated)
        XCTAssertEqual(model.state, .installed)
        let edited = updated + "\nMy saved edits.\n"
        try fixture.files.writeFile(at: path, content: edited)
        await model.refresh(context: fixture.context)
        XCTAssertEqual(model.state, .installed, "Local edits alone must not advertise a newer bundled skill")
        let next = Self.version(original, adding: "Bundled update two.")
        try fixture.files.writeFile(at: source + "/SKILL.md", content: next)
        await model.refresh(context: fixture.context)
        XCTAssertEqual(model.state, .edited)
        await model.update(context: fixture.context)
        XCTAssertNotNil(model.error)
        let refusal = model.error
        await model.refresh(context: fixture.context)
        XCTAssertEqual(model.error, refusal, "Focus refresh must preserve an applicable action error")
        XCTAssertEqual(try fixture.files.readFile(at: path), edited)
        await model.update(context: fixture.context, replaceEdits: true)
        XCTAssertNil(model.error)
        XCTAssertEqual(try fixture.files.readFile(at: path), next)
        XCTAssertEqual(model.state, .installed)
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: next + "unsaved draft")
        await model.update(context: fixture.context, replaceEdits: true)
        XCTAssertTrue(model.error?.contains("draft") == true)
        XCTAssertEqual(try fixture.files.readFile(at: path), next)
    }
    private func assertUpdateWinsRefresh(_ model: BundledSkillModel, observed: SettingsReadFiles, context: ModelContext) async {
        let gate = TestWait.Gate(owner: self)
        observed.pauseNextRead = gate
        let refresh = Task { await model.refresh(context: context) }
        await TestWait.until(failureMessage: "Skill refresh captures the pre-update bytes") { gate.waiterCount == 1 }
        await model.update(context: context)
        gate.open()
        await refresh.value
        XCTAssertEqual(model.state, .installed, "An older skill refresh cannot overwrite Update")
    }

    private static func version(_ original: String, adding body: String) -> String {
        let content = original.components(separatedBy: "\n").filter { !$0.hasPrefix("pensieve-bundled: ") }
            .joined(separator: "\n") + "\n" + body + "\n"
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        return content.replacingOccurrences(of: "---\nname: pensieve", with: "---\npensieve-bundled: \(digest)\nname: pensieve")
    }

    private func assertUserNamedSkillIsPreserved() async throws {
        let fixture = try CLILibraryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let own = "---\nname: pensieve\ndescription: My own skill\n---\nMy private instructions.\n"
        let directory = try fixture.runtime.library.skillStore.createSkill(name: "pensieve", content: own, avoiding: [])
        fixture.context.insert(Skill(name: "pensieve", directoryName: directory))
        try fixture.context.save()
        let model = fixture.runtime.bundledSkill
        await model.refresh(context: fixture.context)
        XCTAssertEqual(model.state, .absent, "A user's same-named skill must offer Add, never Replace")
        await model.add(context: fixture.context)
        XCTAssertNil(model.error, "An imported collision is still an added bundled skill")
        XCTAssertEqual(model.state, .installed)
        XCTAssertEqual(try fixture.files.readFile(at: fixture.paths.skillsDir + "/pensieve/SKILL.md"), own)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Skill>()), 2)
        await model.add(context: fixture.context)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Skill>()), 2, "Retry must not duplicate an imported skill")
        XCTAssertTrue(fixture.files.fileExists(at: fixture.paths.appSupportDir + "/pensieve-skill-receipt.json"))
    }
}
