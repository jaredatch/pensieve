import SwiftData
import XCTest
@testable import Pensieve

extension CategorySaveUndoTests {
    func checkRefusedCreateAfterPulledRebuild() async throws {
        for refusal in ["schema", "lock", "write"] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { lock.release() }
            let created = try XCTUnwrap(h.categories.create(name: "Writing", context: h.context))
            let id = created.id
            if refusal != "lock" {
                await h.assertWaitingBehindHeldLock(pending: 1, before: try h.manifestBytes())
            }
            var pulled = try h.manifest.read(fromRoot: h.root)
            pulled.skills[0].tags = ["peer"]
            try h.manifest.write(pulled, toRoot: h.root)
            try rebuildPulledState(h)
            XCTAssertFalse(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).contains { $0.id == id })
            try refuseAfterPull(refusal, h: h)
            let before = try h.manifestBytes()
            lock.release()
            await h.saves.waitUntilIdle()
            let notice = try XCTUnwrap(h.saves.categoryNotice)
            XCTAssertTrue(notice.message.contains("Writing"), refusal)
            XCTAssertTrue(notice.message.contains("gone"), notice.message)
            XCTAssertTrue(notice.message.contains("dropped"), notice.message)
            XCTAssertFalse(notice.message.contains("undone"), notice.message)
            XCTAssertEqual(notice.title, "Category changes couldn't be saved")
            XCTAssertEqual(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Local", "ZDelete"])
            XCTAssertEqual(try h.manifestBytes(), before)
        }
    }

    func checkPriorSaveAfterPullDoesNotAcknowledgeRefusal() async throws {
        for field in ["name", "skill", "project"] {
            for refusal in ["schema", "lock"] {
                let h = try ManifestSaveFixture()
                defer { h.cleanup() }
                submit(field, category: h.local, h: h)
                await h.saves.waitUntilIdle()
                XCTAssertNil(h.saves.categoryNotice)
                var pulled = try h.manifest.read(fromRoot: h.root)
                pulled.categories.removeAll { $0.name == h.local.name }
                let oldName = field == "name" ? "Writing" : "Local"
                pulled.categories.append(CategoryRecord(name: oldName, projectKeys: [], skillSlugs: []))
                try h.manifest.write(pulled, toRoot: h.root)
                try rebuildPulledState(h)
                let category = try XCTUnwrap(try h.context.fetch(FetchDescriptor<Pensieve.Category>())
                    .first { $0.name == oldName })
                if refusal == "schema" {
                    try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "schema_version: 99\n")
                } else {
                    try h.files.deleteFile(at: h.lockPath)
                    try h.files.createDirectory(at: h.lockPath)
                }
                let before = try h.manifestBytes()
                submit(field, category: category, h: h)
                await h.saves.waitUntilIdle()
                XCTAssertEqual(category.name, oldName, field + " / " + refusal)
                XCTAssertTrue(category.skillSlugs.isEmpty, field + " / " + refusal)
                XCTAssertTrue(category.projectKeys.isEmpty, field + " / " + refusal)
                let notice = try XCTUnwrap(h.saves.categoryNotice).message
                XCTAssertTrue(notice.contains("undone"), notice)
                XCTAssertFalse(notice.contains("already saved"), notice)
                XCTAssertEqual(try h.manifestBytes(), before)
            }
        }
    }

    func checkUnrelatedCategoryDoesNotAcknowledgeRename() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        var remote = try h.manifest.read(fromRoot: h.root)
        remote.categories.append(CategoryRecord(name: "Drafts", projectKeys: ["remote"], skillSlugs: ["beta"]))
        try h.manifest.write(remote, toRoot: h.root)
        let before = try h.manifestBytes()
        h.recording.failingWrites = 1
        h.categories.rename(h.local, to: "Drafts", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.local.name, "Local", "An unrelated target name is not a publication receipt")
        XCTAssertEqual(try h.manifestBytes(), before)
        let notice = try XCTUnwrap(h.saves.categoryNotice).message
        XCTAssertTrue(notice.contains("undone"), notice)
        XCTAssertFalse(notice.contains("already saved"), notice)
        try rebuildPulledState(h)
        let rows = try h.context.fetch(FetchDescriptor<Pensieve.Category>())
        XCTAssertEqual(Set(rows.map(\.name)), ["Local", "Drafts", "ZDelete"])
        XCTAssertEqual(rows.first { $0.name == "Drafts" }?.skillSlugs, ["beta"])
    }

    func checkRefusalAfterPulledDeletion(fields: [String]) async throws {
        for field in fields {
            for refusal in ["schema", "lock", "write"] {
                let h = try ManifestSaveFixture()
                defer { h.cleanup() }
                let id = h.local.id
                let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
                defer { lock.release() }
                submit(field, category: h.local, h: h)
                if refusal != "lock" {
                    await h.assertWaitingBehindHeldLock(pending: 1, before: try h.manifestBytes())
                }
                var pulled = try h.manifest.read(fromRoot: h.root)
                pulled.categories.removeAll { $0.name == "Local" }
                try h.manifest.write(pulled, toRoot: h.root)
                try rebuildPulledState(h)
                XCTAssertFalse(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).contains { $0.id == id })
                try refuseAfterPull(refusal, h: h)
                let before = try h.manifestBytes()
                lock.release()
                await h.saves.waitUntilIdle()
                let rows = try h.context.fetch(FetchDescriptor<Pensieve.Category>())
                XCTAssertEqual(rows.map(\.name), ["ZDelete"], field + " / " + refusal)
                XCTAssertFalse(rows.contains { $0.id == id }, "Undo must not resurrect a pulled deletion")
                let notice = try XCTUnwrap(h.saves.categoryNotice).message
                XCTAssertTrue(notice.contains("gone"), notice)
                XCTAssertFalse(notice.contains("undone"), notice)
                XCTAssertFalse(notice.contains("already saved"), notice)
                XCTAssertEqual(try h.manifestBytes(), before)
                XCTAssertEqual(try h.manifest.snapshot(from: h.context).categories.map(\.name), ["ZDelete"])
            }
        }
    }

    private func submit(_ field: String, category: Pensieve.Category, h: ManifestSaveFixture) {
        switch field {
        case "name": h.categories.rename(category, to: "Drafts", context: h.context)
        case "skill": h.categories.setSkill(h.alpha, inCategory: category, assigned: true, context: h.context)
        default: h.categories.setProject(h.project, inCategory: category, member: true, context: h.context)
        }
    }

    private func rebuildPulledState(_ h: ManifestSaveFixture) throws {
        let result = StoreRebuildService().rebuild(fromRoot: h.root, context: h.context)
        XCTAssertFalse(result.storeUnreadable)
        XCTAssertFalse(result.saveFailed)
    }

    private func refuseAfterPull(_ refusal: String, h: ManifestSaveFixture) throws {
        switch refusal {
        case "schema":
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "schema_version: 99\n")
        case "lock":
            // The queued worker has not run yet; its first open must fail after the pull.
            try h.files.deleteFile(at: h.lockPath)
            try h.files.createDirectory(at: h.lockPath)
        default:
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "not: [yaml\n")
            h.recording.failingWrites = 1
        }
    }
}
