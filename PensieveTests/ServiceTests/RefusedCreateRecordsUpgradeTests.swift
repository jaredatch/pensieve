import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class RefusedCreateRecordsUpgradeTests: XCTestCase, SkillDeletionArrivalAssertions {
    func testVersionOneRemindersRestoreAllProtectionsAndAreRewrittenAsVersionTwo() async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        let seed = try seedVersionOne(in: h)
        h.quit()
        let helper = DeletionRestartSyncHold()
        defer { helper.release() }
        let paths = AppRuntimePaths(storeRoot: h.root, appSupportDir: h.root + "/support")
        let reconcile = paths.makeLaunchReconcile(), lockPath = h.lockPath
        try await h.relaunchThroughRuntime(launchReconcile: { context, migrated in
            let result = reconcile(context, migrated)
            helper.start(lockPath: lockPath)
            return result
        })
        await fulfillment(of: [helper.acquired], timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertTrue(h.saves.hasCollision("beta", context: h.context))
        XCTAssertTrue(h.saves.preservedPeerSlugs.contains("preserved"))
        let shown = try h.manifest.snapshot(from: h.context)
        XCTAssertEqual(shown.skills.first { $0.slug == "beta" }?.tags, ["local-held"])
        XCTAssertFalse(shown.categories.contains { $0.skillSlugs.contains("alpha") || $0.skillSlugs.contains("owed") })
        XCTAssertFalse(shown.deployIntents.contains { $0.skillSlug == "alpha" || $0.skillSlug == "owed" })
        let rewritten = try readJSON(in: h)
        let retained = try XCTUnwrap((rewritten["retirements"] as? [[String: Any]])?.first)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: retained, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: seed.retirement, options: .sortedKeys))
        helper.release()
        await fulfillment(of: [helper.finished], timeout: TestWait.hostedActionTimeoutSeconds)
        await h.saves.waitUntilIdle()
        let afterDeletion = try h.manifest.read(fromRoot: h.root)
        XCTAssertFalse(afterDeletion.skills.contains { $0.slug == "owed" })
        XCTAssertFalse(afterDeletion.categories.contains { $0.skillSlugs.contains("owed") })
        XCTAssertFalse(afterDeletion.deployIntents.contains { $0.skillSlug == "owed" })
        try publishWindow(in: h)
        let published = try h.manifest.read(fromRoot: h.root)
        XCTAssertFalse(published.categories.contains { $0.name == "Current" && $0.skillSlugs.contains("alpha") })
        XCTAssertFalse(published.deployIntents.contains { $0.skillSlug == "alpha" })
        XCTAssertEqual(published.skills.first { $0.slug == "beta" }, seed.disk.skills.first { $0.slug == "beta" })
        XCTAssertEqual(published.skills.first { $0.slug == "preserved" }, seed.preserved)
        XCTAssertEqual(try readJSON(in: h)["schema_version"] as? Int, 2)
    }

    private struct LegacySeed {
        let disk: ManifestSnapshot
        let preserved: SkillOverlay
        let retirement: [String: Any]
    }

    private func seedVersionOne(in h: ManifestSaveFixture) throws -> LegacySeed {
        h.local.name = "Current"
        h.local.skillSlugs = ["alpha", "owed"]
        for slug in ["alpha", "owed"] {
            h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.remoteID, skillSlug: slug, platformRaw: "codex"))
        }
        h.beta.tags = ["local-held"]
        try h.context.save()
        let heldDate = RefusedCreateRecords.writtenDate(h.beta.createdAt)
        var disk = try h.manifest.snapshot(from: h.context)
        let beta = try XCTUnwrap(disk.skills.firstIndex { $0.slug == "beta" })
        disk.skills[beta].createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        disk.skills[beta].tags = ["peer"]
        var owed = disk.skills[beta]
        owed.slug = "owed"
        var preserved = owed
        preserved.slug = "preserved"
        disk.skills += [owed, preserved]
        try h.manifest.write(disk, toRoot: h.root)
        let retirement: [String: Any] = ["slug": "alpha", "fields": [
            "memberships": ["Former"], "intents": [["machine_id": ProjectIntentHarness.remoteID,
                "skill_slug": "alpha", "platform": "codex"]]],
            "category_renames": [["old": "Former", "new": "Current"]]]
        let legacy: [String: Any] = ["schema_version": 1,
            "held": [["slug": "beta", "created_at": heldDate]], "preserved": ["preserved"],
            "retirements": [retirement], "deletions": [["slug": "owed"]]]
        try writeJSON(legacy, in: h)
        return LegacySeed(disk: disk, preserved: preserved, retirement: retirement)
    }

    func testVersionOneDeletionWithAFolderIsStillDroppedOnReopen() async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        _ = try seedRetirement(in: h)
        let before = try h.manifest.read(fromRoot: h.root)
        try writeJSON(["schema_version": 1, "held": [], "preserved": [], "deletions": [["slug": "alpha"]]], in: h)
        h.quit()
        try await h.relaunchThroughRuntime()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), before)
        XCTAssertEqual(try h.manifest.snapshot(from: h.context).skills.first { $0.slug == "alpha" },
                       before.skills.first { $0.slug == "alpha" })
        XCTAssertEqual(try deletionSlugs(in: h), [])
        try publishWindow(in: h)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), before)
    }

    func testAnInvalidPresentDeletionDateMakesTheRecordUnreadable() throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        for invalid: Any in [NSNull(), "not a date", 42] {
            try writeJSON(["schema_version": 2, "held": [], "preserved": [],
                "deletions": [["slug": "alpha", "created_at": invalid]]], in: h)
            XCTAssertThrowsError(try RefusedCreateRecords(path: h.recordPath, files: h.files).read()) { error in
                guard case RefusedCreateRecords.ReadError.unreadable = error else {
                    return XCTFail("Invalid dates must make the file unreadable: \(error)")
                }
            }
        }
    }

    private func writeJSON(_ record: [String: Any], in h: ManifestSaveFixture) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
        try h.files.writeFile(at: h.recordPath, content: try XCTUnwrap(String(data: data, encoding: .utf8)))
    }

    private func readJSON(in h: ManifestSaveFixture) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: h.files.readData(at: h.recordPath)) as? [String: Any])
    }
}
