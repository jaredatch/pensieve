import SwiftData
import XCTest
@testable import Pensieve

extension CategorySaveUndoTests {
    func testAFailedSkillDeletionStaysOwedAfterYouQuitAndReopenPensieve() async throws {
        let h = try persistentRetirementFixture()
        defer { h.cleanup() }
        try await refusePersistentDeletion(h)
        var peer = try h.manifest.read(fromRoot: h.root)
        peer.categories.append(CategoryRecord(name: "Peer", projectKeys: [], skillSlugs: ["alpha"]))
        let added = DeployIntentRecord(machineID: ProjectIntentHarness.remoteID, skillSlug: "alpha",
                                       platformRaw: "claudeCode", projectKey: "peer-project")
        peer.deployIntents.append(added)
        try h.manifest.write(peer, toRoot: h.root)
        let before = try h.manifestBytes()

        try await h.relaunchThroughRuntime()
        try assertOwedRetirement(h, absent: ["Local", "ZDelete"], present: ["Peer"], intents: [added])
        XCTAssertEqual(try h.manifestBytes(), before, "Startup must leave the synced manifest alone")
        XCTAssertTrue(SkillDeletionFlow.delete(skill: try XCTUnwrap(h.alpha), library: h.library,
            platformVM: h.platform, projects: [], context: h.context))
        await h.saves.waitUntilIdle()
        let durable = try h.manifest.read(fromRoot: h.root)
        XCTAssertFalse(durable.skills.contains { $0.slug == "alpha" })
        XCTAssertFalse(durable.categories.contains { $0.skillSlugs.contains("alpha") })
        XCTAssertFalse(durable.deployIntents.contains { $0.skillSlug == "alpha" })
        XCTAssertFalse(h.files.directoryExists(at: h.root + "/skills/alpha"))
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<Skill>()).contains { $0.directoryName == "alpha" })
        try assertNoOwedRetirement(h)
        try await assertAMissingOverlayDoesNotForgetTheRetirement()
    }

    func testAnOwedDeletionSurvivesRestartsAndSettlesOneFieldAtATime() async throws {
        let h = try persistentRetirementFixture()
        defer { h.cleanup() }
        try await refusePersistentDeletion(h)
        try await h.relaunchThroughRuntime()
        try assertOwedRetirement(h, absent: ["Local", "ZDelete"])

        try setDurableMembership(h, category: "Local", members: [])
        try await h.relaunchThroughRuntime()
        try assertOwedRetirement(h, absent: ["Local", "ZDelete"])
        try setDurableMembership(h, category: "Local", members: ["alpha"])
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: h.root, context: h.context)
        try assertOwedRetirement(h, absent: ["ZDelete"], present: ["Local"])

        h.categories.setSkill(h.alpha, inCategory: h.doomed, assigned: true, context: h.context)
        await h.saves.waitUntilIdle()
        try await h.relaunchThroughRuntime()
        try assertOwedRetirement(h, absent: [], present: ["Local", "ZDelete"])
        var durable = try h.manifest.read(fromRoot: h.root)
        durable.deployIntents = []
        try h.manifest.write(durable, toRoot: h.root)
        try await h.relaunchThroughRuntime()
        try assertNoOwedRetirement(h)
        try await h.relaunchThroughRuntime()
        try assertNoOwedRetirement(h)
        XCTAssertEqual(h.local.skillSlugs, ["alpha"])
        XCTAssertEqual(h.doomed.skillSlugs, ["alpha"])
        try await assertLegacyHeldCreateRestores()
    }

    func testARenamedCategoryStaysSettledForAnOwedDeletionAcrossARestart() async throws {
        let h = try persistentRetirementFixture(twoCategories: false, remoteIntent: false)
        defer { h.cleanup() }
        try await refusePersistentDeletion(h)
        h.categories.rename(h.local, to: "Renamed", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.first { $0.name == "Renamed" }?.skillSlugs,
                       ["alpha"])
        try await h.relaunchThroughRuntime()
        try assertOwedRetirement(h, absent: ["Renamed"])

        let replacement = try XCTUnwrap(h.categories.create(name: "Local", context: h.context))
        h.categories.setSkill(h.alpha, inCategory: replacement, assigned: true, context: h.context)
        await h.saves.waitUntilIdle()
        try assertOwedRetirement(h, absent: ["Renamed"], present: ["Local"])
        try await h.relaunchThroughRuntime()
        try assertOwedRetirement(h, absent: ["Renamed"], present: ["Local"])
        try setDurableMembership(h, category: "Renamed", members: [])
        try await h.relaunchThroughRuntime()
        try assertNoOwedRetirement(h)
        XCTAssertEqual(h.local.skillSlugs, ["alpha"])
        try await assertUndoneRenameIsNotReplayed()
    }

    private func assertAMissingOverlayDoesNotForgetTheRetirement() async throws {
        let h = try persistentRetirementFixture()
        defer { h.cleanup() }
        try await refusePersistentDeletion(h)
        var peer = try h.manifest.read(fromRoot: h.root)
        peer.skills.removeAll { $0.slug == "alpha" }
        try h.manifest.write(peer, toRoot: h.root)
        try await h.relaunchThroughRuntime()
        try assertOwedRetirement(h, absent: ["Local", "ZDelete"])
    }

    private func assertUndoneRenameIsNotReplayed() async throws {
        let h = try persistentRetirementFixture(twoCategories: false, remoteIntent: false)
        defer { h.cleanup() }
        try await refusePersistentDeletion(h)
        var peer = try h.manifest.read(fromRoot: h.root)
        peer.categories.append(CategoryRecord(name: "Taken", projectKeys: [], skillSlugs: ["alpha"]))
        try h.manifest.write(peer, toRoot: h.root)
        h.categories.rename(h.local, to: "Taken", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.local.name, "Local", "The conflicting rename must be undone")
        try await h.relaunchThroughRuntime()
        try assertOwedRetirement(h, absent: ["Local"], present: ["Taken"])
    }

    private func persistentRetirementFixture(twoCategories: Bool = true, remoteIntent: Bool = true) throws
        -> ManifestSaveFixture {
        let h = try ManifestSaveFixture(failAlphaDeletion: true, persistent: true)
        h.local.skillSlugs = ["alpha"]
        if twoCategories { h.doomed.skillSlugs = ["alpha"] }
        if remoteIntent {
            h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.remoteID,
                skillSlug: "alpha", platformRaw: "codex"))
        }
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
        return h
    }

    private func refusePersistentDeletion(_ h: ManifestSaveFixture) async throws {
        h.recording.failingWrites = 1
        XCTAssertFalse(SkillDeletionFlow.delete(skill: h.alpha, library: h.library, platformVM: h.platform,
                                                projects: [], context: h.context))
        await h.saves.waitUntilIdle()
        XCTAssertTrue(h.library.error?.contains("updating the sync manifest failed") == true)
        XCTAssertEqual(h.saves.refused.count, 1)
    }

    private func assertOwedRetirement(_ h: ManifestSaveFixture, absent: [String], present: [String] = [],
                                      intents: [DeployIntentRecord] = [],
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(h.files.directoryExists(at: h.root + "/skills/alpha"), file: file, line: line)
        let displayed = try h.manifest.snapshot(from: h.context)
        XCTAssertTrue(displayed.skills.contains { $0.slug == "alpha" }, file: file, line: line)
        XCTAssertEqual(h.saves.refused.count, 1, "Deletion must still be owed after reopening", file: file, line: line)
        let durable = try h.manifest.read(fromRoot: h.root)
        let projected = StoreIngestState.shared(for: h.context.container).projectingEdits(onto: durable).snapshot
        for snapshot in [displayed, projected] {
            for name in absent {
                XCTAssertEqual(snapshot.categories.first { $0.name == name }?.skillSlugs, [], file: file, line: line)
            }
            for name in present {
                XCTAssertEqual(snapshot.categories.first { $0.name == name }?.skillSlugs, ["alpha"], file: file, line: line)
            }
            XCTAssertEqual(snapshot.deployIntents.count, intents.count, file: file, line: line)
            XCTAssertTrue(snapshot.deployIntents.allSatisfy(intents.contains), file: file, line: line)
        }
    }

    private func setDurableMembership(_ h: ManifestSaveFixture, category: String, members: [String]) throws {
        var durable = try h.manifest.read(fromRoot: h.root)
        let index = try XCTUnwrap(durable.categories.firstIndex { $0.name == category })
        durable.categories[index].skillSlugs = members
        try h.manifest.write(durable, toRoot: h.root)
    }

    private func assertNoOwedRetirement(_ h: ManifestSaveFixture,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(h.saves.refused.isEmpty, file: file, line: line)
        guard h.files.fileExists(at: h.recordPath) else { return }
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: h.files.readData(at: h.recordPath)) as? [String: Any])
        XCTAssertEqual((record["retirements"] as? [[String: Any]])?.count ?? 0, 0, file: file, line: line)
    }

    private func assertLegacyHeldCreateRestores() async throws {
        let h = try CollisionCreateFixture(persistent: true)
        defer { h.cleanup() }
        await h.saves.waitUntilIdle()
        // Bytes an earlier build wrote: held creates, with no retirements key.
        try h.writeRecord(held: [["slug": "item", "created_at": CollisionCreateFixture.writtenDate(h.local.createdAt)]])
        try await h.relaunchThroughRuntime()
        try h.assertLocal()
        XCTAssertTrue(h.saves.hasCollision("item", context: h.context))
    }
}
