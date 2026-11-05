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

    func assertReusedName(_ h: CollisionCreateFixture, category: String, requests: [DeployIntentRecord],
                          file: StaticString = #filePath, line: UInt = #line) throws {
        let rows = try h.f.manifest.snapshot(from: h.context)
        XCTAssertEqual(rows.skills.first { $0.slug == "item" }?.tags, ["replacement"], file: file, line: line)
        XCTAssertEqual(rows.categories.first { $0.name == category }?.skillSlugs, ["item"], file: file, line: line)
        XCTAssertEqual(rows.deployIntents.filter { $0.skillSlug == "item" }.sorted { $0.machineID < $1.machineID },
            requests.sorted { $0.machineID < $1.machineID }, file: file, line: line)
    }

    func checkReusedName(replacementWriteFails: Bool) async throws {
        let h = try CollisionCreateFixture(persistent: true, noPeer: true)
        defer { h.cleanup() }
        let originalCategory = try await prepareWriteRefused(h)
        h.recording.failingWrites = 1
        XCTAssertTrue(h.rename("item-2"), h.library.error ?? "")
        await h.saves.waitUntilIdle()
        XCTAssertTrue(h.saves.hasRefusedCreate("item-2", context: h.context))
        h.recording.failingWrites = replacementWriteFails ? 1 : 0
        let replacement = try XCTUnwrap(h.library.createSkill(name: "Item", description: "Replacement", body: "new body",
            tags: ["replacement"], context: h.context))
        XCTAssertEqual(replacement.directoryName, "item")
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.saves.hasRefusedCreate("item", context: h.context), replacementWriteFails)
        let category = try XCTUnwrap(try h.context.fetch(FetchDescriptor<Pensieve.Category>())
            .first { $0.name != originalCategory })
        CategoryStore(manifestSaves: h.saves).setSkill(replacement, inCategory: category, assigned: true, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.saves.categoryNotice)
        var disk = try h.f.manifest.read(fromRoot: h.f.app)
        let requests = [ProjectIntentHarness.localID, ProjectIntentHarness.remoteID].map {
            DeployIntentRecord(machineID: $0, skillSlug: "item", platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil)
        }
        disk.deployIntents.removeAll { $0.skillSlug == "item" }
        disk.deployIntents.append(contentsOf: requests)
        try h.f.manifest.write(disk, toRoot: h.f.app)
        for request in requests {
            h.context.insert(MachineDeployIntent(machineID: request.machineID, skillSlug: request.skillSlug,
                platformRaw: request.platformRaw))
        }
        try h.context.save()
        try assertReusedName(h, category: category.name, requests: requests)
        try h.rebuild()
        try assertReusedName(h, category: category.name, requests: requests)
        let categoryName = category.name
        try await h.relaunchThroughRuntime()
        XCTAssertTrue(h.saves.hasRefusedCreate("item-2", context: h.context))
        try assertReusedName(h, category: categoryName, requests: requests)
        try h.sync()
        try assertReusedName(h, category: categoryName, requests: requests)
        let published = try h.f.manifest.read(fromRoot: h.f.app)
        XCTAssertEqual(published.skills.map(\.slug).sorted(), ["item", "item-2"])
        XCTAssertEqual(published.skills.first { $0.slug == "item" }?.tags, ["replacement"])
        XCTAssertEqual(published.categories.first { $0.name == categoryName }?.skillSlugs, ["item"])
        XCTAssertEqual(published.deployIntents.filter { $0.skillSlug == "item" }
            .sorted { $0.machineID < $1.machineID }, requests.sorted { $0.machineID < $1.machineID })
        try await h.relaunchThroughRuntime()
        XCTAssertTrue(h.saves.refused.isEmpty)
        XCTAssertEqual(try h.heldSlugs(), [])
        try assertReusedName(h, category: categoryName, requests: requests)
    }

    struct ReuseOwnership {
        let local: SkillOverlay
        let categoryA: String
        var categoryB: String?
        var removed = false
        var replacementRequest = false
        var laterPeer = false
    }

    func assertOwnership(_ snapshot: ManifestSnapshot, expected: ReuseOwnership, requireReplacement: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) {
        let local = expected.local, categoryA = expected.categoryA
        let categoryB = expected.categoryB, removed = expected.removed
        let replacementRequest = expected.replacementRequest, laterPeer = expected.laterPeer
        let renamed = snapshot.skills.first { $0.slug == "item-2" }
        XCTAssertNotNil(renamed, file: file, line: line)
        XCTAssertEqual(renamed?.tags, local.tags, file: file, line: line)
        XCTAssertEqual(renamed?.scope, local.scope, file: file, line: line)
        XCTAssertEqual(renamed?.origin, local.origin, file: file, line: line)
        XCTAssertEqual(renamed?.createdAt.timeIntervalSince1970 ?? 0,
            local.createdAt.timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
        if requireReplacement {
            XCTAssertEqual(snapshot.skills.first { $0.slug == "item" }?.tags, ["replacement"], file: file, line: line)
        }
        let originalMembers = removed ? [] : ["item-2"]
        XCTAssertEqual(snapshot.categories.first { $0.name == categoryA }?.skillSlugs.sorted(),
            (originalMembers + (laterPeer ? ["item"] : [])).sorted(), file: file, line: line)
        if let categoryB {
            XCTAssertEqual(snapshot.categories.first { $0.name == categoryB }?.skillSlugs, ["item"], file: file, line: line)
        } else {
            XCTAssertFalse(snapshot.categories.contains { $0.skillSlugs.contains("item") }, file: file, line: line)
        }
        for (machine, hasReplacement) in [(ProjectIntentHarness.localID, replacementRequest),
                                          (ProjectIntentHarness.remoteID, laterPeer)] {
            let expected = (["item-2"] + (hasReplacement ? ["item"] : [])).map {
                DeployIntentRecord(machineID: machine, skillSlug: $0,
                    platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil)
            }.sorted { $0.skillSlug < $1.skillSlug }
            XCTAssertEqual(snapshot.deployIntents.filter { $0.machineID == machine }.sorted { $0.skillSlug < $1.skillSlug },
                expected, file: file, line: line)
        }
    }

    func assertHeldMove(_ h: CollisionCreateFixture) throws {
        XCTAssertTrue(h.saves.hasRefusedCreate("item-2", context: h.context))
        let held = try XCTUnwrap(try h.held().first { $0["slug"] as? String == "item-2" })
        let move = try XCTUnwrap(held["intent_move"] as? [String: Any])
        XCTAssertEqual(move["old_slugs"] as? [String], ["item"])
        XCTAssertEqual(move["new_slug"] as? String, "item-2")
        XCTAssertEqual(move["carried_slugs"] as? [String], ["item"])
    }

    func prepareLeftoverReuse(_ h: CollisionCreateFixture, replacementWriteFails: Bool,
                              removed: Bool) async throws -> ReuseOwnership {
        let categoryA = try await prepareWriteRefused(h)
        h.recording.failingWrites = 1
        XCTAssertTrue(h.rename("item-2"), h.library.error ?? "")
        await h.saves.waitUntilIdle()
        try assertHeldMove(h)
        if removed {
            try await assign(h, category: categoryA, assigned: false)
        }
        XCTAssertEqual(try h.f.manifest.read(fromRoot: h.f.app).categories.first { $0.name == categoryA }?.skillSlugs,
            ["item"])
        h.recording.failingWrites = replacementWriteFails ? 1 : 0
        let replacement = try XCTUnwrap(h.library.createSkill(name: "Item", description: "Replacement", body: "new body",
            tags: ["replacement"], context: h.context))
        XCTAssertEqual(replacement.directoryName, "item")
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.saves.hasRefusedCreate("item", context: h.context), replacementWriteFails)
        let categoryB = try XCTUnwrap(try h.context.fetch(FetchDescriptor<Pensieve.Category>())
            .first { $0.name != categoryA })
        let categoryBName = categoryB.name
        CategoryStore(manifestSaves: h.saves).setSkill(replacement, inCategory: categoryB, assigned: true, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.saves.categoryNotice)
        if !removed {
            var disk = try h.f.manifest.read(fromRoot: h.f.app)
            let own = DeployIntentRecord(machineID: ProjectIntentHarness.localID, skillSlug: "item",
                platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil)
            disk.deployIntents.append(own)
            try h.f.manifest.write(disk, toRoot: h.f.app)
            h.context.insert(MachineDeployIntent(machineID: own.machineID, skillSlug: own.skillSlug,
                platformRaw: own.platformRaw))
            try h.context.save()
        }
        let durable = try h.f.manifest.read(fromRoot: h.f.app)
        XCTAssertEqual(durable.categories.first { $0.name == categoryA }?.skillSlugs, ["item"])
        XCTAssertEqual(durable.deployIntents.filter { $0.machineID == ProjectIntentHarness.remoteID }.map(\.skillSlug),
            ["item"])
        return ReuseOwnership(local: h.local, categoryA: categoryA, categoryB: categoryBName,
            removed: removed, replacementRequest: !removed)
    }

    func checkLeftoverOwnership(replacementWriteFails: Bool, removed: Bool) async throws {
        let h = try CollisionCreateFixture(persistent: true, noPeer: true)
        defer { h.cleanup() }
        var expected = try await prepareLeftoverReuse(h, replacementWriteFails: replacementWriteFails, removed: removed)
        func assertRows(file: StaticString = #filePath, line: UInt = #line) throws {
            assertOwnership(try h.f.manifest.snapshot(from: h.context), expected: expected, file: file, line: line)
        }
        try h.rebuild()
        try assertRows()
        try await h.relaunchThroughRuntime()
        try assertRows()
        try h.sync()
        try assertRows()
        assertOwnership(try h.f.manifest.read(fromRoot: h.f.app), expected: expected)
        if !removed {
            try assertHeldMove(h)
            var disk = try h.f.manifest.read(fromRoot: h.f.app)
            disk.deployIntents.append(DeployIntentRecord(machineID: ProjectIntentHarness.remoteID, skillSlug: "item",
                platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil))
            let index = try XCTUnwrap(disk.categories.firstIndex { $0.name == expected.categoryA })
            disk.categories[index].skillSlugs.append("item")
            try h.f.manifest.write(disk, toRoot: h.f.app)
            try h.rebuild()
            expected.laterPeer = true
            try assertRows()
            try assertHeldMove(h)
            try h.sync()
            assertOwnership(try h.f.manifest.read(fromRoot: h.f.app), expected: expected)
        }
        try await h.relaunchThroughRuntime()
        XCTAssertTrue(h.saves.refused.isEmpty)
        XCTAssertEqual(try h.heldSlugs(), [])
        try assertRows()
    }

    func checkQueuedOwnership(unreadable: Bool) async throws {
        let h = try CollisionCreateFixture(persistent: unreadable, noPeer: true)
        defer { h.cleanup() }
        let category = try await prepareWriteRefused(h)
        let firstWrite = h.recording.writes.count
        XCTAssertTrue(h.rename("item-2"), h.library.error ?? "")
        let replacement = try XCTUnwrap(h.library.createSkill(name: "Item", description: "Replacement", body: "new body",
            tags: ["replacement"], context: h.context))
        XCTAssertEqual(replacement.directoryName, "item")
        if unreadable { h.recording.failingSnapshots = 1 }
        await h.saves.waitUntilIdle()
        if unreadable {
            XCTAssertEqual(h.recording.failingSnapshots, 0)
            try h.sync()
        } else {
            XCTAssertTrue(h.saves.refused.isEmpty)
            XCTAssertNil(h.library.error)
        }
        // The replacement overlay need not exist in the rename's own write yet.
        let writes = h.recording.writes.dropFirst(firstWrite).filter { $0.skills.contains { $0.slug == "item-2" } }
        if !unreadable { XCTAssertFalse(writes.isEmpty) }
        let expected = ReuseOwnership(local: h.local, categoryA: category)
        for write in writes {
            assertOwnership(write, expected: expected, requireReplacement: false)
        }
        assertOwnership(try h.f.manifest.read(fromRoot: h.f.app), expected: expected)
        assertOwnership(try h.f.manifest.snapshot(from: h.context), expected: expected)
        if unreadable {
            try await h.relaunchThroughRuntime()
            XCTAssertTrue(h.saves.refused.isEmpty)
            XCTAssertEqual(try h.heldSlugs(), [])
            assertOwnership(try h.f.manifest.snapshot(from: h.context), expected: expected)
        }
    }

}
