import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func testAfterARelaunchDeletingACollisionRefusedSkillLeavesTheOtherMacsRecord() async throws {
        for failDelete in [false, true] {
            let h = try CollisionCreateFixture(failDelete: failDelete, persistent: true)
            defer { h.cleanup() }
            await h.saves.waitUntilIdle()
            h.library.updateMetadata(h.skill, tags: ["edited"], scope: .project, context: h.context)
            await h.saves.waitUntilIdle()
            try h.addOwnIntent()
            var disk = try h.f.manifest.read(fromRoot: h.f.app)
            disk.deployIntents.append(DeployIntentRecord(machineID: ProjectIntentHarness.localID, skillSlug: "item",
                platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil))
            try h.f.manifest.write(disk, toRoot: h.f.app)
            if failDelete { try h.relaunch() } else { try await h.relaunchThroughRuntime() }
            try h.assertLocal(tags: ["edited"], scope: .project)
            try h.assertPeer()
            XCTAssertEqual(try h.ownIntents(), ["item"])
            XCTAssertTrue(h.saves.hasCollision("item", context: h.context))
            XCTAssertEqual(SkillDeletionFlow.delete(skill: h.skill, library: h.library, platformVM: h.platform,
                projects: [], context: h.context), !failDelete)
            await h.saves.waitUntilIdle()
            try h.assertPeer()
            XCTAssertFalse(try h.f.manifest.read(fromRoot: h.f.app).deployIntents.contains {
                $0.machineID == ProjectIntentHarness.localID && $0.skillSlug == "item"
            })
            XCTAssertEqual(h.saves.refused.isEmpty, !failDelete)
            if failDelete {
                try h.assertLocal(tags: ["edited"], scope: .project)
                XCTAssertEqual(try h.heldSlugs(), ["item"])
                try h.relaunch()
                XCTAssertTrue(h.saves.hasCollision("item", context: h.context))
                try h.assertLocal(tags: ["edited"], scope: .project)
            } else {
                XCTAssertTrue(try h.context.fetch(FetchDescriptor<Skill>()).isEmpty)
                XCTAssertEqual(try h.heldSlugs(), [])
                XCTAssertEqual(try h.preserved(), ["item"])
                try await h.relaunchThroughRuntime()
                XCTAssertTrue(h.saves.refused.isEmpty)
                try h.sync()
                try h.assertPeer()
            }
        }
    }

    func testTheCollisionRecordFollowsTheRefusedCreate() async throws {
        // An ordinary publication failure is not a same-name collision.
        let ordinary = try CollisionCreateFixture(persistent: true)
        defer { ordinary.cleanup() }
        var empty = ordinary.peer
        empty.skills = []
        try ordinary.f.manifest.write(empty, toRoot: ordinary.f.app)
        ordinary.recording.failingWrites = 1
        await ordinary.saves.waitUntilIdle()
        XCTAssertFalse(ordinary.f.files.fileExists(at: ordinary.recordPath))
        XCTAssertEqual(ordinary.saves.refused.count, 1)

        let h = try CollisionCreateFixture(persistent: true)
        defer { h.cleanup() }
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.heldSlugs(), ["item"])
        XCTAssertEqual(try h.held().first?["created_at"] as? String, CollisionCreateFixture.writtenDate(h.local.createdAt))
        let second = try XCTUnwrap(h.library.createSkill(name: "Second", description: "job", body: "body",
            tags: ["second"], context: h.context))
        var disk = try h.f.manifest.read(fromRoot: h.f.app)
        var peerSecond = h.peer.skills[0]
        peerSecond.slug = second.directoryName
        disk.skills.append(peerSecond)
        try h.f.manifest.write(disk, toRoot: h.f.app)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.heldSlugs(), ["item", "second"])
        var own = h.local
        own.tags = ["later"]
        own.scope = .project
        disk.skills = [own, peerSecond]
        try h.f.manifest.write(disk, toRoot: h.f.app)
        h.saves.refreshRefused(durable: try h.f.manifest.read(fromRoot: h.f.app))
        XCTAssertFalse(h.saves.hasRefusedCreate("item", context: h.context))
        XCTAssertEqual(try h.heldSlugs(), ["second"])

        try await checkStaleRecordIdentities()
        try await checkRecordedManifestProbes()
        try await checkRecordedIntentMove()
        try await checkPreservedRecordPruning()
    }

    private func checkStaleRecordIdentities() async throws {
        // Stale identities do not claim a replacement row; absent rows do not revive a create.
        for missingRow in [false, true] {
            let stale = try CollisionCreateFixture(persistent: true)
            defer { stale.cleanup() }
            await stale.saves.waitUntilIdle()
            if missingRow { stale.context.delete(stale.skill) } else {
                stale.skill.createdAt = Date(timeIntervalSince1970: 1_400_000_000)
            }
            try stale.context.save()
            try stale.relaunch()
            XCTAssertTrue(stale.saves.refused.isEmpty)
            XCTAssertEqual(try stale.heldSlugs(), [])
            XCTAssertEqual(stale.skill.tags, stale.peer.skills[0].tags)
        }

    }

    private func checkRecordedManifestProbes() async throws {
        // A missing overlay releases the collision but keeps the create pending publication.
        let absent = try CollisionCreateFixture(persistent: true)
        defer { absent.cleanup() }
        await absent.saves.waitUntilIdle()
        var without = absent.peer
        without.skills = []
        try absent.f.manifest.write(without, toRoot: absent.f.app)
        try absent.relaunch()
        XCTAssertTrue(absent.saves.hasRefusedCreate("item", context: absent.context))
        XCTAssertFalse(absent.saves.hasCollision("item", context: absent.context))
        try absent.assertLocal()
        try absent.sync()
        absent.saves.refreshRefused(durable: try absent.f.manifest.read(fromRoot: absent.f.app))
        XCTAssertTrue(absent.saves.refused.isEmpty)
        XCTAssertEqual(try absent.heldSlugs(), [])
        XCTAssertEqual(try absent.f.manifest.read(fromRoot: absent.f.app).skills.first?.tags, absent.local.tags)

        let unreadable = try CollisionCreateFixture(persistent: true)
        defer { unreadable.cleanup() }
        await unreadable.saves.waitUntilIdle()
        let overlay = unreadable.f.app + "/manifest/skills/item.yaml"
        let original = try unreadable.f.files.readFile(at: overlay)
        try unreadable.f.files.writeFile(at: overlay, content: "[broken")
        try unreadable.relaunch()
        XCTAssertTrue(unreadable.saves.hasCollision("item", context: unreadable.context))
        XCTAssertEqual(try unreadable.heldSlugs(), ["item"])
        try unreadable.assertLocal()
        try unreadable.f.files.writeFile(at: overlay, content: original)
        unreadable.saves.refreshRefused(durable: try unreadable.f.manifest.read(fromRoot: unreadable.f.app))
        XCTAssertTrue(unreadable.saves.hasCollision("item", context: unreadable.context))

    }

    private func checkRecordedIntentMove() async throws {
        let h = try CollisionCreateFixture(persistent: true)
        defer { h.cleanup() }
        await h.saves.waitUntilIdle()
        try h.addOwnIntent()
        var disk = h.peer
        disk.deployIntents.append(DeployIntentRecord(machineID: ProjectIntentHarness.localID, skillSlug: "item",
            platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil))
        try h.f.manifest.write(disk, toRoot: h.f.app)
        h.recording.failingWrites = 1
        XCTAssertTrue(h.rename("item-2"))
        XCTAssertEqual(try h.heldSlugs(), ["item-2"], "Quitting before the queue drains must keep the intent move")
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.heldSlugs(), ["item-2"])
        let move = try XCTUnwrap(try h.held().first?["intent_move"] as? [String: Any])
        XCTAssertEqual(move["old_slugs"] as? [String], ["item"])
        XCTAssertEqual(move["new_slug"] as? String, "item-2")
        XCTAssertEqual(move["machine_id"] as? String, ProjectIntentHarness.localID)
        try h.relaunch()
        try h.assertLocal(slug: "item-2")
        XCTAssertEqual(try h.ownIntents(), ["item-2"])
        try h.sync()
        let afterSync = try h.f.manifest.read(fromRoot: h.f.app)
        XCTAssertEqual(afterSync.deployIntents.filter { $0.machineID == ProjectIntentHarness.localID }
            .map(\.skillSlug), ["item-2"])
        XCTAssertTrue(afterSync.deployIntents.contains(h.peer.deployIntents[0]))
        XCTAssertTrue(h.rename("item-3"))
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.library.error)
        XCTAssertTrue(h.saves.refused.isEmpty)
        try h.assertLocal(slug: "item-3")
        XCTAssertEqual(try h.ownIntents(), ["item-3"])
        XCTAssertEqual(try h.f.manifest.read(fromRoot: h.f.app).deployIntents
            .filter { $0.machineID == ProjectIntentHarness.localID }.map(\.skillSlug), ["item-3"])
        try h.assertPeer()
    }

    private func checkPreservedRecordPruning() async throws {
        let h = try CollisionCreateFixture(persistent: true)
        defer { h.cleanup() }
        await h.saves.waitUntilIdle()
        h.saves.discardRefusedCreate("item", context: h.context)
        XCTAssertEqual(try h.heldSlugs(), [])
        XCTAssertEqual(try h.preserved(), ["item"])
        let overlay = h.f.app + "/manifest/skills/item.yaml"
        let original = try h.f.files.readFile(at: overlay)
        try h.f.files.writeFile(at: overlay, content: "[broken")
        try h.relaunch()
        XCTAssertEqual(try h.preserved(), ["item"])
        try h.f.files.writeFile(at: overlay, content: original)
        var missing = h.peer
        missing.skills = []
        try h.f.manifest.write(missing, toRoot: h.f.app)
        try h.relaunch()
        XCTAssertEqual(try h.preserved(), [])
    }

    func testAnUnreadableCollisionRecordRestoresNothingAndIsNeverDowngraded() async throws {
        for directory in [false, true] {
            let h = try CollisionCreateFixture(persistent: true)
            defer { h.cleanup() }
            await h.saves.waitUntilIdle()
            if h.f.files.fileExists(at: h.recordPath) { try h.f.files.deleteFile(at: h.recordPath) }
            if directory { try h.f.files.createDirectory(at: h.recordPath) } else {
                try h.f.files.writeFile(at: h.recordPath, content: "not a record")
            }
            try h.relaunch()
            XCTAssertTrue(h.saves.refused.isEmpty)
            XCTAssertFalse(h.logs.isEmpty)
            XCTAssertEqual(h.skill.tags, h.peer.skills[0].tags, "Launch rebuild still runs")
            try await submitCollision(h)
            XCTAssertTrue(h.saves.hasCollision("item", context: h.context))
            XCTAssertEqual(try h.heldSlugs(), ["item"])
        }
        for version in [2, Int.max] {
            let h = try CollisionCreateFixture(persistent: true)
            defer { h.cleanup() }
            await h.saves.waitUntilIdle()
            try h.writeRecord(held: [], version: version)
            let bytes = try h.f.files.readData(at: h.recordPath)
            try h.relaunch()
            XCTAssertTrue(h.saves.refused.isEmpty)
            XCTAssertFalse(h.logs.isEmpty)
            XCTAssertEqual(h.skill.tags, h.peer.skills[0].tags)
            try await submitCollision(h)
            XCTAssertTrue(h.saves.hasCollision("item", context: h.context))
            XCTAssertEqual(h.library.error, CollisionCreateFixture.message("item"))
            XCTAssertEqual(try h.f.files.readData(at: h.recordPath), bytes)
            let snapshot = try StoreIngestState.snapshotForPublication(using: h.f.manifest, context: h.context, root: h.f.app)
            XCTAssertEqual(snapshot.skills.first { $0.slug == "item" }, h.peer.skills[0])
            h.saves.discardRefusedCreate("item", context: h.context)
            XCTAssertEqual(try h.f.files.readData(at: h.recordPath), bytes)
        }
        let h = try CollisionCreateFixture(persistent: true)
        defer { h.cleanup() }
        await h.saves.waitUntilIdle()
        try h.writeRecord(held: h.held(), preserved: ["another-peer"])
        let bytes = try h.f.files.readData(at: h.recordPath)
        try h.relaunch(failingSnapshots: 1)
        XCTAssertTrue(h.saves.refused.isEmpty)
        XCTAssertFalse(h.logs.isEmpty)
        XCTAssertEqual(try h.f.files.readData(at: h.recordPath), bytes)
        XCTAssertEqual(h.skill.tags, h.peer.skills[0].tags, "Failed restore does not block launch rebuild")
    }

    private func submitCollision(_ h: CollisionCreateFixture) async throws {
        h.skill.createdAt = h.local.createdAt
        h.skill.tags = h.local.tags
        h.skill.scope = h.local.scope
        try h.context.save()
        h.library.regenerateManifest(.createSkill(h.local), context: h.context)
        await h.saves.waitUntilIdle()
    }
}
