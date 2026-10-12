import SwiftData
import XCTest
@testable import Pensieve

extension CategorySaveUndoTests {
    func testRefusedDeleteRestoresIdentityMembersAndDateWithoutChangingNewSelection() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.local.projectKeys = ["local-key", "remote-key"]
        h.local.skillSlugs = ["alpha", "beta"]
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
        let id = h.local.id, createdAt = h.local.createdAt
        var selection: EntitySelection? = .category(id)
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        let before = try h.manifestBytes()
        h.categories.delete(h.local, context: h.context)
        selection = try prune(selection, h: h)
        XCTAssertNil(selection)
        selection = .project(h.project.id)
        await h.assertWaitingBehindHeldLock(pending: 1, before: before)
        h.recording.failingWrites = 1
        lock.release()
        await h.saves.waitUntilIdle()
        let restored = try XCTUnwrap(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.id == id })
        XCTAssertEqual(restored.name, "Local")
        XCTAssertEqual(restored.createdAt, createdAt)
        XCTAssertEqual(restored.projectKeys, ["local-key", "remote-key"])
        XCTAssertEqual(restored.skillSlugs, ["alpha", "beta"])
        XCTAssertEqual(try prune(selection, h: h), .project(h.project.id))
        XCTAssertEqual(try prune(.category(id), h: h), .category(id), "The old identity still addresses the restored row")
        let persisted = ModelContext(h.context.container)
        XCTAssertEqual(try persisted.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.id == id }?.skillSlugs,
            ["alpha", "beta"])
        XCTAssertEqual(try h.manifestBytes(), before)
    }

    func testHealingPublicationKeepsLaterEditWhenItsOwnLockFails() async throws {
        for kind in ["create", "rename", "delete", "replace", "skill", "project", "rename chain"] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            try h.files.deleteDirectory(at: h.root + "/manifest")
            h.recording.afterWrite = {
                try? h.files.deleteFile(at: h.lockPath)
                try? h.files.createDirectory(at: h.lockPath)
            }
            h.library.updateMetadata(h.beta, tags: ["healed"], scope: .user, context: h.context)
            enqueue(kind, h: h)
            let expected = try h.manifest.snapshot(from: h.context).categories.sorted { $0.name < $1.name }
            let identities = Set(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.id))
            await h.saves.waitUntilIdle()
            XCTAssertEqual(h.recording.writes.count, 1, kind)
            XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories, expected, kind)
            let window = try h.manifest.snapshot(from: h.context).categories.sorted { $0.name < $1.name }
            XCTAssertEqual(window, expected, kind)
            XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.id)), identities, kind)
            let notice = try XCTUnwrap(h.saves.categoryNotice).message
            XCTAssertTrue(notice.contains("already saved"), kind)
            XCTAssertFalse(notice.contains("undone"), kind)
        }
    }

    func testValidationRefusalRestoresCategoryAndNamesDamagedManifestPart() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try h.files.deleteDirectory(at: h.root + "/manifest")
        h.alpha.directoryName = "unsafe/slug"
        try h.context.save()
        h.categories.rename(h.local, to: "Refused", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.local.name, "Local")
        XCTAssertFalse(h.files.fileExists(at: h.root + "/manifest/manifest.yaml"))
        let notice = try XCTUnwrap(h.saves.categoryNotice).message
        XCTAssertTrue(notice.contains("skills/unsafe/slug.yaml"))
        XCTAssertTrue(notice.contains("undone"))
    }

    func testRefusedRenameThenQueuedDeleteRestoresOriginalAndCoalescesNotice() async throws {
        let h = try ManifestSaveFixture(unopenableLock: true)
        defer { h.cleanup() }
        let id = h.local.id
        h.categories.rename(h.local, to: "Drafts", context: h.context)
        h.categories.delete(h.local, context: h.context)
        await h.saves.waitUntilIdle()
        let row = try XCTUnwrap(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.id == id })
        XCTAssertEqual(row.name, "Local", "Delete must undo before rename")
        let notice = try XCTUnwrap(h.saves.categoryNotice)
        XCTAssertEqual(notice.messages.count, 2)
        XCTAssertTrue(notice.message.contains("depends on an earlier change"))
        XCTAssertEqual(h.recording.writes.count, 0)
    }

    func testRefusedRetirementStillProjectsMembershipThroughLaterRebuilds() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.local.skillSlugs = ["alpha", "beta"]
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
        h.local.skillSlugs = ["beta"]
        try h.context.save()
        h.recording.failingWrites = 1
        h.library.regenerateManifest(.retireSkill("alpha"), context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertNotNil(h.library.error)
        for name in ["Other", "Again"] {
            h.categories.rename(h.doomed, to: name, context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertEqual(h.local.skillSlugs, ["beta"])
            XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.first { $0.name == "Local" }?.skillSlugs,
                ["alpha", "beta"])
        }
    }

    func testReturningToOriginalValueDoesNotAcknowledgeAnUnsavedChain() async throws {
        for field in ["name", "skill"] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            h.recording.failingWrites = 1
            if field == "name" {
                h.categories.rename(h.local, to: "Drafts", context: h.context)
                h.categories.rename(h.local, to: "Local", context: h.context)
            } else {
                h.categories.setSkill(h.alpha, inCategory: h.local, assigned: true, context: h.context)
                h.categories.setSkill(h.alpha, inCategory: h.local, assigned: false, context: h.context)
            }
            await h.saves.waitUntilIdle()
            XCTAssertEqual(h.local.name, "Local")
            XCTAssertTrue(h.local.skillSlugs.isEmpty)
            XCTAssertEqual(h.recording.writes.count, 0, "A dependent inverse must be cancelled with its refused parent")
            let notice = try XCTUnwrap(h.saves.categoryNotice)
            XCTAssertEqual(notice.messages.count, 2)
            XCTAssertFalse(notice.message.contains("already saved"))
        }
    }

    func testEditSubmittedDuringHealingWriteDoesNotUndoTheAlreadyPublishedRename() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try h.files.deleteDirectory(at: h.root + "/manifest")
        let written = TestWait.Gate(owner: self)
        defer { written.open() }
        h.recording.afterWrite = {
            try? h.files.deleteFile(at: h.lockPath)
            try? h.files.createDirectory(at: h.lockPath)
            try? written.wait()
        }
        h.library.updateMetadata(h.beta, tags: ["healed"], scope: .user, context: h.context)
        h.categories.rename(h.local, to: "Published", context: h.context)
        await TestWait.until(failureMessage: "Healing write did not publish its captured window") { written.waiterCount == 1 }
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.first { $0.name == "Published" }?.name, "Published")
        h.categories.rename(h.local, to: "Later Unsaved", context: h.context)
        written.open()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.local.name, "Published")
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.map(\.name), ["Published", "ZDelete"])
        let notice = try XCTUnwrap(h.saves.categoryNotice)
        XCTAssertEqual(notice.messages.count, 2)
        XCTAssertTrue(notice.messages[0].contains("already saved"))
        XCTAssertTrue(notice.messages[1].contains("undone"))
    }

    func testCategoryUndoKeepsAssignmentsWhoseRetirementFieldWasAlreadyAcknowledged() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.local.skillSlugs = ["alpha"]
        let intent = MachineDeployIntent(machineID: ProjectIntentHarness.localID, skillSlug: "alpha", platformRaw: "codex")
        h.context.insert(intent)
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
        h.local.skillSlugs = []
        h.context.delete(intent)
        try h.context.save()
        h.recording.failingWrites = 1
        h.library.regenerateManifest(.retireSkill("alpha"), context: h.context)
        await h.saves.waitUntilIdle()
        h.library.updateMetadata(h.beta, tags: ["first"], scope: .user, context: h.context)
        await h.saves.waitUntilIdle()
        var acknowledged = try h.manifest.read(fromRoot: h.root)
        acknowledged.categories.removeAll { $0.name == "Local" }
        acknowledged.categories.append(CategoryRecord(name: "Local", projectKeys: [], skillSlugs: []))
        try h.manifest.write(acknowledged, toRoot: h.root)
        h.library.updateMetadata(h.beta, tags: ["acknowledge"], scope: .user, context: h.context)
        await h.saves.waitUntilIdle()
        h.categories.setSkill(h.alpha, inCategory: h.local, assigned: true, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.local.skillSlugs, ["alpha"])
        let id = h.local.id
        h.recording.failingWrites = 1
        h.categories.delete(h.local, context: h.context)
        await h.saves.waitUntilIdle()
        let restored = try XCTUnwrap(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.id == id })
        XCTAssertEqual(restored.skillSlugs, ["alpha"], "An acknowledged retirement field must not erase a later assignment")
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<MachineDeployIntent>()).isEmpty,
                      "The unacknowledged intent field still stays retired")
    }

    private func enqueue(_ kind: String, h: ManifestSaveFixture) {
        switch kind {
        case "create": _ = h.categories.create(name: "New", context: h.context)
        case "delete": h.categories.delete(h.local, context: h.context)
        case "replace":
            h.categories.delete(h.local, context: h.context)
            _ = h.categories.create(name: "Local", context: h.context)
        case "skill": h.categories.setSkill(h.alpha, inCategory: h.local, assigned: true, context: h.context)
        case "project": h.categories.setProject(h.project, inCategory: h.local, member: true, context: h.context)
        default:
            h.categories.rename(h.local, to: "Drafts", context: h.context)
            if kind == "rename chain" { h.categories.rename(h.local, to: "Final", context: h.context) }
        }
    }

    private func prune(_ selection: EntitySelection?, h: ManifestSaveFixture) throws -> EntitySelection? {
        prunedEntitySelection(selection, projectIDs: [h.project.id],
            categoryIDs: Set(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.id)),
            machineIDs: [], tags: [], remoteProjectKeys: [])
    }
}
