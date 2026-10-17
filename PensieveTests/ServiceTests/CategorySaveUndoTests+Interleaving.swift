import SwiftData
import XCTest
@testable import Pensieve

extension CategorySaveUndoTests {
    func checkEditAfterRebuildFetch(_ kinds: [String]) async throws {
        for kind in kinds {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let context = h.context.container.mainContext
            let local = try XCTUnwrap(try context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Local" })
            let expected = try h.manifest.read(fromRoot: h.root).categories
            let bytes = try h.manifestBytes()
            let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { held.release() }
            let save = TestWait.Gate(owner: self)
            defer { save.open() }
            let container = context.container, root = h.root
            let rebuilding = BlockingWork.task {
                StoreRebuildService(save: { cycleContext in
                    try save.wait()
                    try cycleContext.save()
                }).rebuild(fromRoot: root, context: ModelContext(container))
            }
            await TestWait.until(failureMessage: "The rebuild never reached its save after fetching categories") {
                save.waiterCount == 1
            }
            if kind == "rename-after-save" {
                let beta = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "beta" })
                h.library.updateMetadata(beta, tags: ["ahead"], scope: .user, context: context)
            }
            switch kind {
            case "create": _ = h.categories.create(name: "Writing", context: context)
            case "delete": h.categories.delete(local, context: context)
            case "skill": h.categories.setSkill(h.alpha, inCategory: local, assigned: true, context: context)
            case "project": h.categories.setProject(h.project, inCategory: local, member: true, context: context)
            default: h.categories.rename(local, to: "Drafts", context: context)
            }
            await h.assertWaitingBehindHeldLock(pending: kind == "rename-after-save" ? 2 : 1, before: bytes)
            save.open()
            let result = await rebuilding.value
            XCTAssertFalse(result.saveFailed)
            XCTAssertFalse(result.storeUnreadable)
            if kind == "rename-after-save" {
                h.recording.afterWrite = { h.recording.failingWrites = 1 }
            } else { h.recording.failingWrites = 1 }
            held.release()
            await h.saves.waitUntilIdle()
            h.recording.afterWrite = nil
            try assertInterleavedRefusal(h, context: context, expected: expected, kind: kind)
            if kind == "rename-after-save" {
                XCTAssertEqual(h.recording.writes.count, 1)
            } else { XCTAssertEqual(try h.manifestBytes(), bytes) }
        }
    }

    private func assertInterleavedRefusal(_ h: ManifestSaveFixture, context: ModelContext,
                                          expected: [CategoryRecord], kind: String) throws {
        for window in [context, ModelContext(context.container)] {
            let rows = try window.fetch(FetchDescriptor<Pensieve.Category>())
            XCTAssertEqual(rows.count, Set(rows.map(\.name)).count, kind)
            let actual = rows.map { CategoryRecord(name: $0.name, projectKeys: $0.projectKeys, skillSlugs: $0.skillSlugs) }
            XCTAssertEqual(actual.sorted { $0.name < $1.name }, expected, kind + " / edit after category fetch")
        }
        let notice = try XCTUnwrap(h.saves.categoryNotice).message
        XCTAssertTrue(notice.contains("undone"), kind + ": " + notice)
        XCTAssertFalse(notice.contains("It now shows what's saved."), kind + ": " + notice)
        XCTAssertFalse(notice.contains("gone"), kind + ": " + notice)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories, expected)
    }

    func checkEditBetweenManifestReadAndCategoryFetch() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let context = h.context.container.mainContext
        let local = try XCTUnwrap(try context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Local" })
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        let read = TestWait.Gate(owner: self)
        defer { read.open() }
        let container = context.container, root = h.root
        let rebuilding = BlockingWork.task {
            StoreRebuildService(manifestService: PausedCategoryManifest(read: read))
                .rebuild(fromRoot: root, context: ModelContext(container))
        }
        await TestWait.until(failureMessage: "The rebuild never read the manifest") { read.waiterCount == 1 }
        h.categories.rename(local, to: "Drafts", context: context)
        await h.assertWaitingBehindHeldLock(pending: 1, before: try h.manifestBytes())
        read.open()
        let result = await rebuilding.value
        XCTAssertFalse(result.saveFailed)
        h.recording.failingWrites = 1
        held.release()
        await h.saves.waitUntilIdle()
        let expected = try h.manifest.read(fromRoot: h.root).categories
        for window in [context, ModelContext(container)] {
            XCTAssertEqual(try window.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), expected.map(\.name))
        }
        let notice = try XCTUnwrap(h.saves.categoryNotice).message
        XCTAssertFalse(notice.contains("It now shows what's saved."), "The rebuild retained the pending edit: " + notice)
        XCTAssertTrue(notice.contains("undone"), notice)
        XCTAssertFalse(notice.contains("gone"), notice)
    }

    func checkRefusalHoldsLockThroughUndoSave() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let context = h.context, container = context.container, root = h.root, path = h.lockPath
        h.recording.failingWrites = 1
        h.categories.rename(h.local, to: "Drafts", context: context)
        var checked = false
        var persistedNames: [String] = [], editedName: String?, cycleError: Error?
        let recording = h.recording
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: context, queue: nil) { _ in
            guard !checked, recording.failingWrites == 0 else { return }
            checked = true
            persistedNames = (try? ModelContext(container).fetch(FetchDescriptor<Pensieve.Category>()).map(\.name)) ?? []
            editedName = h.local.name
            let git = SyncEngineTests.StubGit()
            git.remote = nil
            let engine = SyncEngine(gitService: git, lockPath: path)
            do {
                _ = try engine.sync(root: root, message: "must wait for undo", credential: nil,
                                    context: ModelContext(container))
            } catch { cycleError = error }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await h.saves.waitUntilIdle()
        XCTAssertTrue(checked, "Observe the queue's first undo save after its injected write refusal")
        XCTAssertEqual(editedName, "Local", "Observe the inverse before its save")
        XCTAssertTrue(persistedNames.contains("Drafts"), "The undo has not saved yet")
        XCTAssertEqual(cycleError as? SyncError, .syncInProgress, "Sync must remain locked before undo persistence")
        XCTAssertEqual(h.local.name, "Local")
        let acquired = try XCTUnwrap(SyncLock.tryAcquire(at: path), "The queue releases sync.lock after undo")
        acquired.release()
    }
}

private struct PausedCategoryManifest: ManifestReadWriting {
    let read: TestWait.Gate
    func read(fromRoot root: String) throws -> ManifestSnapshot {
        let snapshot = try ManifestService().read(fromRoot: root)
        try read.wait()
        return snapshot
    }
    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        try ManifestService().write(snapshot, toRoot: root)
    }
}
