import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectRemovalReviewTests: XCTestCase {
    func testForeignAtConfirmationOwnedAtExecutionSurvives() throws {
        let h = try ProjectFolderCallerHarness(installed: [.claudeCode])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        try h.addIntent(platform: .claudeCode)
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        let path = h.artifact(.claudeCode)
        try h.files.deleteFile(at: path)
        try h.files.createSymlink(at: path, pointingTo: h.otherProject.path)
        let confirmed = try ProjectRemovalPlan.prepare(project: h.project, platformVM: h.platformVM, context: h.context)
        XCTAssertEqual(confirmed.preview.artifactCount, 0)
        let checkpoint = RemovalCheckpointReconciler(reconciler: h.category) {
            do {
                try h.files.deleteFile(at: path)
                try LinkService(fileService: h.mapped).link(skill: h.skill, platform: .claudeCode, projectPath: h.project.path)
                return BatchResult()
            } catch { return BatchResult.readFailure("checkpoint", error: error) }
        }
        let result = removeRegisteredProject(h.project, reconciler: checkpoint,
            platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
            confirmedPreview: confirmed.preview, context: h.context)
        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(h.files.isSymlink(at: path), "An artifact outside the confirmed owned set survives")
        XCTAssertTrue(try h.deployState.read().records.isEmpty)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<Project>()).map(\.id), [h.otherProject.id])
        XCTAssertFalse(result.didRemoveArtifacts)
    }
}
