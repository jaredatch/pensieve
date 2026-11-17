import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillRenameHoldRestartTests: XCTestCase {
    func testAHeldRenameIsStillHeldAfterReopening() async throws {
        for arm in ["plain", "retry-record", "row-read"] {
            let faults = RenameHoldFileFaults()
            let h = try SkillRenameTakeoverFixture(record: false, leftovers: false, distinctRecords: true,
                persistent: true, faults: faults)
            defer { h.cleanup() }
            var failures = 0
            faults.beforeWrite = { path in
                if path == h.recordPath, failures > 0 {
                    failures -= 1
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            failures = arm == "retry-record" ? .max : 0
            _ = try await h.beginHold()
            if arm == "retry-record" { XCTAssertFalse(h.files.fileExists(at: h.recordPath)) }
            failures = 0
            let before = try h.manifest.read(fromRoot: h.root)
            await h.editHeld()
            let bytes = try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml")
            let record = try h.files.readData(at: h.recordPath)
            try await h.reopen(failingRowRead: arm == "row-read")
            if arm == "row-read" { XCTAssertEqual(try h.files.readData(at: h.recordPath), record) }
            XCTAssertEqual(h.skill.tags, ["latest"])
            XCTAssertEqual(h.skill.scope, .user)
            XCTAssertEqual(h.skill.createdAt.timeIntervalSince1970, h.own.createdAt.timeIntervalSince1970, accuracy: 0.001)
            try h.syncHeld()
            try h.assertGuarded(before, bytes: bytes)
        }
    }

    func testLeavingAHoldNeverTouchesAnotherSkillUnderTheOldName() async throws {
        for restart in [false, true] {
            for oldExists in [false, true] {
                for exit in ["rename", "rename-unreadable", "finish", "delete"] {
                    let h = try SkillRenameTakeoverFixture(record: false, leftovers: false,
                        queueManifest: RecordingSaveManifest(), distinctRecords: true, persistent: true)
                    defer { h.cleanup() }
                    _ = try await h.beginHold()
                    var disk = try h.manifest.read(fromRoot: h.root)
                    disk.skills.removeAll { $0.slug == "alpha" }
                    if oldExists {
                        var replacement = h.own
                        replacement.createdAt = Date(timeIntervalSince1970: 1_500_000_000)
                        replacement.tags = ["replacement"]
                        disk.skills.append(replacement)
                    }
                    try h.manifest.write(disk, toRoot: h.root)
                    let oldBytes = oldExists ? try h.files.readData(at: h.root + "/manifest/skills/alpha.yaml") : nil
                    if restart { try await h.reopen() }
                    await h.editHeld()
                    let peer = disk.skills.first { $0.slug == "zulu" }
                    try leaveHold(h, by: exit, disk: &disk)
                    await h.saves.waitUntilIdle()
                    try h.syncHeld()
                    let after = try h.manifest.read(fromRoot: h.root)
                    XCTAssertEqual(after.skills.first { $0.slug == "alpha" }, disk.skills.first { $0.slug == "alpha" },
                        "restart=\(restart), oldExists=\(oldExists), exit=\(exit)")
                    try assertOldNameUnchanged(h, before: disk, after: after, bytes: oldBytes)
                    var expectedPeer = try XCTUnwrap(peer)
                    expectedPeer.slug = exit == "finish" ? "peer-away" : "zulu"
                    XCTAssertEqual(after.skills.first { $0.slug == expectedPeer.slug }, expectedPeer)
                    if exit == "delete" {
                        XCTAssertFalse(after.skills.contains { ManifestService.sameCreation($0, h.own) })
                    } else {
                        try h.assertPublished(exit.hasPrefix("rename") ? "free" : "zulu", carriesOld: false)
                    }
                    if exit == "finish", oldExists {
                        try await assertFinishedHoldSurvivesAnotherReopen(h, before: disk)
                    }
                }
            }
        }
    }

    private func leaveHold(_ h: SkillRenameTakeoverFixture, by exit: String,
                           disk: inout ManifestSnapshot) throws {
        if exit.hasPrefix("rename") {
            let reader = try XCTUnwrap(h.saves.manifest as? RecordingSaveManifest)
            var probeFailed = false
            if exit == "rename-unreadable" {
                reader.afterRead = {
                    guard Thread.isMainThread, !probeFailed else { return }
                    probeFailed = true
                    throw CocoaError(.fileReadNoPermission)
                }
            }
            XCTAssertTrue(h.renameHeld(), h.library.error ?? "")
            if exit == "rename-unreadable" { XCTAssertTrue(probeFailed) }
        } else if exit == "delete" {
            XCTAssertTrue(h.deleteHeld(), h.library.deletionNotice?.message ?? "")
        } else {
            var moved = try XCTUnwrap(disk.skills.first { $0.slug == "zulu" })
            disk.skills.removeAll { $0.slug == "zulu" }
            // The peer moves to another name; it still must survive publication.
            moved.slug = "peer-away"
            disk.skills.append(moved)
            _ = try h.store.createSkill(name: "Peer Away", description: "Peer", body: "Peer body")
            try h.manifest.write(disk, toRoot: h.root)
        }
    }

    private func assertFinishedHoldSurvivesAnotherReopen(_ h: SkillRenameTakeoverFixture,
                                                         before: ManifestSnapshot) async throws {
        h.tagLibrary.updateMetadata(h.other, tags: ["another edit"], scope: .user, context: h.context)
        await h.saves.waitUntilIdle()
        try await h.reopen()
        try h.syncHeld()
        let after = try h.manifest.read(fromRoot: h.root)
        XCTAssertEqual(after.skills.first { $0.slug == "alpha" }, before.skills.first { $0.slug == "alpha" })
        try assertOldNameUnchanged(h, before: before, after: after, bytes: nil)
    }

    private func assertOldNameUnchanged(_ h: SkillRenameTakeoverFixture, before: ManifestSnapshot,
                                        after: ManifestSnapshot, bytes: Data?) throws {
        for name in before.categories.map(\.name) {
            XCTAssertEqual(after.categories.first { $0.name == name }?.skillSlugs.filter { $0 == "alpha" },
                before.categories.first { $0.name == name }?.skillSlugs.filter { $0 == "alpha" })
        }
        XCTAssertEqual(after.deployIntents.filter { $0.skillSlug == "alpha" },
            before.deployIntents.filter { $0.skillSlug == "alpha" })
        if let bytes { XCTAssertEqual(try h.files.readData(at: h.root + "/manifest/skills/alpha.yaml"), bytes) }
    }

    func testQuittingWhileARenameWaitsReopensToAHeldRename() async throws {
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false, distinctRecords: true, persistent: true)
        defer { h.cleanup() }
        XCTAssertTrue(h.rename())
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        await TestWait.until(failureMessage: "The rename never waited on sync.lock") { h.saves.isWaiting }
        let atQuit = try ManifestSaveFixture.manifestBytes(root: h.root, files: h.files)
        await h.quitWaiting(release: held)
        XCTAssertEqual(try ManifestSaveFixture.manifestBytes(root: h.root, files: h.files), atQuit)
        try h.arrivePeer()
        try h.rememberGuardedRecords()
        let before = try h.manifest.read(fromRoot: h.root)
        try await h.reopen()
        XCTAssertEqual(h.skill.tags, ["own"])
        XCTAssertEqual(h.skill.scope, .project)
        XCTAssertEqual(h.skill.createdAt.timeIntervalSince1970, h.own.createdAt.timeIntervalSince1970, accuracy: 0.001)
        try h.syncHeld()
        try h.assertGuarded(before)
    }

    func testQuittingWhileARenameWaitsFinishesItAfterReopening() async throws {
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false, distinctRecords: true, persistent: true)
        defer { h.cleanup() }
        XCTAssertTrue(h.rename())
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        await TestWait.until(failureMessage: "The rename never waited on sync.lock") { h.saves.isWaiting }
        let atQuit = try ManifestSaveFixture.manifestBytes(root: h.root, files: h.files)
        await h.quitWaiting(release: held)
        XCTAssertEqual(try ManifestSaveFixture.manifestBytes(root: h.root, files: h.files), atQuit)
        try await h.reopen()
        try h.syncHeld()
        try h.assertPublished("zulu", tags: ["own"], scope: .project)
    }
}
