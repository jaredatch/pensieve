import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testInvalidSlugDeletionValidatesBeforeAnyArtifactProbe() throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        let sibling = Project(name: "Second", path: root + "/second")
        skill.directoryName = "~invalid"
        try harness.context.save()
        var probes: [String] = []
        mapped.beforeEntryTypeProbe = { probes.append($0) }
        mapped.beforeDeployStateRead = { probes.append($0) }
        defer { mapped.beforeEntryTypeProbe = nil; mapped.beforeDeployStateRead = nil }
        let cleanup = harness.vm.removeAllDeploys(skill: skill, projects: [project, sibling], localProjectEvidence: {
            XCTFail("Invalid slugs must not query history")
            throw DeletionTestError()
        })
        XCTAssertEqual(cleanup.batch.failureCount, 1, "Validate once before fan-out")
        XCTAssertTrue(probes.isEmpty, "Validation must precede state and artifact reads")
        let library = deletionLibrary()
        XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
            projects: [project], context: harness.context))
        XCTAssertTrue(library.deletionNotice?.message.contains("Invalid skill path component: ~invalid") == true)
        XCTAssertTrue(probes.isEmpty, "Invalid slugs must not reach artifact metadata: \(probes)")
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), 1)
        // Validation must surface even when an injected compiler owns no other artifacts.
        let vm = PlatformViewModel(
            fileService: mapped,
            linkService: TestPaths.linkService(fileService: mapped),
            cursorCompiler: AbsentCleanupCompiler(path: artifactPath(.cursor, project: project.path)),
            agentDetection: DeployStubDetection(installed: [.cursor]),
            deployStateStore: harness.state, skillsDirectory: TestPaths.skillsDir
        )
        let injectedLibrary = deletionLibrary()
        XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: injectedLibrary, platformVM: vm,
            projects: [project], context: harness.context))
        XCTAssertTrue(injectedLibrary.deletionNotice?.message.contains("Invalid skill path component: ~invalid") == true)
        XCTAssertFalse(injectedLibrary.deletionNotice?.message.contains("artifact(s)") == true)
        XCTAssertFalse(injectedLibrary.deletionNotice?.message.contains("Couldn't finish") == true)
        XCTAssertTrue(probes.isEmpty)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), 1)
    }

    @MainActor
    func testCleanupUsesInjectedCompilersPresenceBoundary() throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        let path = artifactPath(.cursor, project: project.path)
        let bytes = "---\n# pensieve: managed\n---\nOutside the injected compiler"
        try mapped.writeFile(at: path, content: bytes)
        let vm = PlatformViewModel(
            fileService: mapped,
            linkService: TestPaths.linkService(fileService: mapped),
            cursorCompiler: AbsentCleanupCompiler(path: path),
            agentDetection: DeployStubDetection(installed: [.cursor]),
            deployStateStore: harness.state, skillsDirectory: TestPaths.skillsDir
        )
        var evidence: SkillProjectDeployEvidence?
        let result = vm.removeAllDeploys(skill: skill, projects: [project], localProjectEvidence: {
            var local = try vm.localSkillProjectDeployEvidence(skill: skill, projects: [project], context: harness.context)
            local.historyFailure = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            evidence = local
            return local
        }).batch
        XCTAssertFalse(result.hasFailures)
        XCTAssertFalse(try XCTUnwrap(evidence).cursorHistoryPaths.contains(path), "No local history admits the external rule")
        XCTAssertEqual(try mapped.readFile(at: path), bytes)
    }

    @MainActor
    func testHistoryAdmittedMetadataFailureKeepsSkillAndRule() throws {
        try verifyMetadataFailure(historyAdmits: true)
    }

    @MainActor
    func testUnadmittedMetadataFailureDoesNotBlockSkillDeletion() throws {
        try verifyMetadataFailure(historyAdmits: false)
    }

    @MainActor
    private func verifyMetadataFailure(historyAdmits: Bool) throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        let path = artifactPath(.cursor, project: project.path)
        let bytes = "---\n# pensieve: managed\n---\nKeep after a metadata failure"
        try mapped.writeFile(at: path, content: bytes)
        if historyAdmits {
            harness.context.insert(DeployRecord(skillID: skill.id, platform: .cursor,
                targetPath: path, contentHash: "deployed here", projectID: project.id))
            try harness.context.save()
        }
        var probes = 0, opens = 0
        mapped.beforeEntryTypeProbe = { candidate in
            if candidate == path {
                probes += 1
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
        }
        mapped.beforeRuleRead = { candidate in if candidate == path { opens += 1 } }
        defer { mapped.beforeEntryTypeProbe = nil; mapped.beforeRuleRead = nil }
        let library = deletionLibrary()
        let deleted = SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
            projects: [project], context: harness.context)
        XCTAssertEqual(deleted, !historyAdmits)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(try mapped.readFile(at: path), bytes)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), historyAdmits ? 1 : 0)
        XCTAssertEqual(files.fileExists(at: root + "/store/skills/" + skill.directoryName + "/SKILL.md"), historyAdmits)
        if historyAdmits {
            XCTAssertTrue(library.deletionNotice?.message.contains("Could not check ownership") == true)
        } else {
            XCTAssertNil(library.deletionNotice)
        }
    }

    @MainActor
    func testDeletionNoticeMatchesActualCleanupChanges() throws {
        for removeArtifact in [false, true] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let path = artifactPath(.cursor, project: project.path)
            let bytes = "---\n# pensieve: managed\n---\nKeep unreadable rule"
            try mapped.writeFile(at: path, content: bytes)
            try harness.state.upsert(DeployStateRecord(slug: skill.directoryName, platform: "cursor", scope: "project",
                projectIdentityKey: project.identityKey, artifactPath: path, recordedAt: "2026-10-05T00:00:00Z"))
            let userPath = artifactPath(.cursor, project: nil)
            if removeArtifact {
                try compiler.compile(skill: skill, projectPath: nil)
                try harness.state.upsert(DeployStateRecord(slug: skill.directoryName, platform: "cursor", scope: "user",
                    projectIdentityKey: nil, artifactPath: userPath, recordedAt: "2026-10-05T00:00:00Z"))
            }
            mapped.beforeDeployStateWrite = { _ in
                if removeArtifact { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            }
            mapped.beforeRuleRead = { candidate in
                if candidate == path { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            }
            let library = deletionLibrary()
            XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
                projects: [project], context: harness.context))
            mapped.beforeDeployStateWrite = nil
            mapped.beforeRuleRead = nil
            XCTAssertEqual(library.deletionNotice?.message.contains("already removed"), removeArtifact)
            XCTAssertTrue(library.deletionNotice?.message.contains("Couldn't remove agent links and rules") == true)
            XCTAssertFalse(library.deletionNotice?.message.contains("artifact(s)") == true)
            XCTAssertTrue(library.deletionNotice?.message.contains("skill was kept") == true)
            XCTAssertEqual(try mapped.readFile(at: path), bytes)
            XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: userPath))
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), 1)
            if removeArtifact {
                XCTAssertTrue(try harness.state.recordedArtifactPaths().contains(userPath), "Failed retirement keeps its record")
            }
        }
    }

    private func deletionLibrary() -> SkillLibraryViewModel {
        SkillLibraryViewModel(
            skillStore: store,
            fileService: mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest"
        )
    }
}

private struct AbsentCleanupCompiler: CursorCompilerProtocol {
    func removalOperation(skill: Skill, platform: PlatformTarget,
                          projectPath: String?) -> DeployRemovalOperation {
        adapterRemovalOperation(skill: skill, projectPath: projectPath)
    }

    let path: String
    func compile(skill: Skill, projectPath: String?) throws {}
    func remove(skill: Skill, projectPath: String?) throws -> Bool { false }
    func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool { false }
    func probeRulePresence(skill: Skill, projectPath: String?) throws -> Bool {
        return false
    }
    func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool { false }
    func isUpToDate(skill: Skill, projectPath: String?) -> Bool { false }
    func outputPath(skill: Skill, projectPath: String?) -> String { path }
}
