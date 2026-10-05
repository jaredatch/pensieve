import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testFirstStateReadFailureCannotOrphanHistoryAdmittedRule() throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        let path = artifactPath(.cursor, project: project.path)
        try compiler.compile(skill: skill, projectPath: project.path)
        let bytes = try mapped.readFile(at: path)
        harness.context.insert(DeployRecord(skillID: skill.id, platform: .cursor,
            targetPath: path, contentHash: "deployed here", projectID: project.id))
        try harness.context.save()
        try harness.state.replaceAll([])
        var reads = 0
        mapped.beforeDeployStateRead = { _ in
            reads += 1
            if reads == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        }
        defer { mapped.beforeDeployStateRead = nil }
        let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
        let deleted = SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
            projects: [project], context: harness.context)
        XCTAssertGreaterThan(reads, 0, "The state read fault must fire")
        if deleted {
            XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path), "Deletion must not orphan its rule")
        } else {
            XCTAssertEqual(try mapped.readFile(at: path), bytes)
            XCTAssertTrue(files.fileExists(at: root + "/store/skills/" + skill.directoryName + "/SKILL.md"))
            XCTAssertNotNil(library.deletionNotice)
        }
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), deleted ? 0 : 1)
    }

    @MainActor
    func testNeededHistoryFetchFailureKeepsSkillAndProjectRule() throws {
        let (harness, project) = try persistentHistoryHarness(projectRule: true)
        let context = harness.context
        let path = artifactPath(.cursor, project: project.path)
        let bytes = try mapped.readFile(at: path)
        XCTAssertTrue(try harness.state.recordedArtifactPaths().isEmpty)
        let url = URL(fileURLWithPath: root + "/history.sqlite")
        try renameHistoryTable(at: url.path, broken: true)
        defer { try? renameHistoryTable(at: url.path, broken: false) }
        XCTAssertThrowsError(try context.fetch(FetchDescriptor<DeployRecord>()))
        let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
        XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
            projects: [project], context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Skill>()), 1)
        XCTAssertTrue(files.fileExists(at: root + "/store/skills/" + skill.directoryName + "/SKILL.md"))
        XCTAssertEqual(try mapped.readFile(at: path), bytes)
        XCTAssertTrue(library.deletionNotice?.message.contains("local deploy history") == true)
    }

    @MainActor
    func testUnrelatedHistoryFetchFailureDoesNotBlockSkillDeletion() throws {
        let (harness, project) = try persistentHistoryHarness(projectRule: false)
        let context = harness.context
        // No project Cursor pair exists. User-wide rules need no project history evidence.
        let path = artifactPath(.cursor, project: nil)
        let url = URL(fileURLWithPath: root + "/history.sqlite")
        try renameHistoryTable(at: url.path, broken: true)
        defer { try? renameHistoryTable(at: url.path, broken: false) }
        XCTAssertThrowsError(try context.fetch(FetchDescriptor<DeployRecord>()))
        let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
        XCTAssertTrue(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
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

    @MainActor
    private func persistentHistoryHarness(projectRule: Bool) throws -> (OwnershipRouteHarness, Project) {
        let url = URL(fileURLWithPath: root + "/history.sqlite")
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: url))
        let context = ModelContext(container)
        context.insert(skill)
        try context.save()
        let state = DeployStateStore(fileService: mapped, appSupportDir: root + "/support")
        let vm = PlatformViewModel(fileService: mapped, cursorCompiler: compiler,
            agentDetection: DeployStubDetection(installed: PlatformTarget.allCases), deployStateStore: state)
        let project = reviewProject(context)
        let projectPath = projectRule ? project.path : nil
        try compiler.compile(skill: skill, projectPath: projectPath)
        if projectRule {
            context.insert(DeployRecord(skillID: skill.id, platform: .cursor,
                targetPath: artifactPath(.cursor, project: projectPath), contentHash: "deployed here", projectID: project.id))
        }
        try context.save()
        return (OwnershipRouteHarness(context: context, vm: vm, state: state), project)
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
