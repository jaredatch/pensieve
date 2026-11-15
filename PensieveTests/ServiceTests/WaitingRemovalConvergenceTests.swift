import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalConvergenceTests: XCTestCase {
    func testLaunchAndSyncRunOnlyOneWaitingPassAndUserReconciliationStillRuns() throws {
        for trigger in ["launch", "sync", "user"] {
            let h = try WaitingRemovalHarness()
            defer { h.tearDown(after: self) }
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
            defer { h.tearDown(after: self) }
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
        defer { h.tearDown(after: self) }
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
            defer { h.tearDown(after: self) }
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

@MainActor
final class WaitingRemovalHarnessTests: XCTestCase {
    func testDeletedSkillSaveFinishesBeforeSandboxRemoval() async throws {
        let h = try WaitingRemovalHarness()
        defer { h.tearDown(after: self) }
        let saves = try XCTUnwrap(h.library.manifestSaves)
        XCTAssertTrue(h.deleteSkill())
        var resolutions = 0
        // The deletion's synchronous file work is over; only its queued save can trip this.
        h.mapped.beforePathResolution = { _ in resolutions += 1 }
        XCTAssertGreaterThan(saves.pendingCount, 0)
        let finished = await h.tearDown(testName: name)
        XCTAssertTrue(finished)
        XCTAssertEqual(saves.pendingCount, 0)
        XCTAssertEqual(resolutions, 0)
        XCTAssertFalse(h.base.files.directoryExists(at: h.base.root))
        h.mapped.beforePathResolution = nil
        await saves.waitUntilIdle()
    }

    func testTeardownClearsEveryHookOnBothDoubles() throws {
        let h = try WaitingRemovalHarness()
        do {
            defer { h.tearDown(after: self) }
            armAllHooks(h)
        }
        // Hooks must already be down before the async teardown block can get a turn.
        assertHooksCleared(h)
    }

    func testTeardownWaitsForQueueCreatedByTest() async throws {
        let h = try WaitingRemovalHarness()
        defer { h.tearDown(after: self) }
        let saves = ManifestSaveModel(manifest: ManifestService(fileService: h.base.files),
            root: h.base.root + "/store", lockPath: h.base.root + "/store.sync.lock", files: h.mapped)
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: h.mapped, baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot),
            fileService: h.mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestRoot: h.base.root + "/store", notifier: {}, manifestSaves: saves)
        h.trackSaveQueue(saves, named: "second library")
        XCTAssertTrue(SkillDeletionFlow.delete(skill: h.base.skill, library: library, platformVM: h.vm,
            projects: [h.base.project, h.base.otherProject], context: h.base.context))
        XCTAssertEqual(h.library.manifestSaves?.pendingCount, 0)
        XCTAssertGreaterThan(saves.pendingCount, 0)
        let finished = await h.tearDown(testName: name)
        XCTAssertTrue(finished)
        XCTAssertEqual(saves.pendingCount, 0)
        XCTAssertFalse(h.base.files.directoryExists(at: h.base.root))
        await saves.waitUntilIdle()
    }

    func testUnfinishedSaveFailsItsOwnerAndPreservesSandboxWithHooksDown() async throws {
        let h = try WaitingRemovalHarness()
        defer { h.tearDown(after: self) }
        let saves = try XCTUnwrap(h.library.manifestSaves)
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: saves.lockPath))
        defer { held.release() }
        XCTAssertTrue(h.deleteSkill())
        armAllHooks(h)
        XCTAssertGreaterThan(saves.pendingCount, 0)
        let ownerName = name
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        options.issueMatcher = {
            $0.compactDescription.contains("Unfinished manifest save: library.manifestSaves")
                && $0.compactDescription.contains(ownerName)
        }
        XCTExpectFailure("A blocked save must fail the test that owns it", options: options)
        let finished = await h.tearDown(testName: ownerName, timeout: .milliseconds(50)) // upper-bound: Deliberately held lock.
        XCTAssertFalse(finished)
        XCTAssertGreaterThan(saves.pendingCount, 0)
        assertHooksCleared(h)
        XCTAssertTrue(h.base.files.directoryExists(at: h.base.root))
        held.release()
        // The deliberately blocked worker must finish too, even if the assertions above fail.
        await saves.waitUntilIdle()
        XCTAssertEqual(saves.pendingCount, 0)
    }

    private let hookPaths: [ReferenceWritableKeyPath<LinkServiceCanonicalDirectoryFileService,
        ((String) throws -> Void)?>] = [
        \.beforeDirectoryCreation, \.beforeArtifactCreation, \.beforeArtifactDeletion, \.beforeProjectProbe,
        \.beforeRuleRead, \.beforeEntryTypeProbe, \.beforeDeployStateRead, \.beforeDeployStateWrite,
        \.beforeFileWrite, \.beforeSymlinkRead, \.beforePathResolution
    ]

    private func armAllHooks(_ h: WaitingRemovalHarness) {
        for double in [h.mapped, h.base.mapped] {
            for path in hookPaths { double[keyPath: path] = { _ in XCTFail("A teardown hook outlived its test") } }
        }
    }

    private func assertHooksCleared(_ h: WaitingRemovalHarness, file: StaticString = #filePath, line: UInt = #line) {
        for double in [h.mapped, h.base.mapped] {
            for path in hookPaths { XCTAssertNil(double[keyPath: path], "\(path)", file: file, line: line) }
        }
    }
}
