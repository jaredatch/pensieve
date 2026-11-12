import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillDeletionPeerArrivalTests: XCTestCase {
    func testDeletingThenCreatingTheSameNameWhileSyncWaitsPublishesTheNewSkillWithoutOldAssignments() async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        _ = try seedRetirement(in: h)
        let before = try h.manifestBytes()
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        delete(in: h)
        let replacement = try XCTUnwrap(h.library.createSkill(name: "Alpha", description: "replacement",
            body: "new body", tags: ["new"], context: h.context))
        XCTAssertEqual(replacement.directoryName, "alpha")
        let expected = try XCTUnwrap(h.manifest.snapshot(from: h.context).skills.first { $0.slug == "alpha" })
        await h.assertWaitingBehindHeldLock(pending: 3, before: before)
        XCTAssertEqual(try deletionSlugs(in: h), ["alpha"])
        held.release()
        await h.saves.waitUntilIdle()
        let durable = try h.manifest.read(fromRoot: h.root)
        assertRetired(durable)
        let saved = try XCTUnwrap(durable.skills.first { $0.slug == "alpha" })
        let shown = try XCTUnwrap(h.manifest.snapshot(from: h.context).skills.first { $0.slug == "alpha" })
        for current in [saved, shown] {
            XCTAssertEqual(current.tags, ["new"])
            XCTAssertEqual(current.scope, .user)
            XCTAssertEqual(RefusedCreateRecords.writtenDate(current.createdAt),
                           RefusedCreateRecords.writtenDate(expected.createdAt))
        }
        XCTAssertTrue(h.saves.refused.isEmpty)
        XCTAssertNil(h.library.error)
        XCTAssertEqual(try deletionSlugs(in: h), [])
        try publishWindow(in: h)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), durable)
    }

    func testDeletingWhileSyncWaitsKeepsTheArrivingPeersSkillAndClearsItsReminder() async throws {
        try await assertArrivalWhileWaiting(failRowSave: false)
    }

    func testDeletingThenRenamingAnotherSkillIntoItsNamePublishesTheRenameWithoutOldAssignments() async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        h.beta.tags = ["renamed"]
        h.beta.createdAt = Date(timeIntervalSince1970: 1_600_000_000)
        _ = try seedRetirement(in: h)
        var expected = try XCTUnwrap(h.manifest.snapshot(from: h.context).skills.first { $0.slug == "beta" })
        expected.slug = "alpha"
        delete(in: h)
        // Both actions finish in one main-actor turn, before the save worker takes sync.lock.
        XCTAssertTrue(SkillRenameFlow.rename(skill: h.beta, to: "Alpha", library: h.library, platformVM: h.platform,
                                             projects: [], context: h.context))
        XCTAssertEqual(h.saves.pendingCount, 3)
        await h.saves.waitUntilIdle()
        let durable = try h.manifest.read(fromRoot: h.root)
        assertRetired(durable)
        XCTAssertEqual(durable.skills, [expected])
        XCTAssertEqual(try h.manifest.snapshot(from: h.context).skills, [expected])
        XCTAssertTrue(h.saves.refused.isEmpty)
        XCTAssertNil(h.library.error)
        XCTAssertEqual(try deletionSlugs(in: h), [])
        try publishWindow(in: h)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), durable)
    }

    func testDeletingThenCreatingTheSameNameDoesNotEraseAPeerArrivingWhileSyncWaits() async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        let peer = try seedRetirement(in: h)
        let before = try h.manifestBytes()
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        delete(in: h)
        let replacement = try XCTUnwrap(h.library.createSkill(name: "Alpha", description: "replacement",
            body: "new body", tags: ["new"], context: h.context))
        XCTAssertEqual(replacement.directoryName, "alpha")
        await h.assertWaitingBehindHeldLock(pending: 3, before: before)
        try deliver(peer, in: h)
        held.release()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), peer)
        XCTAssertEqual(h.saves.refused.count, 1, "The local replacement meets the peer as a name clash")
        XCTAssertEqual(h.library.error, ManifestSaveError.createCollision("alpha").localizedDescription)
        XCTAssertEqual(try deletionSlugs(in: h), [])
        try publishWindow(in: h)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), peer)
    }

    func testDeletingWithAFailedRowSaveLetsTheArrivingPeersSkillOpenNormally() async throws {
        try await assertArrivalWhileWaiting(failRowSave: true)
    }

    private func assertArrivalWhileWaiting(failRowSave: Bool) async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        let peer = try seedRetirement(in: h)
        let before = try h.manifestBytes()
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        let retainedID = h.alpha.id
        delete(in: h, failRowSave: failRowSave)
        XCTAssertFalse(h.files.directoryExists(at: h.root + "/skills/alpha"))
        await h.assertWaitingBehindHeldLock(pending: failRowSave ? 1 : 2, before: before)
        XCTAssertEqual(try deletionSlugs(in: h), ["alpha"], "The reminder must exist before cancellation")
        if failRowSave { XCTAssertTrue(h.library.pendingRowCleanup.contains(retainedID)) }
        try deliver(peer, in: h)
        held.release()
        await h.saves.waitUntilIdle()
        try assertPeer(peer, in: h)
        XCTAssertEqual(try deletionSlugs(in: h), [])
        if failRowSave {
            let row = try XCTUnwrap(h.context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "alpha" })
            XCTAssertEqual(row.id, retainedID, "The retained row is refreshed, not replaced")
            XCTAssertFalse(h.library.pendingRowCleanup.contains(row.id))
            XCTAssertFalse(h.library.isWriteFenced(row), "The returned skill must open normally")
        } else {
            XCTAssertNil(h.library.error)
            XCTAssertNil(h.library.deletionNotice)
        }
        XCTAssertTrue(h.messages.lines.isEmpty)
    }

    func testDeletingWithAPeerArrivingBetweenSavesKeepsThePeersOverlay() async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        let peer = try seedRetirement(in: h)
        let before = try h.manifestBytes()
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        let helperFinished = expectation(description: "The helper delivers under its own lock hold")
        let root = h.root, lockPath = h.lockPath, files = h.files, manifest = h.manifest, recording = h.recording
        let waiterStarted = DispatchSemaphore(value: 0)
        recording.afterWrite = { [weak recording] in
            guard let recording, recording.writes.count == 1 else { return }
            // This hook only starts a waiter. Arrival happens after the save releases sync.lock.
            Thread.detachNewThread {
                waiterStarted.signal()
                do {
                    let lock = try SyncLock.waitForSave(at: lockPath)
                    defer { lock.release() }
                    let retired = try manifest.read(fromRoot: root)
                    XCTAssertEqual(recording.writes.count, 1, "The helper must precede the second save")
                    XCTAssertFalse(retired.categories.contains { $0.skillSlugs.contains("alpha") })
                    XCTAssertFalse(retired.deployIntents.contains { $0.skillSlug == "alpha" })
                    XCTAssertTrue(retired.skills.contains { $0.slug == "alpha" }, "Only retirement has saved")
                    try files.writeFile(at: root + "/skills/alpha/SKILL.md",
                        content: SkillSerializer.serialize(name: "Peer Alpha", description: "peer", body: "peer body"))
                    try manifest.write(peer, toRoot: root)
                } catch { XCTFail("Helper delivery failed: \(error)") }
                helperFinished.fulfill()
            }
            XCTAssertEqual(waiterStarted.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds), .success)
            // Let the native thread enter blocking flock before this save releases it. The
            // assertions under the helper's lock prove the actual order rather than assuming it.
            Thread.sleep(forTimeInterval: 0.05)
            XCTAssertNil(SyncLock.tryAcquire(at: lockPath), "The hook still runs under the save's lock")
        }
        delete(in: h)
        await h.assertWaitingBehindHeldLock(pending: 2, before: before)
        XCTAssertEqual(try deletionSlugs(in: h), ["alpha"])
        held.release()
        await h.saves.waitUntilIdle()
        await fulfillment(of: [helperFinished], timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertEqual(recording.writes.count, 1, "The overlay deletion must be cancelled")
        try assertPeer(peer, in: h)
        XCTAssertEqual(try deletionSlugs(in: h), [])
        XCTAssertNil(h.library.error)
    }

    func testDeletingWhenFilesCannotBeRemovedKeepsTheSkillAndPublishesRetirement() async throws {
        let h = try ManifestSaveFixture(failAlphaDeletion: true)
        defer { h.cleanup() }
        _ = try seedRetirement(in: h)
        XCTAssertFalse(SkillDeletionFlow.delete(skill: h.alpha, library: h.library, platformVM: h.platform,
                                               projects: [], context: h.context))
        await h.saves.waitUntilIdle()
        XCTAssertTrue(h.files.directoryExists(at: h.root + "/skills/alpha"))
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<Skill>()).contains { $0.directoryName == "alpha" })
        let durable = try h.manifest.read(fromRoot: h.root)
        XCTAssertTrue(durable.skills.contains { $0.slug == "alpha" })
        assertRetired(durable)
    }

    func testDeletingOurNameClashWithThePeersFolderPresentFinishesAndKeepsThePeer() async throws {
        let h = try CollisionCreateFixture()
        defer { h.cleanup() }
        await h.saves.waitUntilIdle()
        try h.addOwnIntent()
        var before = try h.f.manifest.read(fromRoot: h.f.app)
        before.deployIntents.append(DeployIntentRecord(machineID: ProjectIntentHarness.localID, skillSlug: "item",
            platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil))
        try h.f.manifest.write(before, toRoot: h.f.app)
        try h.f.files.writeFile(at: h.f.app + "/skills/item/SKILL.md",
            content: SkillSerializer.serialize(name: "Peer Item", description: "peer", body: "peer body"))
        XCTAssertTrue(SkillDeletionFlow.delete(skill: h.skill, library: h.library, platformVM: h.platform,
                                              projects: [], context: h.context))
        // The peer's folder can be present again before either queued save takes its lock.
        try h.f.files.writeFile(at: h.f.app + "/skills/item/SKILL.md",
            content: SkillSerializer.serialize(name: "Peer Item", description: "peer", body: "peer body"))
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.ownIntents(), [])
        XCTAssertFalse(try h.f.manifest.read(fromRoot: h.f.app).deployIntents.contains {
            $0.machineID == ProjectIntentHarness.localID && $0.skillSlug == "item"
        })
        XCTAssertTrue(h.saves.refused.isEmpty)
        try h.assertPeer()
    }

    func testDeletingWithoutAPeerArrivalPublishesCleanupAndClearsTheReminder() async throws {
        for failRowSave in [false, true] {
            let h = try ManifestSaveFixture(persistent: true)
            defer { h.cleanup() }
            _ = try seedRetirement(in: h)
            let before = try h.manifestBytes()
            let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { held.release() }
            let retainedID = h.alpha.id
            delete(in: h, failRowSave: failRowSave)
            await h.assertWaitingBehindHeldLock(pending: failRowSave ? 1 : 2, before: before)
            XCTAssertEqual(try deletionSlugs(in: h), ["alpha"])
            held.release()
            await h.saves.waitUntilIdle()
            XCTAssertFalse(h.files.directoryExists(at: h.root + "/skills/alpha"))
            let durable = try h.manifest.read(fromRoot: h.root)
            assertRetired(durable)
            XCTAssertEqual(durable.skills.contains { $0.slug == "alpha" }, failRowSave)
            XCTAssertEqual(h.library.pendingRowCleanup.contains(retainedID), failRowSave)
            if !failRowSave {
                try publishWindow(in: h)
                let published = try h.manifest.read(fromRoot: h.root)
                assertRetired(published)
                XCTAssertFalse(published.skills.contains { $0.slug == "alpha" })
            }
            XCTAssertEqual(try deletionSlugs(in: h), [])
        }
    }

}

