import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func testDamagedManifestKeepsEditsUntilConfirmedRepair() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try await assertReadableSaveDoesNotFetchFallback(h)
        let corruptLock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { corruptLock.release() }
        h.categories.rename(h.local, to: "Healed", context: h.context)
        h.library.updateMetadata(h.alpha, tags: ["latest"], scope: .project, context: h.context)
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "not: [yaml\n")
        var reports: [Error?] = []
        h.saves.submit(.skillMetadata("alpha", nil, nil), context: h.context) { reports.append($0) }
        corruptLock.release()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.files.readFile(at: h.root + "/manifest/manifest.yaml"), "not: [yaml\n")
        XCTAssertEqual(h.local.name, "Healed")
        XCTAssertEqual(h.alpha.tags, ["latest"])
        XCTAssertEqual(h.saves.pendingCount, 3)
        XCTAssertTrue(h.saves.showsDamageAlert)
        XCTAssertEqual(ManifestSaveModel.damageTitle, "The synced library file is damaged")
        XCTAssertEqual(ManifestSaveModel.repairAction, "Replace with This Mac's Library…")
        XCTAssertNil(h.saves.categoryNotice)
        XCTAssertFalse(h.library.categoryEditsFenced, "Damage must leave category edits available")
        XCTAssertTrue(h.library.addsFenced, "Damage still fences adds")
        XCTAssertEqual(h.library.addFenceReason,
            "Pensieve can't add to this library until the damaged library file is repaired.")
        XCTAssertTrue(reports.isEmpty, "A repair pause is not a completed edit report")
        h.saves.submit(.skillMetadata("alpha", nil, nil), context: h.context) { _ in }
        await h.saves.waitUntilIdle()
        XCTAssertTrue(reports.isEmpty, "Repeated pauses must not report waiting edits")
        let expected = try await assertCategoryChangesWaitForRepair(h)
        let before = try h.manifestBytes()
        h.saves.requestRepair()
        h.saves.cancelRepair()
        XCTAssertFalse(h.saves.showsRepairConfirmation)
        XCTAssertEqual(try h.manifestBytes(), before, "Cancel changes no manifest bytes")
        h.saves.requestRepair()
        await h.saves.replaceWithThisMac(context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.saves.repairError)
        XCTAssertEqual(h.saves.pendingCount, 0)
        let saved = try h.manifest.read(fromRoot: h.root)
        XCTAssertEqual(saved.categories, expected.categories.sorted { $0.name < $1.name })
        XCTAssertEqual(saved.skills, expected.skills.sorted { $0.slug < $1.slug })
        XCTAssertNil(h.library.error)
        XCTAssertEqual(reports.count, 1, "Each completed edit reports once")
        XCTAssertNil(reports.first ?? nil)
        XCTAssertFalse(h.library.addsFenced, "Local repair lifts the damage fence without sync")
    }

    private func assertCategoryChangesWaitForRepair(_ h: ManifestSaveFixture) async throws -> ManifestSnapshot {
        h.categories.setSkill(h.alpha, inCategory: h.local, assigned: true, context: h.context)
        h.categories.setProject(h.project, inCategory: h.local, member: true, context: h.context)
        h.categories.delete(h.doomed, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.saves.pendingCount, 7, "Membership and removal wait alongside rename and skill edits")
        XCTAssertEqual(h.local.skillSlugs, ["alpha"])
        XCTAssertEqual(h.local.projectKeys, ["local-key"])
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name), ["Healed"])
        XCTAssertNil(h.saves.categoryNotice)
        return try h.manifest.snapshot(from: h.context)
    }

    private func assertReadableSaveDoesNotFetchFallback(_ h: ManifestSaveFixture) async throws {
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        h.recording.failingSnapshots = 1
        h.library.updateMetadata(h.alpha, tags: ["readable"], scope: .user, context: h.context)
        lock.release()
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.library.error, "A readable manifest must not fetch the unused fallback")
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "alpha" }?.tags, ["readable"])
        h.recording.failingSnapshots = 0
    }

    func testMissingManifestCreatesUnlessIngestIsPending() async throws {
        for pending in [false, true] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            try h.files.deleteDirectory(at: h.root + "/manifest")
            if pending { StoreIngestState.shared(for: h.context.container).invalidate() }
            h.categories.rename(h.local, to: "Waiting", context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertEqual(h.files.fileExists(at: h.root + "/manifest/manifest.yaml"), !pending)
            XCTAssertEqual(h.local.name, "Waiting")
            XCTAssertEqual(h.saves.showsDamageAlert, pending)
            if pending {
                h.saves.requestRepair()
                await h.saves.replaceWithThisMac(context: h.context)
                await h.saves.waitUntilIdle()
                XCTAssertNil(h.saves.repairError)
            }
            XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.map(\.name), ["Waiting", "ZDelete"])
        }
    }

    func testRepairRejectsChangedDamageAndReadableReplacement() async throws {
        for becomesReadable in [false, true] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "first damage")
            h.categories.rename(h.local, to: "Waiting", context: h.context)
            await h.saves.waitUntilIdle()
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml",
                content: becomesReadable ? "schema_version: 5\n" : "different damage")
            if becomesReadable {
                var peer = try h.manifest.read(fromRoot: h.root)
                peer.categories.append(CategoryRecord(name: "Peer", projectKeys: [], skillSlugs: []))
                try h.manifest.write(peer, toRoot: h.root)
            }
            await h.saves.refreshDamage()
            h.saves.requestRepair()
            let before = try h.manifestBytes()
            await h.saves.replaceWithThisMac(context: h.context)
            await h.saves.waitUntilIdle()
            if becomesReadable {
                XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.map(\.name), ["Peer", "Waiting", "ZDelete"],
                    "A readable replacement keeps peer state and merges the waiting edit normally")
            } else {
                XCTAssertEqual(try h.manifestBytes(), before, "Stale confirmation grants no write authority")
                XCTAssertEqual(h.saves.pendingCount, 1)
                XCTAssertTrue(h.saves.libraryDamaged)
                XCTAssertEqual(h.saves.repairError, "The library file changed. Review the repair again.")
                XCTAssertTrue(h.saves.showsDamageAlert, "Changed damage must offer repair again")
                h.saves.requestRepair()
                await h.saves.replaceWithThisMac(context: h.context)
                await h.saves.waitUntilIdle()
                XCTAssertNil(h.saves.repairError)
                XCTAssertEqual(h.saves.pendingCount, 0, "The refreshed offer can repair the current file")
            }
        }
        try await assertNewerReplacementKeepsItsFence()
    }

    private func assertNewerReplacementKeepsItsFence() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged")
        h.categories.rename(h.local, to: "Waiting", context: h.context)
        await h.saves.waitUntilIdle()
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "schema_version: 999\n")
        h.saves.requestRepair()
        await h.saves.replaceWithThisMac(context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.files.readFile(at: h.root + "/manifest/manifest.yaml"), "schema_version: 999\n")
        XCTAssertTrue(h.library.categoryEditsFenced, "A newer replacement retains the newer-schema fence")
        XCTAssertTrue(h.library.addsFenced)
        XCTAssertEqual(h.library.addFenceReason, SkillLibraryViewModel.storeUnreadableMessage)
        XCTAssertEqual(h.local.name, "Local", "Newer-schema refusal keeps ordinary category undo")
    }

    func testRepairWaitsForAnotherProcessAndWriteFailureKeepsDamage() async throws {
        let files = RebuildReadFileService()
        let h = try ManifestSaveFixture(rebuildFiles: files)
        defer { h.cleanup() }
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged")
        h.library.updateMetadata(h.alpha, tags: ["Waiting"], scope: .user, context: h.context)
        await h.saves.waitUntilIdle()
        let before = try h.manifestBytes()
        // A native subprocess owns the same advisory lock, rather than a mock lock answer.
        let holder = try ExternalSyncLockHolder(path: h.lockPath)
        defer { holder.release() }
        h.saves.requestRepair()
        let repair = Task { await h.saves.replaceWithThisMac(context: h.context) }
        await TestWait.until(failureMessage: "Repair did not wait for the held lock") { h.saves.isWaiting }
        XCTAssertEqual(h.saves.statusMessage, "Your change will save when sync finishes.")
        XCTAssertTrue(h.saves.hasActiveSaves, "Confirmed repair is actively saving for Quit")
        XCTAssertEqual(try h.manifestBytes(), before)
        files.refuseReplacement = true
        holder.release()
        await repair.value
        XCTAssertNotNil(h.saves.repairError)
        XCTAssertEqual(try h.manifestBytes(), before, "Failed repair must leave the old tree intact")
        XCTAssertEqual(h.alpha.tags, ["Waiting"])
        XCTAssertEqual(h.saves.pendingCount, 1)
        XCTAssertTrue(h.saves.libraryDamaged)
        files.refuseReplacement = false
        h.saves.requestRepair()
        await h.saves.replaceWithThisMac(context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.saves.repairError)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "alpha" }?.tags, ["Waiting"])
    }

    func testDamagedFooterStaysMountedWithoutSyncOrQueuedSaveUntilRepairSucceeds() async throws {
        let files = RebuildReadFileService()
        let h = try ManifestSaveFixture(rebuildFiles: files)
        defer { h.cleanup() }
        let sync = SyncModel(git: TestPaths.git, root: h.root, initialState: .unconfigured)
        XCTAssertFalse(sync.showsFooter(saves: h.saves), "No remote or waiting save means no healthy footer")
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged")
        await h.saves.refreshAndRetry()
        XCTAssertEqual(h.saves.pendingCount, 0)
        XCTAssertFalse(h.saves.isWaiting)
        XCTAssertTrue(sync.showsFooter(saves: h.saves), "Damage must mount repair without sync or a queued save")
        let line = try XCTUnwrap(SyncFooterPresentation.make(state: sync.state, canResolve: sync.canResolve,
            hovering: true, now: Date(), libraryDamaged: h.saves.libraryDamaged))
        XCTAssertEqual(line.label, "Repair…")
        XCTAssertEqual(line.action, .repair)
        h.saves.requestRepair()
        XCTAssertTrue(h.saves.showsRepairConfirmation)
        h.saves.cancelRepair()
        XCTAssertTrue(sync.showsFooter(saves: h.saves), "Cancel must keep the repair entry available")
        files.refuseReplacement = true
        h.saves.requestRepair()
        await h.saves.replaceWithThisMac(context: h.context)
        XCTAssertNotNil(h.saves.repairError)
        XCTAssertFalse(h.saves.isWaiting)
        XCTAssertTrue(sync.showsFooter(saves: h.saves), "Failed repair must keep the repair entry available")
        files.refuseReplacement = false
        h.saves.requestRepair()
        await h.saves.replaceWithThisMac(context: h.context)
        XCTAssertNil(h.saves.repairError)
        XCTAssertFalse(h.saves.libraryDamaged)
        XCTAssertFalse(sync.showsFooter(saves: h.saves), "Successful repair restores the absent no-remote footer")
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        h.categories.rename(h.local, to: "Waiting", context: h.context)
        await TestWait.until(failureMessage: "Save did not wait for the held lock") { h.saves.isWaiting }
        XCTAssertTrue(sync.showsFooter(saves: h.saves), "A waiting save still mounts the no-remote footer")
        lock.release()
        await h.saves.waitUntilIdle()
        XCTAssertFalse(sync.showsFooter(saves: h.saves))
    }

    func testDamagedFooterOffersSameConfirmationAfterRelaunchRead() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged")
        await h.saves.refreshAndRetry()
        for hovering in [false, true] {
            let line = try XCTUnwrap(SyncFooterPresentation.make(state: .error("failure"), canResolve: false,
                hovering: hovering, now: Date(), libraryDamaged: h.saves.libraryDamaged))
            XCTAssertEqual(line.label, hovering ? "Repair…" : "Library file damaged")
            XCTAssertEqual(line.action, .repair)
        }
        h.saves.requestRepair()
        XCTAssertTrue(h.saves.showsRepairConfirmation)
        XCTAssertEqual(ManifestSaveModel.repairTitle, "Replace the synced library with this Mac's?")
        h.saves.cancelRepair()
        XCTAssertTrue(h.saves.libraryDamaged)
    }
}
