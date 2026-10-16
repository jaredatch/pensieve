import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func testDamageRefusalRetriesWhenRefreshFindsPeerRepair() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let path = h.root + "/manifest/manifest.yaml"
        let healthy = try h.files.readFile(at: path)
        try h.files.writeFile(at: path, content: "damaged")
        h.recording.afterReadFailure = {
            h.recording.afterReadFailure = nil
            try h.files.writeFile(at: path, content: healthy)
        }
        h.categories.rename(h.local, to: "Retained", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.saves.pendingCount, 0, "Readable refresh must retry the refused head without another event")
        XCTAssertFalse(h.saves.pausedForRepair)
        XCTAssertFalse(h.saves.showsDamageAlert)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.first { $0.name == "Retained" }?.name, "Retained")
    }

    func testVerdictSupersedingDamageReadSchedulesCurrentDiskObservation() async throws {
        for newer in [false, true] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let gate = TestWait.Gate(owner: self)
            defer { gate.open() }
            h.recording.afterRead = { try gate.wait() }
            let old = Task { await h.saves.refreshDamage() }
            await TestWait.until(failureMessage: "Old refresh must be in flight") { gate.waiterCount == 1 }
            h.recording.afterRead = nil
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged")
            h.saves.acceptLibraryVerdict(newer: newer)
            gate.open()
            await old.value
            await TestWait.until(failureMessage: "A verdict must replace the invalidated damage observation") {
                h.saves.libraryDamaged && h.saves.requiresNewerVersion == false
            }
            h.saves.requestRepair()
            XCTAssertTrue(h.saves.showsRepairConfirmation)
        }
    }

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