extension SkillDeletionPeerArrivalTests {
    private func seedRetirement(in h: ManifestSaveFixture) throws -> ManifestSnapshot {
        h.local.skillSlugs = ["alpha"]
        for machine in [ProjectIntentHarness.localID, ProjectIntentHarness.remoteID] {
            h.context.insert(MachineDeployIntent(machineID: machine, skillSlug: "alpha", platformRaw: "codex"))
        }
        try h.context.save()
        var peer = try h.manifest.snapshot(from: h.context)
        try h.manifest.write(peer, toRoot: h.root)
        let index = try XCTUnwrap(peer.skills.firstIndex { $0.slug == "alpha" })
        peer.skills[index].createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        peer.skills[index].tags = ["peer"]
        peer.skills[index].scope = .project
        peer.deployIntents.removeAll { $0.machineID == ProjectIntentHarness.localID }
        peer.skills.sort { $0.slug < $1.slug }
        peer.categories.sort { $0.name < $1.name }
        return peer
    }

    private func delete(in h: ManifestSaveFixture, failRowSave: Bool = false) {
        var saves = 0
        XCTAssertEqual(SkillDeletionFlow.delete(skill: h.alpha, library: h.library, platformVM: h.platform,
            projects: [], context: h.context, persist: { context in
                saves += 1
                if failRowSave && saves == 2 { throw CocoaError(.fileWriteNoPermission) }
                try context.save()
            }), !failRowSave)
    }

