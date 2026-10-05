import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectRemovalTests: XCTestCase {
    func testRemovalUsesOnlyLocalLedgerStateOrHistory() throws {
        for evidence in ["category", "intent", "state", "history", "none"] {
            for platform in [PlatformTarget.claudeCode, .grok, .codex, .cursor] {
                for owned in [false, true] {
                    let h = try ProjectFolderCallerHarness(installed: [platform])
                    defer { h.cleanup() }
                    try h.files.createDirectory(at: h.project.path)
                    let path = try plant(h, platform: platform)
                    if !owned {
                        try h.files.deleteFile(at: path)
                        if platform == .cursor { try h.files.writeFile(at: path, content: "User's rule") } else {
                            try h.files.createSymlink(at: path, pointingTo: h.otherProject.path)
                        }
                    }
                    try record(h, platform: platform, path: path, evidence: evidence)
                    let result = remove(h)
                    XCTAssertFalse(result.hasFailures, "\(evidence)/\(platform)/\(owned)")
                    XCTAssertEqual(try h.files.entryExistsWithoutFollowingLinks(at: path), !owned || evidence == "none")
                    if !owned && platform == .cursor { XCTAssertEqual(try h.files.readFile(at: path), "User's rule") }
                    if !owned && platform != .cursor {
                        XCTAssertEqual(try h.files.symlinkTarget(at: path), h.otherProject.path)
                    }
                    XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 1)
                    XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
                    XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
                    XCTAssertTrue(try h.deployState.recordedArtifactPaths().isEmpty)
                }
            }
        }
    }

    func testRemovalRetiresOnlyLocalProjectIntentsInStoreAndManifest() throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        _ = try h.addCategory()
        XCTAssertFalse(h.category.reconcile(context: h.context).hasFailures)
        for platform in [PlatformTarget.codex, .cursor] { try h.addIntent(platform: platform) }
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.remoteID,
            skillSlug: h.skill.directoryName, platformRaw: "cursor", projectKey: h.project.identityKey))
        h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.localID,
            skillSlug: h.skill.directoryName, platformRaw: "codex"))
        try h.context.save()
        let manifest = ManifestService(fileService: h.files)
        try manifest.write(try manifest.snapshot(from: h.context), toRoot: h.root + "/sync")
        let userFile = h.project.path + "/notes.txt"
        try h.files.writeFile(at: userFile, content: "Keep my notes")
        let teamRule = h.project.path + "/.cursor/rules/teammate.mdc"
        try h.files.writeFile(at: teamRule, content: "---\n# pensieve: managed\n---\nTeammate's rule")
        let result = remove(h, manifest: manifest)
        XCTAssertFalse(result.hasFailures)
        for platform in [PlatformTarget.claudeCode, .grok, .codex, .cursor] {
            XCTAssertFalse(try h.files.entryExistsWithoutFollowingLinks(at: h.platformVM.artifactPath(
                skill: h.skill, platform: platform, target: .project(h.project))))
        }
        XCTAssertEqual(try h.files.readFile(at: userFile), "Keep my notes")
        XCTAssertEqual(try h.files.readFile(at: teamRule), "---\n# pensieve: managed\n---\nTeammate's rule")
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        let remaining = try h.context.fetch(FetchDescriptor<MachineDeployIntent>())
        XCTAssertEqual(remaining.count, 2)
        XCTAssertFalse(remaining.contains { $0.machineID == ProjectIntentHarness.localID && $0.projectKey != nil })
        let snapshot = try manifest.read(fromRoot: h.root + "/sync")
        XCTAssertEqual(snapshot.deployIntents.count, 2)
        XCTAssertFalse(snapshot.deployIntents.contains { $0.machineID == ProjectIntentHarness.localID && $0.projectKey != nil })
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).allSatisfy { $0.projectKeys.isEmpty })
    }

    func testSameKeySiblingKeepsDeploysIntentsMembershipAndLedger() throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        h.otherProject.identityKey = h.project.identityKey
        let category = try h.addCategory()
        try h.addIntent(platform: .cursor)
        XCTAssertFalse(h.category.reconcile(context: h.context).hasFailures)
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        let siblingPaths = [PlatformTarget.claudeCode, .grok, .codex, .cursor].map {
            h.platformVM.artifactPath(skill: h.skill, platform: $0, target: .project(h.otherProject))
        }
        let cursorBytes = try h.files.readFile(at: siblingPaths[3])
        let categoryIDs = Set(try h.context.fetch(FetchDescriptor<SkillProjectAssignment>())
            .filter { $0.projectID == h.otherProject.id }.map(\.id))
        let result = remove(h, manifest: ManifestService(fileService: h.files))
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(category.projectKeys, [h.otherProject.identityKey!])
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<SkillProjectAssignment>()).map(\.id)), categoryIDs)
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<IntentAssignment>()).map(\.projectID), [h.otherProject.id])
        for path in siblingPaths { XCTAssertTrue(try h.files.entryExistsWithoutFollowingLinks(at: path)) }
        XCTAssertEqual(try h.files.readFile(at: siblingPaths[3]), cursorBytes)
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<Project>()).map(\.id), [h.otherProject.id])
    }

    func testPartialRemovalKeepsFailedLedgerAndNamesArtifact() throws {
        let h = try ProjectFolderCallerHarness(installed: [.claudeCode, .codex])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        try h.addIntent(platform: .claudeCode)
        try h.addIntent(platform: .codex)
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        let failedPath = h.artifact(.codex)
        h.mapped.beforeArtifactDeletion = { path in
            if path == failedPath { throw NSError(domain: NSPOSIXErrorDomain, code: 13) }
        }
        let result = remove(h)
        XCTAssertTrue(result.hasFailures)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
        XCTAssertTrue(h.files.isSymlink(at: failedPath))
        XCTAssertFalse(h.files.isSymlink(at: h.artifact(.claudeCode)))
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<IntentAssignment>()).contains { $0.platformRaw == "codex" })
        XCTAssertTrue(ProjectListView.removalFailureMessage(projectName: h.project.name, result: result).contains(failedPath))
        h.mapped.beforeArtifactDeletion = nil
        XCTAssertFalse(remove(h).hasFailures)
        XCTAssertFalse(h.files.isSymlink(at: failedPath))
    }

    private func plant(_ h: ProjectFolderCallerHarness, platform: PlatformTarget) throws -> String {
        if platform == .cursor {
            try CursorCompiler(fileService: h.mapped, skillStore: SkillStore(fileService: h.files,
                baseDir: h.root + "/store/skills")).compile(skill: h.skill, projectPath: h.project.path)
        } else {
            try LinkService(fileService: h.mapped).link(skill: h.skill, platform: platform, projectPath: h.project.path)
        }
        return h.platformVM.artifactPath(skill: h.skill, platform: platform, target: .project(h.project))
    }

    private func record(_ h: ProjectFolderCallerHarness, platform: PlatformTarget, path: String, evidence: String) throws {
        switch evidence {
        case "category":
            h.context.insert(SkillProjectAssignment(skillID: h.skill.id, projectID: h.project.id, platform: platform))
        case "intent":
            h.context.insert(IntentAssignment(skillID: h.skill.id, platformRaw: platform.rawValue, projectID: h.project.id))
        case "state": try h.deployState.upsert(DeployStateRecord(slug: h.skill.directoryName, platform: platform.rawValue,
            scope: "project", projectIdentityKey: h.project.identityKey, artifactPath: path, recordedAt: "2026-10-05T00:00:00Z"))
        case "history": h.context.insert(DeployRecord(skillID: h.skill.id, platform: platform,
            targetPath: path, contentHash: "deployed here", projectID: h.project.id))
        default: break
        }
        try h.context.save()
    }

    private func remove(_ h: ProjectFolderCallerHarness, manifest: ManifestSnapshotting? = nil) -> BatchResult {
        removeRegisteredProject(h.project, categoryStore: CategoryStore(), reconciler: h.category,
            manifestService: manifest, manifestRoot: h.root + "/sync",
            platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
            context: h.context)
    }
}
