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
        let library = SkillLibraryViewModel(
            skillStore: store,
            fileService: mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest"
        )
        let deleted = SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
            projects: [project], context: harness.context)
        XCTAssertGreaterThan(reads, 0, "The state read fault must fire")
        XCTAssertFalse(deleted)
        XCTAssertEqual(try mapped.readFile(at: path), bytes)
        XCTAssertTrue(files.fileExists(at: root + "/store/skills/" + skill.directoryName + "/SKILL.md"))
        XCTAssertTrue(library.deletionNotice?.message.contains("deploy state unreadable") == true)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), 1)
    }

    @MainActor
    func testProjectRuleOwnershipIsReadOnlyAfterLocalDeployEvidence() throws {
        for evidence in ["none", "state", "history"] {
            try store.writeBody(directoryName: skill.directoryName, body: "# Body")
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let path = artifactPath(.cursor, project: project.path)
            let bytes = "---\n# pensieve: managed\n---\nKeep this rule"
            try mapped.writeFile(at: path, content: bytes)
            try harness.state.replaceAll([])
            if evidence == "state" {
                try harness.state.upsert(DeployStateRecord(slug: skill.directoryName, platform: "cursor",
                    scope: "project", projectIdentityKey: project.identityKey,
                    artifactPath: path, recordedAt: "2026-10-05T00:00:00Z"))
            } else if evidence == "history" {
                harness.context.insert(DeployRecord(skillID: skill.id, platform: .cursor,
                    targetPath: path, contentHash: "deployed here", projectID: project.id))
                try harness.context.save()
            }
            var reads = 0
            mapped.beforeRuleRead = { candidate in
                if candidate == path {
                    reads += 1
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
            }
            let library = SkillLibraryViewModel(
                skillStore: store,
                fileService: mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
                manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest"
            )
            let deleted = SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
                projects: [project], context: harness.context)
            mapped.beforeRuleRead = nil
            XCTAssertEqual(deleted, evidence == "none", evidence)
            XCTAssertEqual(reads, evidence == "none" ? 0 : 1, evidence)
            XCTAssertEqual(try mapped.readFile(at: path), bytes, evidence)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), evidence == "none" ? 0 : 1, evidence)
            XCTAssertEqual(files.fileExists(at: root + "/store/skills/" + skill.directoryName + "/SKILL.md"),
                           evidence != "none", evidence)
            if evidence != "none" {
                XCTAssertTrue(library.deletionNotice?.message.contains("Could not check ownership") == true, evidence)
            }
        }
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
        let library = SkillLibraryViewModel(
            skillStore: store,
            fileService: mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest"
        )
        XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
            projects: [project], context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Skill>()), 1)
        XCTAssertTrue(files.fileExists(at: root + "/store/skills/" + skill.directoryName + "/SKILL.md"))
        XCTAssertEqual(try mapped.readFile(at: path), bytes)
        XCTAssertTrue(library.deletionNotice?.message.contains("local deploy history") == true)
        XCTAssertTrue(library.deletionNotice?.message.contains("stopped before changing any deploys") == true)
        XCTAssertTrue(library.deletionNotice?.message.contains("skill was kept") == true)
        XCTAssertFalse(library.deletionNotice?.message.contains("already removed") == true)
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
        let library = SkillLibraryViewModel(
            skillStore: store,
            fileService: mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest"
        )
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
        let library = SkillLibraryViewModel(
            skillStore: store,
            fileService: mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest"
        )
        XCTAssertTrue(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
            projects: [project], context: harness.context))
        XCTAssertEqual(try mapped.readFile(at: path), bytes)
    }

    @MainActor
    func testFailedHistoryFetchWithMissingProjectKeepsSkillAndHiddenRule() throws {
        let (harness, project) = try persistentHistoryHarness(projectRule: true)
        let path = artifactPath(.cursor, project: project.path)
        let bytes = try mapped.readFile(at: path)
        let hidden = root + "/offline"
        try files.replaceItem(at: hidden, with: project.path)
        let database = root + "/history.sqlite"
        try renameHistoryTable(at: database, broken: true)
        defer { try? renameHistoryTable(at: database, broken: false) }
        var historyMessage = ""
        XCTAssertThrowsError(try harness.context.fetch(FetchDescriptor<DeployRecord>())) {
            historyMessage = $0.localizedDescription
        }
        let library = SkillLibraryViewModel(
            skillStore: store,
            fileService: mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest"
        )
        XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
            projects: [project], context: harness.context))
        XCTAssertFalse(historyMessage.isEmpty)
        XCTAssertTrue(library.deletionNotice?.message.contains(historyMessage) == true)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), 1)
        XCTAssertTrue(files.fileExists(at: root + "/store/skills/" + skill.directoryName + "/SKILL.md"))
        let hiddenRule = hidden + String(path.dropFirst(project.path.count))
        XCTAssertEqual(try files.readFile(at: hiddenRule), bytes)
        XCTAssertTrue(try harness.vm.waitingRemovalStore.read().isEmpty)
    }

    @MainActor
    private func persistentHistoryHarness(projectRule: Bool) throws -> (OwnershipRouteHarness, Project) {
        let url = URL(fileURLWithPath: root + "/history.sqlite")
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: url))
        let context = ModelContext(container)
        context.insert(skill)
        try context.save()
        let state = DeployStateStore(fileService: mapped, appSupportDir: root + "/support")
        let vm = PlatformViewModel(
            fileService: mapped,
            linkService: TestPaths.linkService(fileService: mapped),
            cursorCompiler: compiler,
            agentDetection: DeployStubDetection(installed: PlatformTarget.allCases),
            deployStateStore: state, skillsDirectory: TestPaths.skillsDir
        )
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
