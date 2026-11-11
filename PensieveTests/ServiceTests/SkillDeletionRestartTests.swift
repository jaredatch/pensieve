import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillDeletionRestartTests: XCTestCase {
    func testADeletionQueuedJustBeforeQuitStaysDeletedAndPublishesOnLaunch() async throws {
        for failRowSave in [false, true] {
            try await assertOrdinaryDeletionSurvivesQuit(failRowSave: failRowSave)
        }
    }

    private func assertOrdinaryDeletionSurvivesQuit(failRowSave: Bool) async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        h.local.skillSlugs = ["alpha"]
        h.doomed.skillSlugs = ["alpha"]
        for machine in [ProjectIntentHarness.localID, ProjectIntentHarness.remoteID] {
            h.context.insert(MachineDeployIntent(machineID: machine, skillSlug: "alpha", platformRaw: "codex"))
        }
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)

        var saveCount = 0
        XCTAssertEqual(SkillDeletionFlow.delete(skill: h.alpha, library: h.library, platformVM: h.platform,
            projects: [], context: h.context, persist: { context in
                saveCount += 1
                if failRowSave && saveCount == 2 { throw CocoaError(.fileWriteNoPermission) }
                try context.save()
            }), !failRowSave)
        XCTAssertFalse(h.files.directoryExists(at: h.root + "/skills/alpha"))
        let record = h.files.fileExists(at: h.recordPath)
            ? try JSONSerialization.jsonObject(with: h.files.readData(at: h.recordPath)) as? [String: Any] : nil
        XCTAssertEqual((record?["deletions"] as? [[String: Any]])?.compactMap { $0["slug"] as? String }, ["alpha"])
        h.quit() // No suspension gives the old queue a chance to publish.

        try await h.relaunchThroughRuntime()
        XCTAssertFalse(h.local.skillSlugs.contains("alpha"))
        XCTAssertFalse(h.doomed.skillSlugs.contains("alpha"))
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<MachineDeployIntent>()).contains { $0.skillSlug == "alpha" })
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<Skill>()).contains { $0.directoryName == "alpha" })
        await h.saves.waitUntilIdle()
        let durable = try h.manifest.read(fromRoot: h.root)
        XCTAssertFalse(durable.skills.contains { $0.slug == "alpha" })
        XCTAssertFalse(durable.categories.contains { $0.skillSlugs.contains("alpha") })
        XCTAssertFalse(durable.deployIntents.contains { $0.skillSlug == "alpha" })
        let settled = h.files.fileExists(at: h.recordPath)
            ? try JSONSerialization.jsonObject(with: h.files.readData(at: h.recordPath)) as? [String: Any] : nil
        XCTAssertEqual((settled?["deletions"] as? [[String: Any]])?.count ?? 0, 0)
    }

    func testDeletingACollisionBeforeQuitRetiresThisMacAndPreservesThePeerThroughSync() async throws {
        for failRowSave in [false, true] {
            try await assertCollisionDeletionSurvivesQuit(failRowSave: failRowSave)
        }
    }

    private func assertCollisionDeletionSurvivesQuit(failRowSave: Bool) async throws {
        let h = try CollisionCreateFixture(persistent: true)
        defer { h.cleanup() }
        await h.saves.waitUntilIdle()
        try h.addOwnIntent()
        // Seed the saved request in both the local rows and the durable peer snapshot.
        var before = try h.f.manifest.read(fromRoot: h.f.app)
        before.deployIntents.append(DeployIntentRecord(machineID: ProjectIntentHarness.localID, skillSlug: "item",
            platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil))
        try h.f.manifest.write(before, toRoot: h.f.app)
        XCTAssertEqual(try h.ownIntents(), ["item"])
        XCTAssertTrue(try h.f.manifest.read(fromRoot: h.f.app).deployIntents.contains {
            $0.machineID == ProjectIntentHarness.localID && $0.skillSlug == "item"
        })

        var saveCount = 0
        XCTAssertEqual(SkillDeletionFlow.delete(skill: h.skill, library: h.library, platformVM: h.platform,
            projects: [], context: h.context, persist: { context in
                saveCount += 1
                if failRowSave && saveCount == 2 { throw CocoaError(.fileWriteNoPermission) }
                try context.save()
            }), !failRowSave)
        h.quit()
        try await h.relaunchThroughRuntime()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.ownIntents(), [])
        XCTAssertFalse(try h.f.manifest.read(fromRoot: h.f.app).deployIntents.contains {
            $0.machineID == ProjectIntentHarness.localID && $0.skillSlug == "item"
        })
        try h.assertPeer()
        try h.sync()
        try h.assertPeer()
    }
}
