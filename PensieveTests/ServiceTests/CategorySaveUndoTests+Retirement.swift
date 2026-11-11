import SwiftData
import XCTest
@testable import Pensieve

extension CategorySaveUndoTests {
    func testTwoQuickRenamesThatSwapANameKeepAFailedSkillDeletionOwed() async throws {
        for swap in [true, false] {
            let h = try retirementFixture(remoteIntent: false, persistent: swap)
            defer { h.cleanup() }
            h.recording.failingWrites = 1
            refuseSkillDeletion(h)
            await h.saves.waitUntilIdle()
            XCTAssertTrue(h.library.error?.contains("updating the sync manifest failed") == true)
            XCTAssertEqual(h.saves.refused.count, 1)
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { lock.release() }
            let name = swap ? "ZDelete" : "Renamed"
            if swap {
                let before = try h.manifestBytes()
                h.categories.rename(h.doomed, to: "Archive", context: h.context)
                h.categories.rename(h.local, to: name, context: h.context)
                await h.assertWaitingBehindHeldLock(pending: 2, before: before)
            } else {
                var peer = try h.manifest.read(fromRoot: h.root)
                let index = try XCTUnwrap(peer.categories.firstIndex { $0.name == "Local" })
                peer.categories[index].name = name
                try h.manifest.write(peer, toRoot: h.root)
                h.categories.rename(h.local, to: name, context: h.context)
            }
            lock.release()
            await h.saves.waitUntilIdle()
            XCTAssertEqual(h.recording.writes.count, swap ? 2 : 0)
            let durable = try h.manifest.read(fromRoot: h.root)
            XCTAssertEqual(durable.categories.first { $0.name == name }?.skillSlugs, ["alpha"])
            XCTAssertEqual(h.saves.refused.count, 1)
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: h.root, context: h.context)
            XCTAssertEqual(h.local.name, name)
            XCTAssertEqual(h.local.skillSlugs, [])
            assertWorkerMembership(h, durable: durable, members: [], category: name)
            if swap {
                XCTAssertEqual(durable.categories.first { $0.name == "Archive" }?.skillSlugs, [])
                XCTAssertEqual(h.doomed.name, "Archive")
                XCTAssertEqual(h.doomed.skillSlugs, [])
                try await assertSwapRetirementSurvivesRelaunch(h)
            }
            h.categories.setSkill(h.alpha, inCategory: h.local, assigned: true, context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertTrue(h.saves.refused.isEmpty, "A published re-add must settle the renamed membership")
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: h.root, context: h.context)
            XCTAssertEqual(h.local.skillSlugs, ["alpha"])
        }
    }

    private func assertSwapRetirementSurvivesRelaunch(_ h: ManifestSaveFixture) async throws {
        let before = try h.manifestBytes()
        try await h.relaunchThroughRuntime()
        let rows = try h.context.fetch(FetchDescriptor<Pensieve.Category>())
        h.currentLocal = try XCTUnwrap(rows.first { $0.name == "ZDelete" })
        XCTAssertEqual(h.saves.refused.count, 1)
        XCTAssertEqual(h.local.skillSlugs, [])
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.first { $0.name == "ZDelete" }?.skillSlugs,
                       ["alpha"])
        XCTAssertEqual(try h.manifestBytes(), before, "Startup must preserve the synced manifest bytes")
    }

    func testACategoryRenamedAfterAFailedSkillDeletionKeepsTheSkillOutOnceTheRenameSaves() async throws {
        let h = try retirementFixture(remoteIntent: false)
        defer { h.cleanup() }
        h.recording.failingWrites = 1
        refuseSkillDeletion(h)
        await h.saves.waitUntilIdle()
        XCTAssertTrue(h.library.error?.contains("updating the sync manifest failed") == true)
        var expected = try h.manifest.read(fromRoot: h.root)
        let original = try XCTUnwrap(expected.categories.firstIndex { $0.name == "Local" })
        expected.categories[original].name = "Renamed"
        h.categories.rename(h.local, to: "Renamed", context: h.context)
        await h.saves.waitUntilIdle()

        _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: h.root, context: h.context)
        XCTAssertEqual(h.local.name, "Renamed")
        XCTAssertEqual(h.local.skillSlugs, [])
        var durable = try h.manifest.read(fromRoot: h.root)
        assertWorkerMembership(h, durable: durable, members: [], category: "Renamed")
        XCTAssertEqual(h.saves.refused.count, 1)
        XCTAssertEqual(durable.categories.first { $0.name == "Renamed" }?.skillSlugs, ["alpha"])
        XCTAssertEqual(h.recording.writes, [expected], "Only the rename publishes, preserving all other durable fields")

        let replacement = try XCTUnwrap(h.categories.create(name: "Local", context: h.context))
        h.categories.setSkill(h.alpha, inCategory: replacement, assigned: true, context: h.context)
        await h.saves.waitUntilIdle()
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: h.root, context: h.context)
        XCTAssertEqual(replacement.skillSlugs, ["alpha"])
        XCTAssertEqual(h.local.skillSlugs, [])
        XCTAssertEqual(h.saves.refused.count, 1, "A re-add to the replacement does not settle the renamed category")

        durable = try h.manifest.read(fromRoot: h.root)
        let index = try XCTUnwrap(durable.categories.firstIndex { $0.name == "Renamed" })
        durable.categories[index].skillSlugs = []
        try h.manifest.write(durable, toRoot: h.root)
        h.library.updateMetadata(h.beta, tags: ["later"], scope: .user, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertTrue(h.saves.refused.isEmpty, "The real durable removal settles the owed deletion")
    }

    func testPuttingADeletedSkillBackSettlesTheDeletionOnlyWhenThatSaveGoesThrough() async throws {
        for outcome in ["undone", "undone with pending rename", "saved"] {
            let h = try retirementFixture(remoteIntent: false)
            defer { h.cleanup() }
            if outcome != "saved" {
                try await checkUndoneReassignment(h, pendingRename: outcome == "undone with pending rename")
                continue
            }
            h.recording.failingWrites = 1
            refuseSkillDeletion(h)
            await h.saves.waitUntilIdle()
            XCTAssertTrue(h.library.error?.contains("updating the sync manifest failed") == true)
            h.categories.setSkill(h.alpha, inCategory: h.local, assigned: true, context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertTrue(h.saves.refused.isEmpty, "A published re-add settles the owed deletion")
            XCTAssertEqual(h.local.skillSlugs, ["alpha"])
            XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.first { $0.name == "Local" }?.skillSlugs,
                           ["alpha"])
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: h.root, context: h.context)
            XCTAssertEqual(h.local.skillSlugs, ["alpha"])
        }
    }

    private func checkUndoneReassignment(_ h: ManifestSaveFixture, pendingRename: Bool) async throws {
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        let before = try h.manifestBytes()
        refuseSkillDeletion(h)
        h.categories.setSkill(h.alpha, inCategory: h.local, assigned: true, context: h.context)
        if pendingRename { h.categories.rename(h.local, to: "Renamed", context: h.context) }
        await h.assertWaitingBehindHeldLock(pending: pendingRename ? 3 : 2, before: before)
        h.recording.failingWrites = 1
        h.recording.afterRead = {
            h.recording.afterRead = nil
            try h.files.deleteFile(at: h.lockPath)
            try h.files.createDirectory(at: h.lockPath)
        }
        lock.release()
        await h.saves.waitUntilIdle()
        XCTAssertTrue(h.library.error?.contains("updating the sync manifest failed") == true)
        XCTAssertEqual(h.saves.refused.count, 1)
        XCTAssertEqual(h.local.name, "Local")
        XCTAssertEqual(h.local.skillSlugs, [])
        let notice = try XCTUnwrap(h.saves.categoryNotice)
        XCTAssertTrue(notice.message.contains("undone"))
        XCTAssertFalse(notice.message.contains("already saved"))
        XCTAssertTrue(h.recording.writes.isEmpty)
        XCTAssertEqual(try h.manifestBytes(), before)
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: h.root, context: h.context)
        XCTAssertEqual(h.local.skillSlugs, [])
        let durable = try h.manifest.read(fromRoot: h.root)
        assertWorkerMembership(h, durable: durable, members: [])
        XCTAssertEqual(durable.categories.first { $0.name == "Local" }?.skillSlugs, ["alpha"])
    }

    func testACategoryRenamedAfterAFailedSkillDeletionKeepsTheSkillYouAddedWhenTheRenameIsUndone() async throws {
        let h = try retirementFixture()
        defer { h.cleanup() }
        let id = h.local.id
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        let before = try h.manifestBytes()
        refuseSkillDeletion(h)
        h.categories.setSkill(h.alpha, inCategory: h.local, assigned: true, context: h.context)
        h.categories.rename(h.local, to: "Renamed", context: h.context)
        await h.assertWaitingBehindHeldLock(pending: 3, before: before)
        failRetirementAndCategoryEdit(h)
        lock.release()
        await h.saves.waitUntilIdle()

        let restored = try retirementCategory(id, h: h)
        XCTAssertEqual(restored.name, "Local")
        XCTAssertEqual(restored.skillSlugs, ["alpha"], "The assignment after deletion must survive rename undo")
        let durable = try h.manifest.read(fromRoot: h.root)
        XCTAssertEqual(durable.categories.first { $0.name == "Local" }?.skillSlugs, ["alpha"])
        XCTAssertFalse(durable.categories.contains { $0.name == "Renamed" })
        assertWorkerMembership(h, durable: durable, members: ["alpha"])
        XCTAssertEqual(h.recording.writes.count, 1, "Only the assignment publishes")
        try assertRetirementAndUndo(h)
    }

    func testACategoryDeletedAfterAFailedSkillDeletionKeepsTheSkillYouAddedWhenTheDeleteIsUndone() async throws {
        try await checkCategoryDeleteUndoKeepsNewerAssignment()
    }

    private func checkCategoryDeleteUndoKeepsNewerAssignment() async throws {
        let h = try retirementFixture()
        defer { h.cleanup() }
        let id = h.local.id
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        let before = try h.manifestBytes()
        refuseSkillDeletion(h)
        h.categories.setSkill(h.alpha, inCategory: h.local, assigned: true, context: h.context)
        h.categories.delete(h.local, context: h.context)
        await h.assertWaitingBehindHeldLock(pending: 3, before: before)
        failRetirementAndCategoryEdit(h)
        lock.release()
        await h.saves.waitUntilIdle()

        let restored = try retirementCategory(id, h: h)
        XCTAssertEqual(restored.name, "Local")
        XCTAssertEqual(restored.skillSlugs, ["alpha"], "The assignment after deletion must survive category delete undo")
        assertWorkerMembership(h, durable: try h.manifest.read(fromRoot: h.root), members: ["alpha"])
        XCTAssertEqual(h.recording.writes.count, 1, "Only the assignment publishes")
        try assertRetirementAndUndo(h)
    }

    func testACategoryDeletedBeforeAFailedSkillDeletionDoesNotGetTheSkillBackWhenTheDeleteIsUndone() async throws {
        let h = try retirementFixture()
        defer { h.cleanup() }
        let id = h.local.id
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        let before = try h.manifestBytes()
        h.categories.delete(h.local, context: h.context)
        refuseSkillDeletion(h)
        await h.assertWaitingBehindHeldLock(pending: 2, before: before)
        h.recording.failingWrites = 2
        lock.release()
        await h.saves.waitUntilIdle()

        let restored = try retirementCategory(id, h: h)
        XCTAssertEqual(restored.name, "Local")
        XCTAssertTrue(restored.skillSlugs.isEmpty, "Undo must not revive membership captured before skill deletion")
        let durable = try h.manifest.read(fromRoot: h.root)
        XCTAssertEqual(durable.categories.first { $0.name == "Local" }?.skillSlugs, ["alpha"])
        var projected = durable
        for edit in h.saves.refused { edit.project(onto: &projected) }
        XCTAssertEqual(projected.categories.first { $0.name == "Local" }?.skillSlugs, [],
                       "The old membership must remain an unacknowledged retirement field")
        XCTAssertTrue(h.recording.writes.isEmpty)
        assertWorkerMembership(h, durable: durable, members: [])
        try assertRetirementAndUndo(h)

        // Pair the older-membership constraint with the assignment loss this update fixes,
        // so this check also fails on code that already handles the older capture correctly.
        try await checkCategoryDeleteUndoKeepsNewerAssignment()
    }

    private func retirementFixture(remoteIntent: Bool = true, persistent: Bool = false) throws -> ManifestSaveFixture {
        let h = try ManifestSaveFixture(failAlphaDeletion: true, persistent: persistent)
        h.local.skillSlugs = ["alpha"]
        // Keep the retirement refused even when its membership field is acknowledged by
        // the newer assignment. Deploy intent has its own independent acknowledgement.
        if remoteIntent {
            h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.remoteID,
                skillSlug: "alpha", platformRaw: "codex"))
        }
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
        return h
    }

    private func refuseSkillDeletion(_ h: ManifestSaveFixture) {
        XCTAssertFalse(SkillDeletionFlow.delete(skill: h.alpha, library: h.library, platformVM: h.platform,
            projects: [], context: h.context))
    }

    private func failRetirementAndCategoryEdit(_ h: ManifestSaveFixture) {
        h.recording.failingWrites = 1
        let recording = h.recording
        recording.afterWrite = { [weak recording] in
            recording?.failingWrites = 1
            recording?.afterWrite = nil
        }
    }

    private func retirementCategory(_ id: UUID, h: ManifestSaveFixture) throws -> Pensieve.Category {
        try XCTUnwrap(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.id == id })
    }

    private func assertWorkerMembership(_ h: ManifestSaveFixture, durable: ManifestSnapshot, members: [String],
                                        category: String = "Local",
                                        file: StaticString = #filePath, line: UInt = #line) {
        let projected = StoreIngestState.shared(for: h.context.container).projectingEdits(onto: durable).snapshot
        XCTAssertEqual(projected.categories.first { $0.name == category }?.skillSlugs, members,
                       "Worker rebuilds must agree with the window after undo", file: file, line: line)
    }

    private func assertRetirementAndUndo(_ h: ManifestSaveFixture,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<Skill>()).contains { $0.id == h.alpha.id }, file: file, line: line)
        XCTAssertTrue(h.files.directoryExists(at: h.root + "/skills/alpha"), file: file, line: line)
        XCTAssertTrue(h.library.error?.contains("updating the sync manifest failed") == true, file: file, line: line)
        XCTAssertEqual(h.saves.refused.count, 1, file: file, line: line)
        let notice = try XCTUnwrap(h.saves.categoryNotice, file: file, line: line)
        XCTAssertEqual(notice.entries.count, 1, file: file, line: line)
        XCTAssertTrue(notice.message.contains("“Local”"), file: file, line: line)
        XCTAssertTrue(notice.message.contains("undone"), file: file, line: line)
        XCTAssertFalse(notice.message.contains("already saved"), file: file, line: line)
    }
}
