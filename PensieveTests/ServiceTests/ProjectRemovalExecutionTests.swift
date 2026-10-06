import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectRemovalExecutionTests: XCTestCase {
    func testFolderDisappearingAfterPreparationKeepsDeployStateEvidence() throws {
        let h = try ProjectFolderCallerHarness(installed: [.codex])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        try h.addIntent()
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        let before = try h.deployState.read()
        let reconciler = RemovalCheckpointReconciler {
            do {
                try h.files.replaceItem(at: h.root + "/offline", with: h.project.path)
            } catch { XCTFail("Couldn't stage the missing folder: \(error)") }
            return BatchResult()
        }
        let result = removeRegisteredProject(h.project, categoryStore: CategoryStore(), reconciler: reconciler,
            platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID, context: h.context)
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(try h.deployState.read(), before)
        XCTAssertTrue(h.files.isSymlink(at: h.root + "/offline/agents/" + h.skill.directoryName + ".md"))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 1)
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
        let result = removeRegisteredProject(h.project, categoryStore: CategoryStore(), reconciler: h.category,
            platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID, context: h.context)
        let message = ProjectListView.removalFailureMessage(projectName: h.project.name, result: result)
        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(message.contains("folder"))
        XCTAssertTrue(message.contains(h.project.path))
        XCTAssertFalse(message.contains("deploy records"))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
    }

    func testConfirmationPreparationIsReusedAndStateRetirementIsBatched() throws {
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
            removeRegisteredProject(project, categoryStore: CategoryStore(), reconciler: h.category,
                platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID, preparedPlan: plan, context: h.context)
        }
        XCTAssertNil(model.error)
        XCTAssertEqual(targetReads, 6, "One confirmation classification and one protective leaf check per link")
        XCTAssertEqual(stateWrites, 1, "The three records retire in one durable batch")
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 1)
    }

    func testNoWithdrawalChangesNeedNoManifestWrite() throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        var writes = 0
        h.mapped.beforeFileWrite = { path in
            if path.contains(".manifest-build-") && path.hasSuffix("/manifest.yaml") { writes += 1 }
        }
        let manifest = ManifestService(fileService: h.mapped)
        XCTAssertFalse(removeRegisteredProject(h.project, categoryStore: CategoryStore(manifestService: manifest,
            manifestRoot: h.root + "/sync"), reconciler: h.category, manifestService: manifest,
            manifestRoot: h.root + "/sync", platformVM: h.platformVM,
            localMachineID: ProjectIntentHarness.localID, context: h.context).hasFailures)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 1)
    }
}

private struct RemovalCheckpointReconciler: CategoryReconcilerProtocol {
    let run: () -> BatchResult
    func reconcile(context: ModelContext) -> BatchResult { run() }
    func reconcileRemovingProject(_ projectID: UUID, context: ModelContext) -> BatchResult { run() }
}
