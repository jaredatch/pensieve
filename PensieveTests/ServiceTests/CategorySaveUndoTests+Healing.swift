import SwiftData
import XCTest
@testable import Pensieve

extension CategorySaveUndoTests {
    func checkPublishedEditsNeverReplay() async throws {
        for deleting in [false, true] {
            for queuedCreate in [true, false] {
                for intermediary in ["none", "saved", "refused"] {
                    try await checkHealingSuccess(deleting: deleting, queuedCreate: queuedCreate, intermediary: intermediary)
                }
            }
        }
    }

    private func checkHealingSuccess(deleting: Bool, queuedCreate: Bool, intermediary: String) async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let kind = "delete=\(deleting), queued create=\(queuedCreate), intermediary=\(intermediary)"
        let oldID = h.local.id
        try h.files.deleteDirectory(at: h.root + "/manifest")
        let healed = TestWait.Gate(owner: self), ownWrite = TestWait.Gate(owner: self)
        defer { healed.open(); ownWrite.open() }
        h.recording.afterWrite = {
            let count = h.recording.writes.count
            if count == 1 { try? healed.wait() }
            if count == (intermediary == "saved" ? 3 : 2) { try? ownWrite.wait() }
        }
        h.library.updateMetadata(h.beta, tags: ["healed"], scope: .user, context: h.context)
        if intermediary != "none" { h.library.updateMetadata(h.alpha, tags: ["queued"], scope: .user, context: h.context) }
        if deleting { h.categories.delete(h.local, context: h.context) } else {
            h.categories.rename(h.local, to: "Drafts", context: h.context)
        }
        let replacement = queuedCreate ? h.categories.create(name: "Local", context: h.context) : nil
        await TestWait.until(failureMessage: "The healing write never completed") { healed.waiterCount == 1 }
        var peer = try h.manifest.read(fromRoot: h.root)
        if !queuedCreate { peer.categories.append(CategoryRecord(name: "Local", projectKeys: [], skillSlugs: ["beta"])) }
        let index = try XCTUnwrap(peer.categories.firstIndex { $0.name == "ZDelete" })
        peer.categories[index].skillSlugs = ["alpha"]
        let skill = try XCTUnwrap(peer.skills.firstIndex { $0.slug == "alpha" })
        peer.skills[skill].tags = ["peer"]
        try h.manifest.write(peer, toRoot: h.root)
        let expected = deleting ? ["Local", "ZDelete"] : ["Drafts", "Local", "ZDelete"]
        if intermediary == "refused" { h.recording.failingWrites = 1 }
        healed.open()
        await TestWait.until(failureMessage: "The category's own successful write never completed") { ownWrite.waiterCount == 1 }
        let displayed = try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted()
        XCTAssertEqual(displayed, intermediary == "saved" || queuedCreate ? expected : expected.filter { $0 != "Local" },
                       "An intervening rebuild must not replay the published edit: " + kind)
        if intermediary == "saved" { XCTAssertEqual(h.alpha.tags, ["peer"], "A published skill edit must not replay: " + kind) }
        ownWrite.open()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.recording.writes.count, 2 + (intermediary == "saved" ? 1 : 0) + (queuedCreate ? 1 : 0), kind)
        checkPublishedManifest(h, names: expected, queuedCreate: queuedCreate, kind: kind)
        let rows = try h.context.fetch(FetchDescriptor<Pensieve.Category>())
        XCTAssertEqual(rows.map(\.name).sorted(), expected, "No duplicate or missing local rows: " + kind)
        XCTAssertEqual(rows.first { $0.id == oldID }?.name, deleting ? nil : "Drafts", kind)
        if let replacement { XCTAssertEqual(rows.first { $0.id == replacement.id }?.name, "Local", kind) }
        XCTAssertEqual(h.doomed.skillSlugs, ["alpha"], kind)
        XCTAssertEqual(h.alpha.tags, ["peer"], kind)
        XCTAssertNil(h.saves.categoryNotice, "Successful saves report no refusal: " + kind)
        XCTAssertNil(h.library.error, "A healing write already published this skill edit: " + kind)
    }

    private func checkPublishedManifest(_ h: ManifestSaveFixture, names: [String], queuedCreate: Bool, kind: String) {
        for write in h.recording.writes.dropFirst() {
            XCTAssertEqual(write.categories.map(\.name).sorted(), names, "Each later write preserves both names: " + kind)
            XCTAssertEqual(write.skills.first { $0.slug == "alpha" }?.tags, ["peer"], kind)
        }
        let disk = try? h.manifest.read(fromRoot: h.root)
        XCTAssertEqual(disk?.categories.map(\.name).sorted(), names, "The saved manifest must retain the replacement: " + kind)
        XCTAssertEqual(disk?.categories.first { $0.name == "Local" }?.skillSlugs, queuedCreate ? [] : ["beta"], kind)
    }

    func checkHealPublishesOnlyItsOwnContext() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let other = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        try h.files.deleteDirectory(at: h.root + "/manifest")
        h.recording.afterWrite = {
            try? h.files.deleteFile(at: h.lockPath)
            try? h.files.createDirectory(at: h.lockPath)
        }
        h.library.updateMetadata(h.beta, tags: ["healed"], scope: .user, context: h.context)
        h.categories.rename(h.local, to: "Published", context: h.context)
        _ = h.categories.create(name: "Other window", context: other)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.map(\.name), ["Published", "ZDelete"])
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Published", "ZDelete"])
        XCTAssertTrue(try other.fetch(FetchDescriptor<Pensieve.Category>()).isEmpty,
                      "An edit absent from this context's snapshot must undo its own refusal")
        let notice = try XCTUnwrap(h.saves.categoryNotice)
        XCTAssertEqual(notice.messages.count, 2)
        XCTAssertTrue(notice.messages[0].contains("already saved"))
        XCTAssertTrue(notice.messages[1].contains("undone"))
    }

    func checkPublishedRenameWithReusedOldName() async throws {
        for queuedCreate in [true, false] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            try h.files.deleteDirectory(at: h.root + "/manifest")
            let written = TestWait.Gate(owner: self)
            defer { written.open() }
            h.recording.afterWrite = { try? written.wait() }
            h.library.updateMetadata(h.beta, tags: ["healed"], scope: .user, context: h.context)
            h.categories.rename(h.local, to: "Drafts", context: h.context)
            let replacement = queuedCreate ? h.categories.create(name: "Local", context: h.context) : nil
            await TestWait.until(failureMessage: "The heal did not publish the queued rename") { written.waiterCount == 1 }
            var peer = try h.manifest.read(fromRoot: h.root)
            XCTAssertTrue(peer.categories.contains { $0.name == "Drafts" })
            if queuedCreate {
                XCTAssertTrue(peer.categories.contains { $0.name == "Local" })
            } else {
                peer.categories.append(CategoryRecord(name: "Local", projectKeys: [], skillSlugs: []))
            }
            // Change an unrelated category too, so whole-tree receipt equality cannot confirm the rename.
            let index = try XCTUnwrap(peer.categories.firstIndex { $0.name == "ZDelete" })
            peer.categories[index].skillSlugs = ["alpha"]
            try h.manifest.write(peer, toRoot: h.root)
            let peerBytes = try h.manifestBytes()
            h.recording.failingWrites = queuedCreate ? 2 : 1
            written.open()
            await h.saves.waitUntilIdle()
            XCTAssertEqual(h.recording.writes.count, 1)
            XCTAssertEqual(h.local.name, "Drafts", "The published rename stays when another category owns Local")
            XCTAssertEqual(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(),
                           queuedCreate ? ["Drafts", "Local", "ZDelete"] : ["Drafts", "ZDelete"],
                           "The healing rebuild must not replay the rename onto the replacement category")
            if let replacement {
                let rows = try h.context.fetch(FetchDescriptor<Pensieve.Category>())
                XCTAssertEqual(rows.first { $0.id == replacement.id }?.name, "Local",
                               "The published create must not be undone as a dependent")
                XCTAssertNotEqual(replacement.id, h.local.id)
            }
            XCTAssertEqual(try h.manifestBytes(), peerBytes, "Refused writes leave the peer's manifest intact")
            let notice = try XCTUnwrap(h.saves.categoryNotice).message
            XCTAssertTrue(notice.contains("already saved"))
            XCTAssertFalse(notice.contains("undone"))
            h.recording.afterWrite = nil
            h.library.updateMetadata(h.beta, tags: ["next save"], scope: .user, context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.map(\.name).sorted(),
                           ["Drafts", "Local", "ZDelete"], "A later save must keep both published names")
            XCTAssertEqual(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(),
                           ["Drafts", "Local", "ZDelete"])
            XCTAssertEqual(h.doomed.skillSlugs, ["alpha"], "The next rebuild also accepts the peer's unrelated edit")
        }
    }

}
