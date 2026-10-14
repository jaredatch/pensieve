import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ManifestSaveTests: XCTestCase {
    func testCategoryWritersWaitApplyFIFOAndKeepPulledMembership() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        let before = try h.manifestBytes()
        let created = try XCTUnwrap(h.categories.create(name: "New", context: h.context))
        h.categories.rename(h.local, to: "Renamed", context: h.context)
        h.categories.setProject(h.project, inCategory: h.local, member: true, context: h.context)
        h.categories.setSkill(h.alpha, inCategory: h.local, assigned: true, context: h.context)
        h.categories.delete(h.doomed, context: h.context)
        XCTAssertEqual(created.name, "New")
        XCTAssertEqual(h.local.name, "Renamed")
        XCTAssertEqual(h.local.projectKeys, ["local-key"])
        XCTAssertEqual(h.local.skillSlugs, ["alpha"])
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Pensieve.Category>()), 2)
        await h.assertWaitingBehindHeldLock(pending: 5, before: before)
        h.categories.setProject(h.project, inCategory: h.local, member: false, context: h.context)
        h.categories.setSkill(h.alpha, inCategory: h.local, assigned: false, context: h.context)
        XCTAssertTrue(h.local.projectKeys.isEmpty)
        XCTAssertTrue(h.local.skillSlugs.isEmpty)
        await h.assertWaitingBehindHeldLock(pending: 7, before: before)
        var pulled = try h.manifest.read(fromRoot: h.root)
        pulled.categories[0].projectKeys = ["pulled-key"]
        pulled.categories[0].skillSlugs = ["pulled-skill"]
        pulled.categories.append(CategoryRecord(name: "Remote", projectKeys: [], skillSlugs: []))
        try h.manifest.write(pulled, toRoot: h.root)
        lock.release()
        await h.saves.waitUntilIdle()
        let saved = try h.manifest.read(fromRoot: h.root)
        XCTAssertEqual(Set(saved.categories.map(\.name)), ["New", "Renamed", "Remote"])
        let renamed = try XCTUnwrap(saved.categories.first { $0.name == "Renamed" })
        XCTAssertEqual(renamed.projectKeys, ["pulled-key"])
        XCTAssertEqual(renamed.skillSlugs, ["pulled-skill"])
        let displayed = try h.context.fetch(FetchDescriptor<Pensieve.Category>())
        XCTAssertEqual(Set(displayed.map(\.name)), ["New", "Renamed", "Remote"])
        let windowCategory = try XCTUnwrap(displayed.first { $0.name == "Renamed" })
        XCTAssertEqual(Set(windowCategory.projectKeys), Set(renamed.projectKeys))
        XCTAssertEqual(Set(windowCategory.skillSlugs), Set(renamed.skillSlugs))
        let writes = h.recording.writes
        XCTAssertEqual(writes.count, 7)
        XCTAssertTrue(writes[0].categories.contains { $0.name == "Local" })
        XCTAssertTrue(writes[1].categories.contains { $0.name == "Renamed" && $0.projectKeys == ["pulled-key"] })
        XCTAssertEqual(writes[2].categories.first { $0.name == "Renamed" }?.projectKeys, ["pulled-key", "local-key"])
        XCTAssertEqual(writes[3].categories.first { $0.name == "Renamed" }?.skillSlugs, ["pulled-skill", "alpha"])
        XCTAssertFalse(writes[4].categories.contains { $0.name == "ZDelete" })
        XCTAssertEqual(writes[5].categories.first { $0.name == "Renamed" }?.projectKeys, ["pulled-key"])
        XCTAssertEqual(writes[6].categories.first { $0.name == "Renamed" }?.skillSlugs, ["pulled-skill"])
    }

    func testSkillWritersWaitAndMergeOnlyEditedFields() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.local.skillSlugs = ["beta"]
        h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.localID,
            skillSlug: "beta", platformRaw: "codex", projectKey: nil))
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        let before = try h.manifestBytes()
        let new = try XCTUnwrap(h.library.createSkill(name: "New Skill", description: "d", body: "body",
            tags: ["new"], context: h.context))
        h.library.updateMetadata(h.alpha, tags: ["local"], scope: .user, context: h.context)
        let platforms = PlatformViewModel(fileService: h.files,
            linkService: TestPaths.linkService(fileService: h.files),
            cursorCompiler: TestPaths.cursorCompiler(fileService: h.files),
            agentDetection: DeployStubDetection(installed: []), deployStateStore: .memoryBacked,
            skillsDirectory: h.root + "/skills")
        XCTAssertTrue(SkillDeletionFlow.delete(skill: h.beta, library: h.library, platformVM: platforms,
            projects: [], context: h.context))
        XCTAssertEqual(new.tags, ["new"])
        XCTAssertEqual(h.alpha.tags, ["local"])
        await h.assertWaitingBehindHeldLock(pending: 4, before: before)
        var pulled = try h.manifest.read(fromRoot: h.root)
        let index = try XCTUnwrap(pulled.skills.firstIndex { $0.slug == "alpha" })
        pulled.skills[index].tags = ["remote-same-field"]
        pulled.skills[index].scope = .project
        pulled.skills[index].origin = .imported(from: "remote")
        try h.manifest.write(pulled, toRoot: h.root)
        lock.release()
        await h.saves.waitUntilIdle()
        let saved = try h.manifest.read(fromRoot: h.root)
        XCTAssertEqual(Set(saved.skills.map(\.slug)), ["alpha", "new-skill"])
        let alpha = try XCTUnwrap(saved.skills.first { $0.slug == "alpha" })
        XCTAssertEqual(alpha.tags, ["local"])
        XCTAssertEqual(alpha.scope, .project)
        XCTAssertEqual(alpha.origin, .imported(from: "remote"))
        XCTAssertEqual(h.alpha.tags, ["local"])
        XCTAssertEqual(h.alpha.scope, .project)
        XCTAssertEqual(h.alpha.importedFrom, "remote")
        XCTAssertEqual(h.recording.writes.count, 4)
        XCTAssertFalse(saved.categories.contains { $0.skillSlugs.contains("beta") })
        XCTAssertFalse(saved.deployIntents.contains { $0.skillSlug == "beta" })
        XCTAssertNil(h.library.error)
        try await checkAbsentSkillDeletionCountsAsSaved(h)
    }

    func testPulledDeletionSkipsQueuedEditAndRefreshesWindow() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        h.categories.rename(h.local, to: "Gone", context: h.context)
        var pulled = try h.manifest.read(fromRoot: h.root)
        pulled.categories.removeAll { $0.name == "Local" }
        try h.manifest.write(pulled, toRoot: h.root)
        let before = try h.manifestBytes()
        lock.release()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.manifestBytes(), before)
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name), ["ZDelete"])
        XCTAssertTrue(h.messages.lines.contains { $0.contains("Skipped") && $0.contains("removed by sync") })
        XCTAssertTrue(h.recording.writes.isEmpty)
        for edit in ["rename", "membership", "delete", "recreated delete"] {
            let r = try ManifestSaveFixture()
            defer { r.cleanup() }
            r.recording.failingWrites = 1
            if edit == "rename" { r.categories.rename(r.local, to: "Refused", context: r.context) } else if edit == "membership" {
                r.categories.setSkill(r.alpha, inCategory: r.local, assigned: true, context: r.context)
            } else { r.categories.delete(r.local, context: r.context) }
            await r.saves.waitUntilIdle()
            var remote = try r.manifest.read(fromRoot: r.root)
            remote.categories.removeAll { $0.name == "Local" }
            if edit == "recreated delete" {
                remote.categories.append(CategoryRecord(name: "Local", projectKeys: [], skillSlugs: ["remote"]))
            }
            try r.manifest.write(remote, toRoot: r.root)
            r.categories.rename(r.doomed, to: "Other", context: r.context)
            await r.saves.waitUntilIdle()
            let expected: Set<String> = edit == "recreated delete" ? ["Local", "Other"] : ["Other"]
            XCTAssertEqual(Set(try r.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name)), expected, edit)
            remote = try r.manifest.read(fromRoot: r.root)
            if !remote.categories.contains(where: { $0.name == "Local" }) {
                remote.categories.append(CategoryRecord(name: "Local", projectKeys: [], skillSlugs: []))
            }
            try r.manifest.write(remote, toRoot: r.root)
            let other = try XCTUnwrap(try r.context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Other" })
            r.categories.rename(other, to: "Again", context: r.context)
            await r.saves.waitUntilIdle()
            XCTAssertEqual(Set(try r.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name)),
                ["Again", "Local"], "A retired refusal must not hide or recreate pulled categories")
        }
    }

    func testRefusedCategoriesUndoWhileSkillFieldsStayLocal() async throws {
        for refusal in ["newer schema", "write", "snapshot"] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let disk = try h.manifest.read(fromRoot: h.root)
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { lock.release() }
            let created = try XCTUnwrap(h.categories.create(name: "Undone", context: h.context))
            let createdID = created.id
            h.categories.rename(h.local, to: "Renamed", context: h.context)
            h.library.updateMetadata(h.alpha, tags: ["kept"], scope: .project, context: h.context)
            if refusal == "newer schema" {
                try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "schema_version: 99\n")
            } else if refusal == "write" { h.recording.failingWrites = 3 } else {
                try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "not: [yaml\n")
                h.recording.failingSnapshots = .max
            }
            let before = try h.manifestBytes()
            lock.release()
            await h.saves.waitUntilIdle()
            h.recording.failingSnapshots = 0
            XCTAssertEqual(try h.manifestBytes(), before, refusal)
            XCTAssertFalse(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).contains { $0.id == createdID })
            XCTAssertEqual(h.local.name, "Local")
            XCTAssertEqual(h.alpha.tags, ["kept"])
            XCTAssertEqual(h.alpha.scope, .project)
            let notice = try XCTUnwrap(h.saves.categoryNotice)
            XCTAssertTrue(notice.message.contains("Undone"))
            XCTAssertTrue(notice.message.contains("Local"))
            XCTAssertNotNil(h.library.error)
            if refusal == "newer schema" {
                XCTAssertTrue(h.library.error?.contains("newer version") == true)
                XCTAssertTrue(notice.message.contains("Update Pensieve"))
            }
            XCTAssertFalse(h.saves.isWaiting)
            var remote = disk
            remote.categories.append(CategoryRecord(name: "Remote", projectKeys: [], skillSlugs: []))
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "schema_version: 5\n")
            try h.manifest.write(remote, toRoot: h.root)
            h.categories.rename(h.doomed, to: "Saved Other", context: h.context)
            await h.saves.waitUntilIdle()
            let window = try h.context.fetch(FetchDescriptor<Pensieve.Category>())
            XCTAssertEqual(Set(window.map(\.name)), ["Local", "Remote", "Saved Other"], refusal)
            XCTAssertEqual(h.alpha.tags, ["kept"], refusal)
            XCTAssertEqual(h.alpha.scope, .project, refusal)
            try await checkRefusedFieldAcknowledgement(h, window: window)
        }
        try await checkPresentationReadFailureAfterDurableWrite()
    }

    func testCorruptManifestHealsFromCurrentWindowAfterWaiting() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        h.recording.failingSnapshots = 1
        h.library.updateMetadata(h.alpha, tags: ["readable"], scope: .user, context: h.context)
        lock.release()
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.library.error, "A readable manifest must not fetch the unused fallback")
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "alpha" }?.tags, ["readable"])
        h.recording.failingSnapshots = 0
        let corruptLock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { corruptLock.release() }
        h.categories.rename(h.local, to: "Healed", context: h.context)
        h.library.updateMetadata(h.alpha, tags: ["latest"], scope: .project, context: h.context)
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "not: [yaml\n")
        let expected = try h.manifest.snapshot(from: h.context)
        corruptLock.release()
        await h.saves.waitUntilIdle()
        let saved = try h.manifest.read(fromRoot: h.root)
        XCTAssertEqual(saved.categories, expected.categories.sorted { $0.name < $1.name })
        XCTAssertEqual(saved.skills, expected.skills.sorted { $0.slug < $1.slug })
        XCTAssertNil(h.library.error)
    }

    func testUnopenableLockReportsImmediatelyWithoutWaitingNotice() async throws {
        let h = try ManifestSaveFixture(unopenableLock: true)
        defer { h.cleanup() }
        let before = try h.manifestBytes()
        let started = Date()
        h.categories.rename(h.local, to: "Kept", context: h.context)
        h.library.updateMetadata(h.alpha, tags: ["kept"], scope: .project, context: h.context)
        await TestWait.until(failureMessage: "The lock open failure did not finish") { h.saves.pendingCount == 0 }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(try h.manifestBytes(), before)
        XCTAssertFalse(h.saves.isWaiting)
        XCTAssertNil(h.saves.statusMessage)
        XCTAssertTrue(h.messages.lines.contains { $0.contains("Category change") })
        XCTAssertNotNil(h.library.error)
    }
}

