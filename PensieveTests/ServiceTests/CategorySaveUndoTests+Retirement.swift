import SwiftData
import XCTest
@testable import Pensieve

extension CategorySaveUndoTests {
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

    private func retirementFixture() throws -> ManifestSaveFixture {
        let h = try ManifestSaveFixture(failAlphaDeletion: true)
        h.local.skillSlugs = ["alpha"]
        // Keep the retirement refused even when its membership field is acknowledged by
        // the newer assignment. Deploy intent has its own independent acknowledgement.
        h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.remoteID,
            skillSlug: "alpha", platformRaw: "codex"))
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
                                        file: StaticString = #filePath, line: UInt = #line) {
        let projected = StoreIngestState.shared(for: h.context.container).projectingEdits(onto: durable).snapshot
        XCTAssertEqual(projected.categories.first { $0.name == "Local" }?.skillSlugs, members,
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
