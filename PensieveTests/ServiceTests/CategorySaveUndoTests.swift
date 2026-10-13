import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class CategorySaveUndoTests: XCTestCase {
    func testRefusedRenameRestoresNameForNewerSchemaLockWriteAndFallbackRead() async throws {
        for refusal in ["newer schema", "lock", "write", "snapshot"] {
            let h = try ManifestSaveFixture(unopenableLock: refusal == "lock")
            defer { h.cleanup() }
            let id = h.local.id
            if refusal == "newer schema" {
                try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "schema_version: 99\n")
            } else if refusal == "write" {
                h.recording.failingWrites = 1
            } else if refusal == "snapshot" {
                try h.files.deleteDirectory(at: h.root + "/manifest")
                h.recording.failingSnapshots = 1
            }
            h.categories.rename(h.local, to: "Drafts", context: h.context)
            await h.saves.waitUntilIdle()
            let category = try XCTUnwrap(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.id == id })
            XCTAssertEqual(category.name, "Local", refusal)
        }
        try await checkRefusalHoldsLockThroughUndoSave()
        try await checkFailedCategoryFetch()
        try await checkEditAfterRebuildFetch(["rename", "rename-after-save"])
        try await checkEditBetweenManifestReadAndCategoryFetch()
        try await checkPriorSaveAfterPullDoesNotAcknowledgeRefusal()
        try await checkUnrelatedCategoryDoesNotAcknowledgeRename()
        try await checkRefusalAcrossSync(["rename-peer", "rename-plain", "rename-normal", "rename-peer-after-save",
                                         "rename-published-lock", "rename-dependent-published-lock"])
        try await checkRefusalAfterPulledDeletion(fields: ["name"])
    }

    func testRefusedCreateAndDependentRenameLeaveNoCategory() async throws {
        let h = try ManifestSaveFixture(unopenableLock: true)
        defer { h.cleanup() }
        let created = try XCTUnwrap(h.categories.create(name: "Writing", context: h.context))
        let id = created.id
        h.categories.rename(created, to: "Drafts", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).contains { $0.id == id })
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.map(\.name), ["Local", "ZDelete"])
        try await checkEditAfterRebuildFetch(["create"])
        try await checkRefusedCreateAfterPulledRebuild()
        try await checkRefusalAcrossSync(["create-peer", "create-schema"])
    }

    func testDependentRenamesUndoInReverseOrderIncludingRestoredName() async throws {
        for claimedName in ["Writing", " WRITING ", "writing"] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let recorder = ConvergenceRecorder()
            let store = CategoryStore(manifestSaves: h.saves,
                reconciler: ConvergenceRecordingLedger(name: "category", recorder: recorder))
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { lock.release() }
            h.local.name = "Writing"
            h.doomed.name = "Spare"
            try h.context.save()
            try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
            h.recording.failingWrites = 1
            store.rename(h.local, to: "Drafts", context: h.context)
            store.rename(h.doomed, to: claimedName, context: h.context)
            store.rename(h.local, to: "Final", context: h.context)
            store.setSkill(h.alpha, inCategory: h.local, assigned: true, context: h.context)
            lock.release()
            await h.saves.waitUntilIdle()
            XCTAssertEqual(recorder.observedCategoryNames.sorted(), ["Spare", "Writing"],
                           "Deployment convergence must see the completed undo, with no taken name or intermediate rule")
            let rows = try h.context.fetch(FetchDescriptor<Pensieve.Category>())
            XCTAssertEqual(rows.first { $0.id == h.local.id }?.name, "Writing")
            XCTAssertEqual(rows.first { $0.id == h.doomed.id }?.name, "Spare")
            XCTAssertTrue(rows.first { $0.id == h.local.id }?.skillSlugs.isEmpty == true)
            XCTAssertEqual(h.recording.writes.count, 0, "Dependent saves must not publish")
            XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.map(\.name), ["Spare", "Writing"])
            XCTAssertEqual(try XCTUnwrap(h.saves.categoryNotice).messages.count, 4)
        }
    }
}
