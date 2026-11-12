import XCTest
@testable import Pensieve

@MainActor
final class SkillRenameQueuedRefusalTests: XCTestCase {
    func testTakenRenameDoesNotFailTheTagSaveAheadOfIt() async throws {
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false)
        defer { h.cleanup() }
        let firstLock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        h.tagLibrary.updateMetadata(h.other, tags: ["edited"], scope: .user, context: h.context)
        firstLock.release()
        // The flow owns the same lock. Queue both edits before yielding to their worker.
        XCTAssertTrue(h.rename(), h.library.error ?? "")
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        var disk = try h.manifest.read(fromRoot: h.root)
        disk.skills.append(h.leftover)
        try h.manifest.write(disk, toRoot: h.root)
        // A pull also updates the old path before this Mac has published its move.
        // Keeping both scanned names exercises refusal in the earlier save's pending projection.
        _ = try h.store.createSkill(name: "Alpha", description: "Updated by peer", body: "Peer body")
        try h.moveHead()
        let peerBytes = try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml")
        held.release()
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.tagLibrary.error, "The earlier edit must never report a rebuild failure")
        XCTAssertEqual(h.library.error, h.takenMessage())
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "other" }?.tags, ["edited"])
        XCTAssertEqual(try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml"), peerBytes)
        XCTAssertEqual(h.saves.pendingCount, 0)
    }
}
