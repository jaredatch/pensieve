import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testUnrelatedHistoryFetchFailureDoesNotBlockSkillDeletion() throws {
        let url = URL(fileURLWithPath: root + "/history.sqlite")
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: url))
        let context = ModelContext(container)
        context.insert(skill)
        try context.save()
        let state = DeployStateStore(fileService: mapped, appSupportDir: root + "/support")
        let vm = PlatformViewModel(fileService: mapped, cursorCompiler: compiler,
            agentDetection: DeployStubDetection(installed: PlatformTarget.allCases), deployStateStore: state)
        let project = reviewProject(context)
        // No project Cursor pair exists. User-wide rules need no project history evidence.
        let path = artifactPath(.cursor, project: nil)
        try compiler.compile(skill: skill, projectPath: nil)
        try renameHistoryTable(at: url.path, broken: true)
        defer { try? renameHistoryTable(at: url.path, broken: false) }
        XCTAssertThrowsError(try context.fetch(FetchDescriptor<DeployRecord>()))
        let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
        XCTAssertTrue(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: vm,
            projects: [project], context: context), library.deletionNotice?.message ?? "Deletion failed")
        XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Skill>()), 0)
    }

    @MainActor
    func testDeletionEvidenceIncludesOnlyThisSkillsProjectCursorRecords() throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        let path = artifactPath(.cursor, project: project.path)
        let bytes = "---\n# pensieve: managed\n---\nTeammate rule"
        try mapped.writeFile(at: path, content: bytes)
        harness.context.insert(DeployRecord(skillID: skill.id, platform: .claudeCode,
            targetPath: path, contentHash: "wrong agent", projectID: project.id))
        harness.context.insert(DeployRecord(skillID: skill.id, platform: .cursor,
            targetPath: path, contentHash: "user-wide"))
        harness.context.insert(DeployRecord(skillID: UUID(), platform: .cursor,
            targetPath: path, contentHash: "other skill", projectID: project.id))
        try harness.context.save()
        let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
        XCTAssertTrue(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
            projects: [project], context: harness.context))
        XCTAssertEqual(try mapped.readFile(at: path), bytes)
    }

    private func renameHistoryTable(at path: String, broken: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, broken
            ? "ALTER TABLE ZDEPLOYRECORD RENAME TO ZDEPLOYRECORD_BROKEN;"
            : "ALTER TABLE ZDEPLOYRECORD_BROKEN RENAME TO ZDEPLOYRECORD;"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let diagnostics = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)
    }
}
