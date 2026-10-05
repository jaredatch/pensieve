import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testInvalidSlugDeletionValidatesBeforeAnyArtifactProbe() throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        skill.directoryName = "~invalid"
        try harness.context.save()
        var probes: [String] = []
        mapped.beforeEntryTypeProbe = { probes.append($0) }
        defer { mapped.beforeEntryTypeProbe = nil }
        let library = deletionLibrary()
        XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
            projects: [project], context: harness.context))
        XCTAssertTrue(library.deletionNotice?.message.contains("Invalid skill path component: ~invalid") == true)
        XCTAssertTrue(probes.isEmpty, "Invalid slugs must not reach artifact metadata: \(probes)")
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), 1)
        // Validation must surface even when an injected compiler owns no other artifacts.
        let vm = PlatformViewModel(fileService: mapped,
            cursorCompiler: AbsentCleanupCompiler(path: artifactPath(.cursor, project: project.path)),
            agentDetection: DeployStubDetection(installed: [.cursor]), deployStateStore: harness.state)
        let injectedLibrary = deletionLibrary()
        XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: injectedLibrary, platformVM: vm,
            projects: [project], context: harness.context))
        XCTAssertTrue(injectedLibrary.deletionNotice?.message.contains("Invalid skill path component: ~invalid") == true)
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
        let vm = PlatformViewModel(fileService: mapped, cursorCompiler: AbsentCleanupCompiler(path: path),
            agentDetection: DeployStubDetection(installed: [.cursor]), deployStateStore: harness.state)
        var requestedHistory = false
        let result = vm.removeAllDeploys(skill: skill, projects: [project], localDeployHistory: { _ in
            requestedHistory = true
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }).batch
        XCTAssertFalse(result.hasFailures)
        XCTAssertFalse(requestedHistory)
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
            var stateReads = 0
            mapped.beforeDeployStateRead = { _ in
                stateReads += 1
                // The snapshot succeeds; retirement then fails after the owned artifact was removed.
                if removeArtifact && stateReads > 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            }
            mapped.beforeRuleRead = { candidate in
                if candidate == path { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            }
            let library = deletionLibrary()
            XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
                projects: [project], context: harness.context))
            mapped.beforeDeployStateRead = nil
            mapped.beforeRuleRead = nil
            XCTAssertEqual(library.deletionNotice?.message.contains("already removed"), removeArtifact)
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
        SkillLibraryViewModel(skillStore: store, fileService: mapped,
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
    }
}

private struct AbsentCleanupCompiler: CursorCompilerProtocol {
    let path: String
    func compile(skill: Skill, projectPath: String?) throws {}
    func remove(skill: Skill, projectPath: String?) throws {}
    func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool { false }
    func ruleMayExist(skill: Skill, projectPath: String?) throws -> Bool {
        try LinkService.validatePathComponent(skill.directoryName)
        return false
    }
    func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool { false }
    func isUpToDate(skill: Skill, projectPath: String?) -> Bool { false }
    func outputPath(skill: Skill, projectPath: String?) -> String { path }
}
