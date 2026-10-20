import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func checkRefusedFieldAcknowledgementDuringRetry() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try NativeTestWork.run {
            try TestPaths.git.initRepository(at: h.root)
            XCTAssertTrue(try TestPaths.git.stageAllAndCommit(at: h.root, message: "seed"))
        }
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: h.root, context: h.context)
        h.recording.failingWrites = 1
        h.library.updateMetadata(h.alpha, tags: ["kept"], scope: .user, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertNotNil(h.library.error)
        try NativeTestWork.run {
            try h.files.writeFile(at: h.root + "/outside.txt", content: "force pre-save ingest")
            XCTAssertTrue(try TestPaths.git.stageAllAndCommit(at: h.root, message: "outside change"))
        }
        var scans = 0
        h.recording.afterRebuildSnapshot = {
            scans += 1
            guard scans <= 2 else { return }
            var pulled = try h.manifest.read(fromRoot: h.root)
            let index = try XCTUnwrap(pulled.skills.firstIndex { $0.slug == "alpha" })
            pulled.skills[index].tags = scans == 1 ? ["kept"] : ["pulled-after-ack"]
            try h.manifest.write(pulled, toRoot: h.root)
            XCTAssertTrue(try TestPaths.git.stageAllAndCommit(at: h.root, message: "outside metadata \(scans)"))
        }
        h.categories.rename(h.local, to: "Saved", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(scans, 3)
        XCTAssertNil(h.saves.categoryNotice)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "alpha" }?.tags, ["pulled-after-ack"])
        XCTAssertEqual(h.alpha.tags, ["pulled-after-ack"], "The retry read acknowledged the refusal before the next pull")
    }

    func testDamageRefusalRetriesWhenRefreshFindsPeerRepair() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let path = h.root + "/manifest/manifest.yaml"
        let healthy = try h.files.readFile(at: path)
        try h.files.writeFile(at: path, content: "damaged")
        await h.saves.refreshDamage()
        XCTAssertTrue(h.saves.libraryDamaged)
        var repaired = false
        h.saves.didReadRepairedLibrary = {
            repaired = true
            let lock = SyncLock.tryAcquire(at: h.lockPath)
            XCTAssertNotNil(lock, "The damaged-save exit must release before its repair callback")
            do {
                try NativeTestWork.run(container: h.context.container) { worker in
                    _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: h.root, context: worker)
                    XCTAssertEqual(Set(try worker.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name)),
                                   ["Retained", "ZDelete"], "Repair callbacks must retain the edit awaiting retry")
                }
            } catch { XCTFail("Repair callback rebuild failed: " + error.localizedDescription) }
            lock?.release()
        }
        h.recording.afterReadFailure = {
            h.recording.afterReadFailure = nil
            try h.files.writeFile(at: path, content: healthy)
        }
        h.categories.rename(h.local, to: "Retained", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertTrue(repaired)
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
            let currentRead = TestWait.Gate(owner: self)
            defer { currentRead.open() }
            let returned = expectation(description: "Superseded refresh returned before the current read")
            returned.isInverted = true
            var releasedCurrentRead = false
            h.recording.afterRead = { try gate.wait() }
            let old = Task {
                await h.saves.refreshDamage()
                if !releasedCurrentRead { returned.fulfill() }
            }
            await TestWait.until(failureMessage: "Old refresh must be in flight") { gate.waiterCount == 1 }
            h.recording.afterRead = nil
            h.recording.afterReadFailure = { try currentRead.wait() }
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged")
            h.saves.acceptLibraryVerdict(newer: newer)
            await TestWait.until(failureMessage: "Current damage read must be held") { currentRead.waiterCount == 1 }
            gate.open()
            await fulfillment(of: [returned], timeout: 0.5) // upper-bound: negative wait; the current read stays gated.
            releasedCurrentRead = true
            currentRead.open()
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

    func testRefusalReportCanAcquireLock() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.alpha.tags = ["refused"]
        try h.context.save()
        h.recording.failingWrites = 1
        var reported = false
        h.saves.submit(.skillMetadata("alpha", ["refused"], nil), context: h.context) { error in
            reported = true
            XCTAssertNotNil(error)
            let lock = SyncLock.tryAcquire(at: h.lockPath)
            XCTAssertNotNil(lock, "Refusal callbacks may start another lock-owning operation")
            XCTAssertEqual(h.saves.refused.count, 1, "The refusal transfers before its report runs")
            lock?.release()
        }
        await h.saves.waitUntilIdle()
        XCTAssertTrue(reported)
        for rebuildFails in [false, true] {
            h.recording.failingRebuildSnapshots = rebuildFails ? 1 : 0
            var completed = false, nudges = 0
            h.saves.didSave = { nudges += 1 }
            h.saves.submit(.skillMetadata("alpha", ["saved"], nil), context: h.context) { error in
                completed = true
                XCTAssertEqual(error != nil, rebuildFails)
                let lock = SyncLock.tryAcquire(at: h.lockPath)
                XCTAssertNotNil(lock, "A published save reports only after releasing its lock")
                lock?.release()
            }
            await h.saves.waitUntilIdle()
            XCTAssertTrue(completed)
            XCTAssertEqual(nudges, 1, "A landed write must nudge sync even when its rebuild failed")
        }
    }

    func testCategoryCompletionCanAcquireLock() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let change = ManifestChange.renameCategory("Local", "Refused")
        let edit = CategorySaveEdit(category: h.local, context: h.context, change: change)
        h.local.name = "Refused"
        try edit.save(in: h.context)
        h.recording.failingWrites = 1
        var reports = 0, reconciled = false
        let report: (Error?) -> Void = { error in
            reports += 1
            XCTAssertNotNil(error)
            XCTAssertEqual(h.local.name, "Local", "Undo lands before reporting")
            let lock = SyncLock.tryAcquire(at: h.lockPath)
            XCTAssertNotNil(lock, "Category refusal reports may start another lock-owning operation")
            if lock != nil {
                do {
                    try NativeTestWork.run(container: h.context.container) { worker in
                        _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: h.root, context: worker)
                        XCTAssertEqual(Set(try worker.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name)),
                                       ["Local", "ZDelete"], "A callback's writer cannot project a refused category edit")
                    }
                } catch { XCTFail("Callback rebuild failed: " + error.localizedDescription) }
            }
            lock?.release()
        }
        h.saves.submit(change, context: h.context, categoryEdit: edit, reconcile: {
            reconciled = true
            let lock = SyncLock.tryAcquire(at: h.lockPath)
            XCTAssertNotNil(lock, "Category reconciliation must run after the save releases its lock")
            lock?.release()
            return BatchResult()
        }, report: report)
        let dependent = ManifestChange.renameCategory("Refused", "Dependent")
        let dependentEdit = CategorySaveEdit(category: h.local, context: h.context, change: dependent)
        h.local.name = "Dependent"
        try dependentEdit.save(in: h.context)
        h.saves.submit(dependent, context: h.context, categoryEdit: dependentEdit, report: report)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(reports, 2, "The dependent refusal must also report after release")
        XCTAssertTrue(reconciled)
    }
}