    private func deliver(_ peer: ManifestSnapshot, in h: ManifestSaveFixture) throws {
        try h.files.writeFile(at: h.root + "/skills/alpha/SKILL.md",
            content: SkillSerializer.serialize(name: "Peer Alpha", description: "peer", body: "peer body"))
        try h.manifest.write(peer, toRoot: h.root)
    }

    private func deletionSlugs(in h: ManifestSaveFixture) throws -> [String] {
        try RefusedCreateRecords(path: h.recordPath, files: h.files).read().deletions.map(\.slug)
    }

    private func assertPeer(_ peer: ManifestSnapshot, in h: ManifestSaveFixture,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), peer, file: file, line: line)
        let displayed = try h.manifest.snapshot(from: h.context)
        XCTAssertEqual(displayed.skills.first { $0.slug == "alpha" }, peer.skills.first { $0.slug == "alpha" },
                       file: file, line: line)
        XCTAssertEqual(displayed.categories.sorted { $0.name < $1.name }, peer.categories, file: file, line: line)
        XCTAssertEqual(displayed.deployIntents, peer.deployIntents, file: file, line: line)
        try publishWindow(in: h)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), peer, file: file, line: line)
    }

    private func publishWindow(in h: ManifestSaveFixture) throws {
        try h.manifest.write(try StoreIngestState.snapshotForPublication(using: h.manifest,
            context: h.context, root: h.root), toRoot: h.root)
    }

    private func assertRetired(_ snapshot: ManifestSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(snapshot.categories.contains { $0.skillSlugs.contains("alpha") }, file: file, line: line)
        XCTAssertFalse(snapshot.deployIntents.contains { $0.skillSlug == "alpha" }, file: file, line: line)
    }
}
