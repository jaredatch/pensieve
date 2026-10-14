import SwiftData
import XCTest
@testable import Pensieve

extension CategoryStoreTests {
    @MainActor
    func testTakenNamesRefuseCreateAndRenameWithoutSaving() async throws {
        for name in ["Local", "LOCAL", "local", " \tLoCaL\n"] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let before = try h.manifestBytes()
            let window = try h.manifest.snapshot(from: h.context)
            var notifications = 0
            XCTAssertNil(h.categories.create(name: name, context: h.context, notifier: { notifications += 1 }))
            h.categories.rename(h.doomed, to: name, context: h.context, notifier: { notifications += 1 })
            XCTAssertEqual(h.saves.pendingCount, 0, name)
            XCTAssertEqual(notifications, 0, name)
            XCTAssertEqual(try h.manifest.snapshot(from: h.context), window, name)
            await h.saves.waitUntilIdle()
            XCTAssertTrue(h.recording.writes.isEmpty, name)
            XCTAssertEqual(try h.manifestBytes(), before, name)
        }
    }

    @MainActor
    func testRenameTrimsAllowsOwnCaseAndSkipsUnchangedAndBlankNames() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.categories.rename(h.local, to: " \tlocal\n", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.local.name, "local")
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.map(\.name), ["ZDelete", "local"])
        XCTAssertEqual(h.recording.writes.count, 1)
        let before = try h.manifestBytes()
        var notifications = 0
        for name in ["local", " local ", " \t\n"] {
            h.categories.rename(h.local, to: name, context: h.context, notifier: { notifications += 1 })
            XCTAssertEqual(h.saves.pendingCount, 0, name)
        }
        await h.saves.waitUntilIdle()
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(h.local.name, "local")
        XCTAssertEqual(h.recording.writes.count, 1)
        XCTAssertEqual(try h.manifestBytes(), before)
    }

    @MainActor
    func testOwnCaseRenameRefusesAnotherLegacyMatchingRow() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let duplicate = Pensieve.Category(name: " LOCAL ")
        duplicate.projectKeys = ["legacy-key"]
        h.context.insert(duplicate)
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
        let before = try h.manifestBytes()
        h.categories.rename(h.local, to: "lOcAl", context: h.context)
        XCTAssertEqual(h.saves.pendingCount, 0)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.local.name, "Local")
        XCTAssertEqual(duplicate.name, " LOCAL ")
        XCTAssertEqual(duplicate.projectKeys, ["legacy-key"])
        XCTAssertTrue(h.recording.writes.isEmpty)
        XCTAssertEqual(try h.manifestBytes(), before)
    }

    @MainActor
    func testQueuedRenameRefusesTakenDiskNameWithoutMergingRecords() async throws {
        for peerName in ["Drafts", "DRAFTS", " drafts "] {
            for (rebuild, precedingSaves) in [(false, 0), (true, 0), (false, 1), (false, 2)] {
                try await checkQueuedRename(peerName, rebuild: rebuild, precedingSaves: precedingSaves)
            }
        }
    }

    @MainActor
    private func checkQueuedRename(_ peerName: String, rebuild: Bool, precedingSaves: Int) async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        h.local.projectKeys = ["local-key"]
        h.local.skillSlugs = ["alpha"]
        try h.context.save()
        h.recording.sortRebuildCategories = true
        if precedingSaves > 0 {
            h.library.updateMetadata(h.alpha, tags: ["head"], scope: .user, context: h.context)
        }
        if precedingSaves > 1 {
            h.library.updateMetadata(h.beta, tags: ["second"], scope: .user, context: h.context)
        }
        h.categories.rename(h.local, to: "Drafts", context: h.context)
        var disk = try h.manifest.read(fromRoot: h.root)
        disk.categories = [
            CategoryRecord(name: "Local", projectKeys: ["local-key"], skillSlugs: ["alpha"]),
            CategoryRecord(name: peerName, projectKeys: ["peer-key"], skillSlugs: ["beta"])
        ]
        try h.manifest.write(disk, toRoot: h.root)
        if rebuild {
            let syncContext = ModelContext(h.context.container)
            _ = try StoreRebuildService().rebuild(fromRoot: h.root, context: syncContext)
        }
        let before = try h.manifestBytes()
        held.release()
        await h.saves.waitUntilIdle()
        try assertQueuedRenameRefusal(h, disk: disk, peerName: peerName, before: before,
                                     rebuild: rebuild, precedingSaves: precedingSaves)
    }

    @MainActor
    private func assertQueuedRenameRefusal(_ h: ManifestSaveFixture, disk: ManifestSnapshot, peerName: String,
                                           before: [String: Data], rebuild: Bool, precedingSaves: Int) throws {
        var disk = disk
        XCTAssertEqual(h.recording.writes.count, precedingSaves, peerName)
        if precedingSaves == 0 { XCTAssertEqual(try h.manifestBytes(), before, peerName) }
        if precedingSaves > 0 {
            let index = try XCTUnwrap(disk.skills.firstIndex { $0.slug == "alpha" })
            disk.skills[index].tags = ["head"]
        }
        if precedingSaves > 1 {
            let index = try XCTUnwrap(disk.skills.firstIndex { $0.slug == "beta" })
            disk.skills[index].tags = ["second"]
        }
        disk.categories.sort { $0.name < $1.name }
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root), disk)
        let rows = try h.context.fetch(FetchDescriptor<Pensieve.Category>())
        let local = try XCTUnwrap(rows.first { $0.name == "Local" })
        XCTAssertEqual(local.projectKeys, ["local-key"])
        XCTAssertEqual(local.skillSlugs, ["alpha"])
        if rebuild || precedingSaves > 0 {
            let peer = try XCTUnwrap(rows.first { $0.name == peerName })
            XCTAssertEqual(peer.projectKeys, ["peer-key"])
            XCTAssertEqual(peer.skillSlugs, ["beta"])
        } else {
            XCTAssertEqual(local.id, h.local.id)
        }
        XCTAssertTrue(try XCTUnwrap(h.saves.categoryNotice).message.contains("already exists"))
    }

    @MainActor
    func testQueuedCreateStillJoinsExactPeerNameAndKeepsPeerMembers() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        _ = try XCTUnwrap(h.categories.create(name: "Writing", context: h.context))
        var disk = try h.manifest.read(fromRoot: h.root)
        disk.categories.append(CategoryRecord(name: "Writing", projectKeys: ["peer-key"], skillSlugs: ["beta"]))
        try h.manifest.write(disk, toRoot: h.root)
        held.release()
        await h.saves.waitUntilIdle()
        let saved = try h.manifest.read(fromRoot: h.root).categories.filter { $0.name == "Writing" }
        XCTAssertEqual(saved, [CategoryRecord(name: "Writing", projectKeys: ["peer-key"], skillSlugs: ["beta"])])
        let rows = try h.context.fetch(FetchDescriptor<Pensieve.Category>()).filter { $0.name == "Writing" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.projectKeys, ["peer-key"])
        XCTAssertEqual(rows.first?.skillSlugs, ["beta"])
        XCTAssertNil(h.saves.categoryNotice)
    }
}
