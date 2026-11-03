import SwiftData
import XCTest
@testable import Pensieve

extension ManifestRenameTests {
    func prepareWriteRefused(_ h: CollisionCreateFixture) async throws -> String {
        await h.saves.waitUntilIdle()
        XCTAssertTrue(h.saves.hasRefusedCreate("item", context: h.context))
        XCTAssertFalse(h.saves.hasCollision("item", context: h.context))
        XCTAssertTrue(try h.f.manifest.read(fromRoot: h.f.app).skills.isEmpty)
        let category = try XCTUnwrap(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).first).name
        try await assign(h, category: category, assigned: true)
        var disk = try h.f.manifest.read(fromRoot: h.f.app)
        XCTAssertEqual(disk.categories.first { $0.name == category }?.skillSlugs, ["item"])
        try h.addOwnIntent()
        let remote = DeployIntentRecord(machineID: ProjectIntentHarness.remoteID, skillSlug: "item",
            platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil)
        disk.deployIntents.append(remote)
        try h.f.manifest.write(disk, toRoot: h.f.app)
        h.context.insert(MachineDeployIntent(machineID: remote.machineID, skillSlug: remote.skillSlug,
            platformRaw: remote.platformRaw))
        try h.context.save()
        return category
    }

    func assign(_ h: CollisionCreateFixture, category name: String, assigned: Bool) async throws {
        let category = try XCTUnwrap(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == name })
        CategoryStore(manifestSaves: h.saves).setSkill(h.skill, inCategory: category, assigned: assigned, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.saves.categoryNotice)
    }

    func assertMove(_ h: CollisionCreateFixture, carried: [String]) throws {
        XCTAssertEqual(try h.heldSlugs(), ["item-2"])
        let move = try XCTUnwrap(try h.held().first?["intent_move"] as? [String: Any])
        XCTAssertEqual(move["old_slugs"] as? [String], ["item"])
        XCTAssertEqual(move["new_slug"] as? String, "item-2")
        XCTAssertEqual(move["machine_id"] as? String, ProjectIntentHarness.localID)
        XCTAssertEqual(move["carried_slugs"] as? [String], carried)
        XCTAssertEqual(try h.record()["schema_version"] as? Int, 1)
    }

    func assertCarried(_ h: CollisionCreateFixture, category: String) throws {
        try h.assertLocal(slug: "item-2")
        assertCarried(try h.f.manifest.snapshot(from: h.context), local: h.local, category: category)
    }

    func assertCarried(_ snapshot: ManifestSnapshot, local: SkillOverlay, category: String) {
        XCTAssertFalse(snapshot.skills.contains { $0.slug == "item" })
        let own = snapshot.skills.first { $0.slug == "item-2" }
        XCTAssertEqual(own?.tags, local.tags)
        XCTAssertEqual(own?.scope, local.scope)
        XCTAssertEqual(own?.origin, local.origin)
        XCTAssertEqual(own?.createdAt.timeIntervalSince1970 ?? 0, local.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(snapshot.categories.first { $0.name == category }?.skillSlugs, ["item-2"])
        XCTAssertFalse(snapshot.categories.contains { $0.skillSlugs.contains("item") })
        for machine in [ProjectIntentHarness.localID, ProjectIntentHarness.remoteID] {
            XCTAssertEqual(snapshot.deployIntents.filter { $0.machineID == machine }.map(\.skillSlug), ["item-2"])
        }
    }

    func assertMixedChain(_ h: CollisionCreateFixture, category: String) throws {
        try h.assertLocal(slug: "item-3")
        let disk = try h.f.manifest.read(fromRoot: h.f.app)
        XCTAssertEqual(disk.skills.first { $0.slug == "item" }, h.peer.skills[0])
        let own = try XCTUnwrap(disk.skills.first { $0.slug == "item-3" })
        XCTAssertEqual(own.tags, h.local.tags)
        XCTAssertEqual(own.scope, h.local.scope)
        XCTAssertEqual(own.origin, h.local.origin)
        XCTAssertEqual(own.createdAt.timeIntervalSince1970, h.local.createdAt.timeIntervalSince1970, accuracy: 0.001)
        for snapshot in [disk, try h.f.manifest.snapshot(from: h.context)] {
            XCTAssertEqual(snapshot.categories.first { $0.name == category }?.skillSlugs.sorted(), ["item", "item-3"])
            XCTAssertEqual(snapshot.deployIntents.filter { $0.machineID == ProjectIntentHarness.localID }
                .map(\.skillSlug), ["item-3"])
            XCTAssertEqual(snapshot.deployIntents.filter { $0.machineID == ProjectIntentHarness.remoteID }, h.peer.deployIntents)
        }
    }

}
