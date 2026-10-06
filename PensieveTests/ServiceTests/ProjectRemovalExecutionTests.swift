import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectRemovalExecutionTests: XCTestCase {
    func testArtifactFailureDetailsPrecedeStateWriteFailureDetails() throws {
        let h = try ProjectFolderCallerHarness(installed: [.claudeCode, .codex])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        try h.addIntent(platform: .claudeCode)
        try h.addIntent(platform: .codex)
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        h.mapped.beforeArtifactDeletion = { path in
            if path == h.artifact(.codex) { throw NSError(domain: NSPOSIXErrorDomain, code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Artifact delete failed"]) }
        }
        h.mapped.beforeDeployStateWrite = { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: 5,
                userInfo: [NSLocalizedDescriptionKey: "State retirement failed"])
        }
        let result = removeRegisteredProject(h.project, reconciler: h.category,
            platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID, context: h.context)
        XCTAssertEqual(result.failureCount, 2)
        let message = ProjectRemovalModel.removalFailureMessage(projectName: h.project.name, result: result)
        let artifact = try XCTUnwrap(message.range(of: "Artifact delete failed"))
        let state = try XCTUnwrap(message.range(of: "State retirement failed"))
        XCTAssertLessThan(artifact.lowerBound, state.lowerBound,
                          "Project removal reports artifact errors before batched state errors")
        XCTAssertFalse(h.files.isSymlink(at: h.artifact(.claudeCode)))
        XCTAssertTrue(h.files.isSymlink(at: h.artifact(.codex)))
        XCTAssertEqual(try h.deployState.read().records.count, 2)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), 2)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
    }

    func testOwnershipReadFailureAfterWithdrawalKeepsArtifactRecordAndRegistration() throws {
        let h = try ProjectFolderCallerHarness(installed: [.cursor])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        try h.addIntent(platform: .cursor)
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        let path = h.platformVM.artifactPath(skill: h.skill, platform: .cursor, target: .project(h.project))
        let bytes = try h.files.readFile(at: path)
        let before = try h.deployState.read()
        let reconciler = RemovalCheckpointReconciler(reconciler: h.category) {
            h.mapped.beforeRuleRead = { candidate in
                if candidate == path { throw NSError(domain: NSPOSIXErrorDomain, code: 5) }
            }
            return BatchResult()
        }
        let result = removeRegisteredProject(h.project, reconciler: reconciler,
            platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID, context: h.context)
        XCTAssertEqual(result.failureCount, 1)
        XCTAssertTrue(result.failures.first?.error?.contains("Could not check ownership") == true)
        XCTAssertTrue(result.failures.first?.error?.contains(path) == true)
        XCTAssertEqual(try h.files.readFile(at: path), bytes)
        XCTAssertEqual(try h.deployState.read(), before)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
    }

    func testFolderDisappearingAfterPreparationKeepsDeployStateEvidence() throws {
        let h = try ProjectFolderCallerHarness(installed: [.codex])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        try h.addIntent()
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        let before = try h.deployState.read()
        let model = ProjectRemovalModel()
        model.request(h.project, platformVM: h.platformVM, context: h.context)
        try h.files.replaceItem(at: h.root + "/offline", with: h.project.path)
        let result = model.confirm { project, plan in
            removeRegisteredProject(project, reconciler: h.category,
                platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
                confirmedPreview: plan, context: h.context)
        }
        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(model.error?.contains("changed") == true)
        XCTAssertEqual(try h.deployState.read(), before)
        XCTAssertTrue(h.files.isSymlink(at: h.root + "/offline/agents/" + h.skill.directoryName + ".md"))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
    }

    func testExecutionFolderCheckFailureNamesFolderAndKeepsRegistration() throws {
        let h = try ProjectFolderCallerHarness(installed: [.codex])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        let model = ProjectRemovalModel()
        model.request(h.project, platformVM: h.platformVM, context: h.context)
        XCTAssertNotNil(model.preview)
        h.mapped.beforeProjectProbe = { path in
            if path == h.project.path { throw NSError(domain: NSPOSIXErrorDomain, code: 13) }
        }
        let result = removeRegisteredProject(h.project, reconciler: h.category,
            platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID, context: h.context)
        let message = ProjectRemovalModel.removalFailureMessage(projectName: h.project.name, result: result)
        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(message.contains("folder"))
        XCTAssertTrue(message.contains(h.project.path))
        XCTAssertFalse(message.contains("deploy records"))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
    }

    func testFolderDisappearingDuringExecutionKeepsEvidenceAndWithdrawalForRetry() throws {
        let h = try ProjectFolderCallerHarness(installed: [.codex])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        try h.addIntent()
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        let before = try h.deployState.read()
        let manifest = ManifestService(fileService: h.mapped)
        let root = h.root + "/sync"
        try manifest.write(try manifest.snapshot(from: h.context), toRoot: root)
        var checkpoint = false
        let reconciler = RemovalCheckpointReconciler(reconciler: h.category) {
            checkpoint = true
            do {
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
                XCTAssertTrue(try manifest.read(fromRoot: root).deployIntents.isEmpty)
                try h.files.replaceItem(at: h.root + "/offline", with: h.project.path)
            } catch { XCTFail(error.localizedDescription) }
            return BatchResult()
        }
        let model = ProjectRemovalModel()
        model.request(h.project, platformVM: h.platformVM, context: h.context)
        let result = model.confirm { project, preview in
            removeRegisteredProject(project, reconciler: reconciler, manifestService: manifest,
                manifestRoot: root, platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
                confirmedPreview: preview, context: h.context)
        }
        XCTAssertTrue(checkpoint)
        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(model.error?.contains("The project folder changed. Please review removal again.") == true)
        XCTAssertEqual(try h.deployState.read(), before)
        XCTAssertTrue(h.files.isSymlink(at: h.root + "/offline/agents/" + h.skill.directoryName + ".md"))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertTrue(try manifest.read(fromRoot: root).deployIntents.isEmpty)
        try h.files.replaceItem(at: h.project.path, with: h.root + "/offline")
        XCTAssertFalse(removeRegisteredProject(h.project, reconciler: h.category, manifestService: manifest,
            manifestRoot: root, platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
            context: h.context).hasFailures)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertFalse(try h.files.entryExistsWithoutFollowingLinks(at: h.artifact(.codex)))
        XCTAssertTrue(try h.deployState.read().records.isEmpty)
    }

    func testConfirmationPreparationIsRefreshedAndStateRetirementIsBatched() throws {
        let h = try ProjectFolderCallerHarness(installed: [.claudeCode, .grok, .codex])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        for platform in [PlatformTarget.claudeCode, .grok, .codex] { try h.addIntent(platform: platform) }
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        var targetReads = 0, stateWrites = 0
        h.mapped.beforeSymlinkRead = { _ in targetReads += 1 }
        h.mapped.beforeDeployStateWrite = { _ in stateWrites += 1 }
        let model = ProjectRemovalModel()
        model.request(h.project, platformVM: h.platformVM, context: h.context)
        model.confirm { project, plan in
            removeRegisteredProject(project, reconciler: h.category,
                platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID, confirmedPreview: plan,
                context: h.context)
        }
        XCTAssertNil(model.error)
        XCTAssertEqual(targetReads, 9, "Confirmation, current execution classification and the protective leaf check")
        XCTAssertEqual(stateWrites, 1, "The three records retire in one durable batch")
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 1)
    }

    func testUnchangedWithdrawalPublishesBeforeUnregistering() throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        var writes = 0
        h.mapped.beforeFileWrite = { path in
            if path.contains(".manifest-build-") && path.hasSuffix("/manifest.yaml") { writes += 1 }
        }
        let manifest = RemovalPublicationCheckpointManifest(base: ManifestService(fileService: h.mapped)) {
            do {
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2,
                               "Publication completes while the registration is still saved")
                XCTAssertFalse(h.context.deletedModelsArray.contains {
                    $0.persistentModelID == h.project.persistentModelID
                }, "Publication completes before registration deletion is even staged")
            } catch { XCTFail(error.localizedDescription) }
        }
        XCTAssertFalse(removeRegisteredProject(h.project, reconciler: h.category, manifestService: manifest,
            manifestRoot: h.root + "/sync", platformVM: h.platformVM,
            localMachineID: ProjectIntentHarness.localID, context: h.context).hasFailures)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 1)
    }
}

struct RemovalCheckpointReconciler: CategoryReconcilerProtocol {
    let reconciler: CategoryReconcilerProtocol?
    let run: () -> BatchResult

    init(reconciler: CategoryReconcilerProtocol? = nil, run: @escaping () -> BatchResult) {
        self.reconciler = reconciler
        self.run = run
    }

    func reconcile(context: ModelContext) -> BatchResult {
        var result = reconciler?.reconcile(context: context) ?? BatchResult()
        result.append(run())
        return result
    }
    func reconcileRemovingProject(_ projectID: UUID, preservingProjects: Set<UUID>, context: ModelContext) -> BatchResult {
        var result = reconciler?.reconcileRemovingProject(projectID, preservingProjects: preservingProjects,
            context: context) ?? BatchResult()
        result.append(run())
        return result
    }
}

struct RemovalPublicationCheckpointManifest: ManifestSnapshotting {
    let base: ManifestService
    let didPublish: () -> Void

    func snapshot(from context: ModelContext) throws -> ManifestSnapshot { try base.snapshot(from: context) }
    func read(fromRoot root: String) throws -> ManifestSnapshot { try base.read(fromRoot: root) }
    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        try base.write(snapshot, toRoot: root)
        didPublish()
    }
}
