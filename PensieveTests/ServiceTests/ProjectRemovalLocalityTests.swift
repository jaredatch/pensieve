import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectRemovalLocalityTests: XCTestCase {
    func testPublishedRemovalKeepsAnotherMacCategoryDeploys() throws {
        let sender = try ProjectFolderCallerHarness()
        defer { sender.cleanup() }
        let receiver = try ProjectFolderCallerHarness()
        defer { receiver.cleanup() }
        for h in [sender, receiver] {
            try h.files.createDirectory(at: h.project.path)
            _ = try h.addCategory()
            XCTAssertFalse(h.category.reconcile(context: h.context).hasFailures)
            h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.remoteID,
                skillSlug: h.skill.directoryName, platformRaw: "cursor", projectKey: h.otherProject.identityKey))
            try h.context.save()
        }
        try sender.addIntent()
        XCTAssertFalse(sender.intent.reconcile(context: sender.context).hasFailures)
        let remoteIntent = IntentReconciler(platformVM: receiver.platformVM,
            machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.remoteID))
        XCTAssertFalse(remoteIntent.reconcile(context: receiver.context).hasFailures)
        let state = try receiver.deployState.read()
        let ledgerIDs = Set(try receiver.context.fetch(FetchDescriptor<SkillProjectAssignment>()).map(\.id))
        let intentKeys = try receiver.context.fetch(FetchDescriptor<IntentAssignment>()).map(\.key)
        let rulePath = receiver.platformVM.artifactPath(skill: receiver.skill, platform: .cursor,
            target: .project(receiver.project))
        let ruleBytes = try receiver.files.readFile(at: rulePath)
        let manifest = ManifestService(fileService: sender.files)
        XCTAssertFalse(remove(sender, manifest: manifest, root: sender.root + "/store").hasFailures)

        // Copy the published bytes as sync would, then use the real ingestion and ledger pass.
        try FileManager.default.copyItem(atPath: sender.root + "/store/manifest",
            toPath: receiver.root + "/store/manifest")
        let rebuilt = StoreRebuildService(fileService: receiver.files,
            manifestService: ManifestService(fileService: receiver.files))
            .rebuild(fromRoot: receiver.root + "/store", context: receiver.context)
        XCTAssertFalse(rebuilt.storeUnreadable)
        XCTAssertFalse(rebuilt.saveFailed)
        XCTAssertTrue(rebuilt.warnings.isEmpty)
        let convergence = PostSyncConvergence(root: receiver.root + "/store",
            deployReconciler: ConvergenceRecordingDeploy(recorder: ConvergenceRecorder()),
            contextFactory: { receiver.context }, categoryReconciler: receiver.category,
            intentReconciler: remoteIntent, auditLog: { _, _ in })
        convergence.run(after: .synced(pushed: false, warnings: [], completedAt: Date(), headAdvanced: true))
        XCTAssertEqual(try receiver.context.fetch(FetchDescriptor<Pensieve.Category>()).first?.projectKeys,
                       ["github.com/owner/project"])
        XCTAssertEqual(try receiver.deployState.read(), state)
        XCTAssertEqual(Set(try receiver.context.fetch(FetchDescriptor<SkillProjectAssignment>()).map(\.id)), ledgerIDs)
        XCTAssertEqual(try receiver.context.fetch(FetchDescriptor<IntentAssignment>()).map(\.key), intentKeys)
        XCTAssertEqual(try receiver.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.machineID),
                       [ProjectIntentHarness.remoteID])
        for platform in [PlatformTarget.claudeCode, .grok, .codex] {
            XCTAssertTrue(receiver.files.isSymlink(at: receiver.artifact(platform)))
        }
        XCTAssertEqual(try receiver.files.readFile(at: rulePath), ruleBytes)
        XCTAssertTrue(try receiver.context.fetch(FetchDescriptor<Project>()).contains { $0.id == receiver.project.id })
    }

    func testReregisteredIdentityGetsCategoryDeploysAtNextConvergence() throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        let category = try h.addCategory()
        XCTAssertFalse(h.category.reconcile(context: h.context).hasFailures)
        let path = h.project.path
        let manifest = ManifestService(fileService: h.files)
        XCTAssertFalse(remove(h, manifest: manifest).hasFailures)
        h.convergence(audit: { _, _ in }).runAfterLaunchIngest()
        XCTAssertTrue(try h.deployState.read().records.isEmpty, "An unregistered key deploys nowhere")
        let replacement = Project(name: "Added again", path: path)
        replacement.identityKey = "github.com/owner/project"
        registerProject(replacement, manifestService: manifest, manifestRoot: h.root + "/sync",
            context: h.context, intentReconciler: { h.intent.reconcile(context: $0) })
        XCTAssertTrue(try h.deployState.read().records.isEmpty, "Registration alone does not run category fan-out")
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
        h.convergence(audit: { _, _ in }).runAfterLaunchIngest()
        for platform in [PlatformTarget.claudeCode, .grok, .codex, .cursor] {
            XCTAssertTrue(try h.platformVM.artifactIsOwned(skill: h.skill, platform: platform, target: .project(replacement)))
        }
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<SkillProjectAssignment>()).map(\.projectID),
                       Array(repeating: replacement.id, count: 4))
        XCTAssertEqual(try h.deployState.read().records.count, 4)
        XCTAssertEqual(category.projectKeys, ["github.com/owner/project"])
        XCTAssertEqual(try manifest.read(fromRoot: h.root + "/sync").categories.first?.projectKeys,
                       ["github.com/owner/project"])
    }

    func testPartialRemovalConvergesCategoryAndRetryRemovesBothSources() throws {
        let h = try ProjectFolderCallerHarness(installed: [.claudeCode, .cursor])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        let category = try h.addCategory()
        let direct = try h.addDirectSkill(platforms: [.cursor])
        h.convergence(audit: { _, _ in }).runAfterLaunchIngest()
        let failedPath = h.platformVM.artifactPath(skill: direct, platform: .cursor, target: .project(h.project))
        h.mapped.beforeArtifactDeletion = { path in
            if path == failedPath { throw NSError(domain: NSPOSIXErrorDomain, code: 13) }
        }
        let manifest = ManifestService(fileService: h.files)
        let partial = remove(h, manifest: manifest)
        XCTAssertEqual(partial.failureCount, 1)
        XCTAssertTrue(partial.didRemoveArtifacts)
        XCTAssertFalse(h.files.isSymlink(at: h.artifact(.claudeCode)))
        XCTAssertTrue(try h.files.entryExistsWithoutFollowingLinks(at: failedPath))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertTrue(try manifest.read(fromRoot: h.root + "/sync").deployIntents.isEmpty)
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<Project>()).contains { $0.id == h.project.id })
        XCTAssertTrue(ProjectRemovalModel.removalFailureMessage(projectName: h.project.name, result: partial)
            .contains("stays registered"))
        h.convergence(audit: { _, _ in }).runAfterLaunchIngest()
        XCTAssertTrue(h.files.isSymlink(at: h.artifact(.claudeCode)), "A still-registered category member deploys again")
        XCTAssertTrue(try h.files.entryExistsWithoutFollowingLinks(at: failedPath))
        h.mapped.beforeArtifactDeletion = nil
        XCTAssertFalse(remove(h, manifest: manifest).hasFailures)
        XCTAssertFalse(try h.files.entryExistsWithoutFollowingLinks(at: failedPath))
        for platform in [PlatformTarget.claudeCode, .cursor] {
            XCTAssertFalse(try h.files.entryExistsWithoutFollowingLinks(at: h.platformVM.artifactPath(
                skill: h.skill, platform: platform, target: .project(h.project))))
        }
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<Project>()).map(\.id), [h.otherProject.id])
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
        XCTAssertTrue(try h.deployState.read().records.isEmpty)
        XCTAssertEqual(category.projectKeys, ["github.com/owner/project"])
    }

    private func remove(_ h: ProjectFolderCallerHarness, manifest: ManifestSnapshotting? = nil,
                        root: String? = nil) -> BatchResult {
        removeRegisteredProject(h.project, reconciler: h.category, manifestService: manifest,
            manifestRoot: root ?? h.root + "/sync", platformVM: h.platformVM,
            localMachineID: ProjectIntentHarness.localID, context: h.context)
    }
}
