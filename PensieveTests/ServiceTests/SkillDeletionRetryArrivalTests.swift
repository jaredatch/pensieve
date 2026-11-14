import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillDeletionRetryArrivalTests: XCTestCase, SkillDeletionArrivalAssertions {
    func testDeletingTwiceUnsuccessfullyThenRetryingWhileSyncWaitsKeepsThePeerAndRetiresOnlyTheOtherKeptSkill() async throws {
        let h = try ManifestSaveFixture(failAlphaDeletion: true, persistent: true)
        defer { h.cleanup() }
        h.doomed.skillSlugs = ["beta"]
        h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.remoteID, skillSlug: "beta", platformRaw: "codex"))
        let peer = try seedRetirement(in: h)
        let before = try h.manifestBytes()
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        h.deletionFailures.paths = [h.root + "/skills/alpha", h.root + "/skills/beta"]
        assertFailedDeletion(h.alpha, in: h)
        await h.assertWaitingBehindHeldLock(pending: 1, before: before)

        assertFailedDeletion(h.beta, in: h)
        assertFailedDeletion(h.alpha, in: h)
        h.deletionFailures.paths.remove(h.root + "/skills/alpha")
        delete(in: h)
        XCTAssertFalse(h.files.directoryExists(at: h.root + "/skills/alpha"))
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<Skill>()).contains { $0.directoryName == "alpha" })
        await h.assertWaitingBehindHeldLock(pending: 5, before: before)
        XCTAssertTrue(try deletionSlugs(in: h).contains("alpha"))
        try deliver(peer, in: h)
        held.release()
        await h.saves.waitUntilIdle()

        var expected = peer
        for index in expected.categories.indices { expected.categories[index].skillSlugs.removeAll { $0 == "beta" } }
        expected.deployIntents.removeAll { $0.skillSlug == "beta" }
        try assertPeer(expected, in: h)
        XCTAssertTrue(h.files.directoryExists(at: h.root + "/skills/beta"))
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<Skill>()).contains { $0.directoryName == "beta" })
        XCTAssertEqual(h.recording.writes, [expected], "Only the kept beta's retirement may publish")
        XCTAssertFalse(try deletionSlugs(in: h).contains("alpha"))
    }

    func testRetryingAfterAFailedDeleteWithAFailedRowSaveKeepsTheArrivingPeerAndLetsItsRetainedRowOpen() async throws {
        let h = try ManifestSaveFixture(failAlphaDeletion: true, persistent: true)
        defer { h.cleanup() }
        let peer = try seedRetirement(in: h)
        let retainedID = h.alpha.id
        let before = try h.manifestBytes()
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        assertFailedDeletion(h.alpha, in: h)
        await h.assertWaitingBehindHeldLock(pending: 1, before: before)

        h.deletionFailures.paths.remove(h.root + "/skills/alpha")
        delete(in: h, failRowSave: true)
        XCTAssertFalse(h.files.directoryExists(at: h.root + "/skills/alpha"))
        XCTAssertTrue(h.library.pendingRowCleanup.contains(retainedID))
        await h.assertWaitingBehindHeldLock(pending: 2, before: before)
        XCTAssertEqual(try deletionSlugs(in: h), ["alpha"])
        try deliver(peer, in: h)
        held.release()
        await h.saves.waitUntilIdle()

        try assertPeer(peer, in: h)
        let row = try XCTUnwrap(h.context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "alpha" })
        XCTAssertEqual(row.id, retainedID, "The returned skill refreshes the retained row")
        XCTAssertFalse(h.library.pendingRowCleanup.contains(row.id))
        XCTAssertFalse(h.library.isWriteFenced(row), "The returned skill must open normally")
        XCTAssertEqual(try deletionSlugs(in: h), [])
        XCTAssertTrue(h.recording.writes.isEmpty)
    }

    func testRetryingAfterAFailedDeleteWhileSyncWaitsFinishesDeletionWhenNothingArrives() async throws {
        let h = try ManifestSaveFixture(failAlphaDeletion: true, persistent: true)
        defer { h.cleanup() }
        _ = try seedRetirement(in: h)
        let before = try h.manifestBytes()
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        assertFailedDeletion(h.alpha, in: h)
        await h.assertWaitingBehindHeldLock(pending: 1, before: before)

        h.deletionFailures.paths.remove(h.root + "/skills/alpha")
        delete(in: h)
        await h.assertWaitingBehindHeldLock(pending: 3, before: before)
        XCTAssertEqual(try deletionSlugs(in: h), ["alpha"])
        held.release()
        await h.saves.waitUntilIdle()

        let durable = try h.manifest.read(fromRoot: h.root)
        assertRetired(durable)
        XCTAssertFalse(durable.skills.contains { $0.slug == "alpha" })
        XCTAssertFalse(h.files.directoryExists(at: h.root + "/skills/alpha"))
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<Skill>()).contains { $0.directoryName == "alpha" })
        XCTAssertEqual(h.recording.writes.count, 3, "Every queued edit must publish")
        XCTAssertEqual(try deletionSlugs(in: h), [])
        try publishWindow(in: h)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), durable)
    }

    func testFailingToDeleteWhileSyncWaitsKeepsTheSkillAndRetiresItsCategoriesAndRequests() async throws {
        let h = try ManifestSaveFixture(failAlphaDeletion: true, persistent: true)
        defer { h.cleanup() }
        _ = try seedRetirement(in: h)
        let before = try h.manifestBytes()
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        assertFailedDeletion(h.alpha, in: h)
        await h.assertWaitingBehindHeldLock(pending: 1, before: before)
        held.release()
        await h.saves.waitUntilIdle()

        let durable = try h.manifest.read(fromRoot: h.root)
        assertRetired(durable)
        XCTAssertTrue(durable.skills.contains { $0.slug == "alpha" })
        XCTAssertTrue(h.files.directoryExists(at: h.root + "/skills/alpha"))
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<Skill>()).contains { $0.directoryName == "alpha" })
        XCTAssertEqual(h.recording.writes.count, 1)
        try publishWindow(in: h)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), durable)
    }

    private func assertFailedDeletion(_ skill: Skill, in h: ManifestSaveFixture,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: h.library, platformVM: h.platform,
            projects: [], context: h.context), file: file, line: line)
        XCTAssertTrue(h.files.directoryExists(at: h.root + "/skills/" + skill.directoryName), file: file, line: line)
    }
}