extension ManifestSaveTests {
    private func checkAbsentSkillDeletionCountsAsSaved(_ h: ManifestSaveFixture) async throws {
        var saves = 0
        h.saves.didSave = { saves += 1 }
        let writes = h.recording.writes.count
        h.library.regenerateManifest(.deleteSkill("beta"), context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.recording.writes.count, writes + 1, "An absent-record deletion must publish its idempotent result")
        XCTAssertEqual(saves, 1, "An idempotent deletion must still nudge sync")
        XCTAssertFalse(h.messages.lines.contains { $0.contains("removed by sync") })
        XCTAssertNil(h.library.error)
    }

    private func checkRefusedFieldAcknowledgement(_ h: ManifestSaveFixture,
                                                  window: [Pensieve.Category]) async throws {
        // A later successful field must retire its refusal overlay without retiring another field's.
        h.library.updateMetadata(h.alpha, tags: ["kept"], scope: .user, context: h.context)
        await h.saves.waitUntilIdle()
        var laterPull = try h.manifest.read(fromRoot: h.root)
        laterPull.skills[0].scope = .project
        try h.manifest.write(laterPull, toRoot: h.root)
        let other = try XCTUnwrap(window.first { $0.name == "Saved Other" })
        h.categories.rename(other, to: "Saved Again", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.alpha.scope, .project, "An acknowledged field must accept a later pull")
        XCTAssertEqual(h.alpha.tags, ["kept"], "The still-refused field must remain local")
        h.library.updateMetadata(h.alpha, tags: ["acknowledged"], scope: .project, context: h.context)
        await h.saves.waitUntilIdle()
        laterPull = try h.manifest.read(fromRoot: h.root)
        laterPull.skills[0].tags = ["pulled-after-ack"]
        try h.manifest.write(laterPull, toRoot: h.root)
        h.categories.rename(other, to: "Saved Finally", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.alpha.tags, ["pulled-after-ack"], "A successful write must retire its refused field before a later pull")
    }

