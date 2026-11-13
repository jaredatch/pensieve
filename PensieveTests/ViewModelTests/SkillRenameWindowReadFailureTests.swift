import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillRenameWindowReadFailureTests: XCTestCase {
    func testARefusedRenameMovesBackWhenTheQueuesWindowReadFails() async throws {
        let reader = RecordingSaveManifest()
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false,
            queueManifest: reader, distinctRecords: true)
        defer { h.cleanup() }
        let id = h.skill.id
        XCTAssertTrue(h.rename())
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        h.library.updateMetadata(h.skill, tags: ["queued"], scope: .user, context: h.context)
        try h.arrivePeer()
        var pulled = try h.manifest.read(fromRoot: h.root)
        let otherIndex = try XCTUnwrap(pulled.skills.firstIndex { $0.slug == "other" })
        pulled.skills[otherIndex].tags = ["pulled"]
        pulled.skills[otherIndex].scope = .project
        pulled.categories.removeAll { $0.name == "Own" }
        pulled.categories.append(CategoryRecord(name: "Remote", projectKeys: [], skillSlugs: ["other"]))
        try h.manifest.write(pulled, toRoot: h.root)
        try h.moveHead()
        let peer = try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml")
        reader.failingSnapshots = .max
        held.release()
        await h.saves.waitUntilIdle()
        reader.failingSnapshots = 0

        XCTAssertEqual(h.library.error, h.takenMessage())
        try assertMovedBack(h, id: id)
        var expected = h.own
        expected.tags = ["queued"]
        expected.scope = .user
        XCTAssertEqual(try h.manifest.snapshot(from: h.context).skills.first { $0.slug == "alpha" }, expected)
        let disk = try h.manifest.read(fromRoot: h.root)
        let own = try XCTUnwrap(disk.skills.first { $0.slug == "alpha" })
        XCTAssertEqual(own.tags, ["queued"])
        XCTAssertEqual(own.scope, .user)
        XCTAssertTrue(ManifestService.sameCreation(own, h.own))
        XCTAssertEqual(try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml"), peer)
        XCTAssertEqual(h.saves.pendingCount, 0)
        XCTAssertTrue(h.saves.refused.isEmpty)

        // Exercise sync's admission before publication: the failed queue read must not mark
        // an unapplied pulled HEAD loaded or let this window put the removed category back.
        try StoreIngestState.rebuildIfNeeded(using: StoreRebuildService(fileService: h.files),
            root: h.root, context: h.context, files: h.files)
        let publication = try StoreIngestState.snapshotForPublication(using: h.manifest, context: h.context, root: h.root)
        try h.manifest.write(publication, toRoot: h.root)
        let afterSync = try h.manifest.read(fromRoot: h.root)
        XCTAssertEqual(afterSync.skills.first { $0.slug == "other" }?.tags, ["pulled"])
        XCTAssertEqual(afterSync.skills.first { $0.slug == "other" }?.scope, .project)
        XCTAssertEqual(afterSync.categories.first { $0.name == "Remote" }?.skillSlugs, ["other"])
        XCTAssertFalse(afterSync.categories.contains { $0.name == "Own" })
        XCTAssertEqual(afterSync.skills.first { $0.slug == "alpha" }?.tags, ["queued"])
        XCTAssertEqual(afterSync.skills.first { $0.slug == "alpha" }?.scope, .user)
    }

    func testAnEarlierSaveKeepsThisMacsRecordWhenTheQueuesWindowReadFails() async throws {
        let reader = RecordingSaveManifest()
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false,
            queueManifest: reader, distinctRecords: true)
        defer { h.cleanup() }
        let id = h.skill.id
        let firstLock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        h.tagLibrary.updateMetadata(h.other, tags: ["edited"], scope: .user, context: h.context)
        firstLock.release()
        // Both edits reach the FIFO before yielding to the worker. No peer folder occupies alpha.
        XCTAssertTrue(h.rename(), h.library.error ?? "")
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        try h.arrivePeer()
        try h.moveHead()
        let peer = try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml")
        reader.failingSnapshots = .max
        held.release()
        await h.saves.waitUntilIdle()
        reader.failingSnapshots = 0

        XCTAssertNil(h.tagLibrary.error)
        XCTAssertEqual(h.library.error, h.takenMessage())
        try assertMovedBack(h, id: id)
        XCTAssertEqual(try h.manifest.snapshot(from: h.context).skills.first { $0.slug == "alpha" }, h.own)
        XCTAssertEqual(try h.files.symlinkTarget(at: h.projects[0].path + "/.claude/skills/alpha"), h.store.baseDir + "/alpha")
        for project in h.projects {
            for suffix in ["/.claude/skills/zulu", "/.cursor/rules/zulu.mdc"] {
                XCTAssertFalse(try h.files.entryExistsWithoutFollowingLinks(at: project.path + suffix))
            }
        }
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "other" }?.tags, ["edited"])
        XCTAssertEqual(try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml"), peer)
        XCTAssertEqual(h.saves.pendingCount, 0)
        XCTAssertTrue(h.saves.refused.isEmpty)
    }

    private func assertMovedBack(_ h: SkillRenameTakeoverFixture, id: UUID,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(h.files.directoryExists(at: h.store.baseDir + "/alpha"), file: file, line: line)
        XCTAssertFalse(h.files.directoryExists(at: h.store.baseDir + "/zulu"), file: file, line: line)
        let row = try XCTUnwrap(h.context.fetch(FetchDescriptor<Skill>()).first { $0.id == id }, file: file, line: line)
        XCTAssertTrue(row === h.skill, file: file, line: line)
        XCTAssertEqual(row.id, id, file: file, line: line)
        XCTAssertEqual(row.name, "Alpha", file: file, line: line)
        XCTAssertEqual(row.directoryName, "alpha", file: file, line: line)
    }
}
