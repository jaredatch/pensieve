import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalConvergenceTests: XCTestCase {
    func testLaunchAndSyncRunOnlyOneWaitingPassAndUserReconciliationStillRuns() throws {
        for trigger in ["launch", "sync", "user"] {
            let h = try WaitingRemovalHarness()
            defer { h.base.cleanup() }
            try h.deploy([.codex])
            try h.hideFolder()
            XCTAssertTrue(h.deleteSkill())
            try h.restoreFolder()
            let newer = h.entry(source: "newer during pass")
            h.base.mapped.beforeArtifactDeletion = { path in
                if path == newer.artifactPath { try h.vm.waitingRemovalStore.add([newer]) }
            }
            if trigger == "user" { _ = h.base.intent.reconcile(context: h.base.context) } else {
                let convergence = h.base.convergence { _, _ in }
                if trigger == "launch" { convergence.runAfterLaunchIngest() } else {
                    convergence.run(after: .synced(pushed: false, warnings: [], completedAt: Date(), headAdvanced: true))
                }
            }
            XCTAssertFalse(h.base.files.isSymlink(at: newer.artifactPath))
            XCTAssertEqual(try h.vm.waitingRemovalStore.read(), [newer], trigger)
        }
    }

    func testFolderLostAfterAdmissionKeepsAllEntriesQuietlyUntilRestored() throws {
        for loss in ["missing", "uncheckable"] {
            let h = try WaitingRemovalHarness(platforms: [.claudeCode, .codex])
            defer { h.base.cleanup() }
            try h.deploy([.claudeCode, .codex])
            try h.hideFolder()
            XCTAssertTrue(h.deleteSkill())
            try h.restoreFolder()
            let waiting = try h.vm.waitingRemovalStore.read()
            var probes: [String] = []
            var judged = 0
            var lost = false
            h.mapped.beforeProjectProbe = { path in
                probes.append(path)
                if loss == "uncheckable", lost { throw CocoaError(.fileReadNoPermission) }
            }
            h.mapped.beforePathResolution = { _ in
                if !lost { try h.hideFolder(); lost = true }
            }
            h.mapped.beforeEntryTypeProbe = { path in
                if waiting.contains(where: { $0.artifactPath == path }) {
                    judged += 1
                    if loss == "uncheckable" { throw CocoaError(.fileReadNoPermission) }
                }
            }
            XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures, loss)
            XCTAssertEqual(try h.vm.waitingRemovalStore.read(), waiting, loss)
            XCTAssertEqual(judged, 2)
            XCTAssertEqual(probes, [h.base.project.path, h.base.project.path], loss)
            h.mapped.beforePathResolution = nil
            h.mapped.beforeEntryTypeProbe = nil
            h.mapped.beforeProjectProbe = nil
            try h.restoreFolder()
            XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
            for entry in waiting { XCTAssertFalse(try h.base.files.entryExistsWithoutFollowingLinks(at: entry.artifactPath)) }
            XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
        }
    }

    func testNoReachableEntrySkipsDesiredReadsAndResolution() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        try h.deploy([.codex])
        try h.hideFolder()
        XCTAssertTrue(h.deleteSkill())
        let before = try h.base.files.readData(at: h.storePath)
        h.mapped.beforePathResolution = { _ in XCTFail("No reachable work must resolve no paths") }
        let reconciler = WaitingRemovalReconciler(store: h.vm.waitingRemovalStore, fileService: h.mapped,
            platformVM: h.vm, machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
            stateFetcher: WaitingDesiredReadFault(failing: "categories"))
        XCTAssertFalse(reconciler.reconcile(context: h.base.context).hasFailures)
        XCTAssertEqual(try h.base.files.readData(at: h.storePath), before)
    }

    func testUnavailableDesiredProjectKeepsUnresolvedPathsWithoutPausingReadyWork() throws {
        for unavailable in ["missing", "uncheckable"] {
            let h = try WaitingRemovalHarness()
            defer { h.base.cleanup() }
            try h.deploy([.codex])
            try h.hideFolder()
            XCTAssertFalse(h.removeProject().hasFailures)
            try h.restoreFolder()
            try h.base.addIntent(platform: .codex, project: h.base.otherProject)
            if unavailable == "missing" { try h.base.files.deleteDirectory(at: h.base.otherProject.path) } else {
                h.mapped.beforeProjectProbe = { path in
                    if path == h.base.otherProject.path { throw CocoaError(.fileReadNoPermission) }
                }
            }
            h.mapped.beforePathResolution = { path in
                XCTAssertFalse(path.hasPrefix(h.base.otherProject.path), "Unavailable desired paths must stay unresolved")
            }
            let result = h.vm.reconcileWaitingRemovals(context: h.base.context)
            XCTAssertFalse(result.hasFailures, unavailable)
            XCTAssertFalse(h.base.files.isSymlink(at: h.base.artifact(.codex)), unavailable)
            XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
        }
    }
}
