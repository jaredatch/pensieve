import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func testOlderDamageRefreshCannotReplaceLaterVerdictOrRead() async throws {
        for laterRead in [false, true] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let gate = TestWait.Gate(owner: self)
            defer { gate.open() }
            h.recording.afterRead = { try gate.wait() }
            let old = Task { await h.saves.refreshDamage() }
            await TestWait.until(failureMessage: "Old refresh never reached its read") { gate.waiterCount == 1 }
            h.recording.afterRead = nil
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "schema_version: 999\n")
            if laterRead { await h.saves.refreshDamage() } else {
                h.library.applySyncCycleOutcome(.storeUnreadable("newer"))
            }
            gate.open()
            await old.value
            XCTAssertTrue(h.library.categoryEditsFenced, "An older read cannot lower the newer-schema fence")
            XCTAssertEqual(h.library.addFenceReason, SkillLibraryViewModel.storeUnreadableMessage)
        }
    }

    func testRepairUsesTheQueuesConfiguredManifestService() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.recording.base = ManifestService(supportedSchemaVersion: 4)
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged")
        await h.saves.refreshDamage()
        h.saves.requestRepair()
        await h.saves.replaceWithThisMac(context: h.context)
        XCTAssertNil(h.saves.repairError)
        XCTAssertEqual(try h.files.readFile(at: h.root + "/manifest/manifest.yaml"), "schema_version: 4\n",
            "Repair must preserve the queue's manifest configuration")
    }
    func testReadableQueuedEditsDoNotHashAnUnusedRepairToken() async throws {
        for pending in [false, true] {
            let files = RebuildReadFileService()
            let h = try ManifestSaveFixture(rebuildFiles: files)
            defer { h.cleanup() }
            let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { held.release() }
            if pending { StoreIngestState.shared(for: h.context.container).invalidate() }
            h.categories.rename(h.local, to: "Waiting", context: h.context)
            await h.saves.refreshDamage()
            XCTAssertFalse(h.saves.libraryDamaged)
            XCTAssertEqual(files.entryObservations.value, 0, "A readable manifest needs no repair token")
            held.release()
            await h.saves.waitUntilIdle()
        }
    }

    func testRepairTokenTakesTypeAndMetadataFromOneEntryObservation() async throws {
        let files = RebuildReadFileService()
        let h = try ManifestSaveFixture(rebuildFiles: files)
        defer { h.cleanup() }
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged")
        let before = files.separateTypeReads.value
        _ = ManifestDamage.capture(root: h.root, files: files)
        XCTAssertGreaterThan(files.entryObservations.value, 0, "The offer must observe its entries")
        XCTAssertEqual(files.separateTypeReads.value, before,
            "A second type probe could describe a different inode from the token's metadata")
    }

}
