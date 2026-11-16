import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillDeletionNameReuseRestartTests: XCTestCase, SkillDeletionArrivalAssertions {
    func testDeletingReusingAndQuittingBeforeSaveFinishesTheDeletionOnReopen() async throws {
        try await reuseBeforeQuit(lockedLaunch: false)
    }

    func testReopeningDuringSyncKeepsTheDatedReminderUntilTheDeletionCanSave() async throws {
        try await reuseBeforeQuit(lockedLaunch: true)
    }

    private func reuseBeforeQuit(lockedLaunch: Bool) async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        _ = try seedDeletedSkill(in: h)
        let deletedDate = RefusedCreateRecords.writtenDate(h.alpha.createdAt)
        delete(in: h)
        let expected = try createReplacement(in: h)
        XCTAssertEqual(try deletionSlugs(in: h), ["alpha"])
        h.quit() // Delete, create and quit have no intervening suspension.
        let held = lockedLaunch ? try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath)) : nil
        defer { held?.release() }
        try await h.relaunchThroughRuntime()
        if lockedLaunch {
            let entries = try deletionEntries(in: h)
            XCTAssertEqual(entries.first?["slug"] as? String, "alpha")
            XCTAssertEqual(entries.first?["created_at"] as? String, deletedDate)
        }
        held?.release()
        await TestWait.until(failureMessage: "Deferred launch never completed") { !h.library.launchIngestPending }
        await h.saves.waitUntilIdle()
        let disk = try h.manifest.read(fromRoot: h.root)
        assertRetired(disk)
        XCTAssertFalse(disk.skills.contains {
            $0.slug == "alpha" && RefusedCreateRecords.writtenDate($0.createdAt) == deletedDate
        })
        try assertReplacement(expected, in: h)
        try publishWindow(in: h)
        try assertReplacementPublication(expected, in: h)
    }

    func testCreatingAfterReopenWhileSyncWaitsPublishesTheNewSkillWithoutANameClash() async throws {
        for failedBeforeQuit in [false, true] {
            try await reuseAfterLaunch(failedBeforeQuit: failedBeforeQuit, peerArrives: false)
        }
    }

    func testAPeerArrivingInTheSameWaitProtectsItsRecordAndRefusesLocalCreateAndEdits() async throws {
        try await reuseAfterLaunch(failedBeforeQuit: false, peerArrives: true)
    }

    private func reuseAfterLaunch(failedBeforeQuit: Bool, peerArrives: Bool) async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        let peer = try seedDeletedSkill(in: h)
        let before = try h.manifestBytes()
        h.recording.failingWrites = failedBeforeQuit ? 2 : 0
        delete(in: h)
        if failedBeforeQuit {
            await h.saves.waitUntilIdle()
            XCTAssertEqual(h.saves.refused.count, 2)
        }
        h.quit()
        let helper = DeletionRestartSyncHold()
        defer { helper.release() }
        let paths = AppRuntimePaths(storeRoot: h.root, appSupportDir: h.root + "/support")
        let reconcile = paths.makeLaunchReconcile()
        let root = h.root, files = h.files, manifest = h.manifest, lockPath = h.lockPath
        try await h.relaunchThroughRuntime(launchReconcile: { context, migrated in
            let result = reconcile(context, migrated)
            helper.start(lockPath: lockPath) {
                if peerArrives {
                    try files.writeFile(at: root + "/skills/alpha/SKILL.md",
                        content: SkillSerializer.serialize(name: "Peer Alpha", description: "peer", body: "peer body"))
                    try manifest.write(peer, toRoot: root)
                }
            }
            return result
        })
        await fulfillment(of: [helper.acquired], timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertFalse(h.library.addsFenced)
        XCTAssertNil(SyncLock.tryAcquire(at: h.lockPath))
        XCTAssertEqual(try h.manifestBytes(), before, "Startup must finish before the replay saves")
        let expected = try createReplacement(in: h)
        helper.release()
        await fulfillment(of: [helper.finished], timeout: TestWait.hostedActionTimeoutSeconds)
        await h.saves.waitUntilIdle()
        if peerArrives {
            try await assertLocalCollision(expected, peer: peer, in: h)
        } else {
            try assertReplacement(expected, in: h)
            try assertReplacementPublication(expected, in: h)
            try publishWindow(in: h)
            try assertReplacementPublication(expected, in: h)
        }
    }

    private func assertLocalCollision(_ expected: SkillOverlay, peer: ManifestSnapshot, in h: ManifestSaveFixture) async throws {
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), peer)
        XCTAssertTrue(h.saves.hasCollision("alpha", context: h.context))
        XCTAssertEqual(h.library.error, ManifestSaveError.createCollision("alpha").localizedDescription)
        try assertShown(expected, in: h)
        let row = try XCTUnwrap(h.context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "alpha" })
        h.library.updateMetadata(row, tags: ["edited"], scope: .project, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.library.error, ManifestSaveError.createCollision("alpha").localizedDescription)
        XCTAssertEqual(row.tags, ["edited"])
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), peer)
        try publishWindow(in: h)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), peer)
        XCTAssertEqual(try deletionSlugs(in: h), [])
    }

    func testAPeersSameNamedSkillArrivingWhileClosedKeepsAllItsValues() async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        let peer = try seedDeletedSkill(in: h)
        delete(in: h)
        h.quit()
        try deliver(peer, in: h)
        try await h.relaunchThroughRuntime()
        await h.saves.waitUntilIdle()
        try assertPeer(peer, in: h)
        XCTAssertEqual(try deletionSlugs(in: h), [])
    }

    func testFailedCategoryAndRequestCleanupSurvivesReuseAndQuitIndependentlyOfTheDeletion() async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        _ = try seedDeletedSkill(in: h)
        h.recording.failingWrites = 1
        delete(in: h)
        let expected = try createReplacement(in: h)
        await h.saves.waitUntilIdle()
        let record = try recordJSON(in: h)
        XCTAssertEqual((record["retirements"] as? [[String: Any]])?.first?["slug"] as? String, "alpha")
        XCTAssertEqual(try deletionEntries(in: h).first?["created_at"] as? String, "2023-11-14T22:13:20.000Z")
        h.quit()
        try await h.relaunchThroughRuntime()
        await h.saves.waitUntilIdle()
        try assertShown(expected, in: h)
        assertRetired(try h.manifest.snapshot(from: h.context))
        try publishWindow(in: h)
        try assertReplacementPublication(expected, in: h)
        // The next save observes the whole-window publication and acknowledges the retirement.
        h.library.regenerateManifest(.skillMetadata("beta", nil, nil), context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try deletionSlugs(in: h), [])
    }

    private func seedDeletedSkill(in h: ManifestSaveFixture) throws -> ManifestSnapshot {
        h.alpha.tags = ["old"]
        h.alpha.scope = .project
        return try seedRetirement(in: h)
    }

    private func createReplacement(in h: ManifestSaveFixture) throws -> SkillOverlay {
        let row = try XCTUnwrap(h.library.createSkill(name: "Alpha", description: "replacement",
            body: "new body", tags: ["new"], context: h.context))
        XCTAssertEqual(row.directoryName, "alpha")
        return try XCTUnwrap(h.manifest.snapshot(from: h.context).skills.first { $0.slug == "alpha" })
    }

    private func assertShown(_ expected: SkillOverlay, in h: ManifestSaveFixture) throws {
        let shown = try XCTUnwrap(h.manifest.snapshot(from: h.context).skills.first { $0.slug == "alpha" })
        XCTAssertEqual(shown.tags, expected.tags)
        XCTAssertEqual(shown.scope, expected.scope)
        XCTAssertEqual(RefusedCreateRecords.writtenDate(shown.createdAt), RefusedCreateRecords.writtenDate(expected.createdAt))
    }

    private func assertReplacement(_ expected: SkillOverlay, in h: ManifestSaveFixture) throws {
        try assertShown(expected, in: h)
        assertRetired(try h.manifest.snapshot(from: h.context))
        XCTAssertTrue(h.saves.refused.isEmpty)
        XCTAssertNil(h.library.error)
        XCTAssertEqual(try deletionSlugs(in: h), [])
    }

    private func assertReplacementPublication(_ expected: SkillOverlay, in h: ManifestSaveFixture) throws {
        let disk = try h.manifest.read(fromRoot: h.root)
        assertRetired(disk)
        let saved = try XCTUnwrap(disk.skills.first { $0.slug == "alpha" })
        XCTAssertEqual(saved.tags, expected.tags)
        XCTAssertEqual(saved.scope, expected.scope)
        XCTAssertEqual(RefusedCreateRecords.writtenDate(saved.createdAt), RefusedCreateRecords.writtenDate(expected.createdAt))
    }

    private func recordJSON(in h: ManifestSaveFixture) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: h.files.readData(at: h.recordPath)) as? [String: Any])
    }

    private func deletionEntries(in h: ManifestSaveFixture) throws -> [[String: Any]] {
        try XCTUnwrap(recordJSON(in: h)["deletions"] as? [[String: Any]])
    }
}