    private func checkPresentationReadFailureAfterDurableWrite() async throws {
        // Projection failures cannot turn a durable success into a refused save or hide a pull.
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.recording.failingWrites = 1
        h.categories.rename(h.local, to: "Refused", context: h.context)
        await h.saves.waitUntilIdle()
        var remote = try h.manifest.read(fromRoot: h.root)
        remote.categories.append(CategoryRecord(name: "Pulled", projectKeys: [], skillSlugs: []))
        try h.manifest.write(remote, toRoot: h.root)
        h.recording.afterWrite = { h.recording.failingSnapshots = 1 }
        h.library.updateMetadata(h.alpha, tags: ["saved"], scope: .user, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "alpha" }?.tags, ["saved"])
        XCTAssertNil(h.library.error, "Presentation read failure cannot report a durable write as refused")
        XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name)),
            ["Local", "Pulled", "ZDelete"])
        h.recording.afterWrite = nil
        h.recording.failingWrites = 1
        h.library.updateMetadata(h.alpha, tags: ["refused"], scope: .project, context: h.context)
        await h.saves.waitUntilIdle()
        h.recording.afterWrite = { h.recording.failingSnapshots = 1 }
        h.library.updateMetadata(h.alpha, tags: ["newer"], scope: .project, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.library.error)
        XCTAssertEqual(h.alpha.tags, ["newer"], "A later save must supersede the cached refused field")
        XCTAssertEqual(h.alpha.scope, .project, "The other refused field stays local")
    }

}
