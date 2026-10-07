import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalAttemptTests: XCTestCase {
    func testProjectFailureWithdrawsOnlyWaitingEntriesCreatedByThisAttempt() throws {
        for phase in ["publish", "reconcile", "state write"] {
            let h = try WaitingRemovalHarness(platforms: [.claudeCode, .codex])
            defer { h.base.cleanup() }
            try h.deploy([.claudeCode, .codex])
            try h.hideFolder()
            let old = h.entry(platform: .claudeCode, source: "project:\(h.base.project.id)")
            try h.vm.waitingRemovalStore.add([old])
            let manifest = RecordingDeletionManifest()
            if phase == "publish" { manifest.failingWrites = [1] }
            if phase == "state write" {
                h.base.mapped.beforeDeployStateWrite = { _ in throw CocoaError(.fileWriteNoPermission) }
            }
            let reconciler = RemovalCheckpointReconciler {
                var result = BatchResult()
                if phase == "reconcile" { result.operationFailures.append("Reconcile refused") }
                return result
            }
            let result = removeRegisteredProject(h.base.project, reconciler: reconciler,
                manifestService: manifest, manifestRoot: h.base.root + "/store", platformVM: h.vm,
                localMachineID: ProjectIntentHarness.localID, context: h.base.context)
            XCTAssertTrue(result.hasFailures, phase)
            XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Project>()), 2)
            XCTAssertEqual(try h.vm.waitingRemovalStore.read(), [old], "Failed attempts withdraw only their new UUIDs")
            h.base.mapped.beforeDeployStateWrite = nil
            XCTAssertFalse(h.removeProject().hasFailures)
            XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 2, "Retry recreates missing work from retained evidence")
        }
    }

    func testUnavailableFolderWithoutEvidencePromisesNoLaterCleanup() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        let plan = try ProjectRemovalPlan.prepare(project: h.base.project, platformVM: h.vm, context: h.base.context)
        XCTAssertFalse(plan.preview.message.contains("when the folder is back"))
        XCTAssertFalse(h.removeProject().hasFailures)
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
    }

    func testRejectedEntryNamesInputAndKeepsHealthyWaitingFileUnchanged() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        let good = h.entry()
        try h.vm.waitingRemovalStore.add([good])
        let before = try h.base.files.readData(at: h.storePath)
        let bad = WaitingRemoval(source: "rejected source", projectPath: "relative", projectName: "Rejected Project",
            projectIdentityKey: nil, artifactPath: "/rejected-entry", platform: .codex, slug: "bad/slug", legacyFingerprint: nil)
        XCTAssertThrowsError(try h.vm.waitingRemovalStore.add([bad])) { error in
            XCTAssertTrue(error.localizedDescription.contains(bad.artifactPath))
            XCTAssertFalse(error.localizedDescription.contains("couldn't read"), "Invalid input is not an unreadable store")
        }
        XCTAssertEqual(try h.base.files.readData(at: h.storePath), before)
        XCTAssertEqual(try h.vm.waitingRemovalStore.read(), [good])
    }
}
