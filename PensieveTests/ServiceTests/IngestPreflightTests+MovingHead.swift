import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testQueuedRenameRetriesMovingHeadAndPreservesOutsideManifestChange() async throws {
        for timing in ["scan", "acceptance"] {
            try await checkMovingHead(timing: timing)
        }
        for alreadyIngested in [false, true] { try await checkMovementInsideWrite(alreadyIngested: alreadyIngested) }
    }

    private func checkMovementInsideWrite(alreadyIngested: Bool) async throws {
        let fixture = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/write-race-\(alreadyIngested)")
        }
        let context = try damageContext(fixture)
        if !alreadyIngested { try pullCategoryChange(fixture) }
        let recording = RecordingSaveManifest()
        var scans = 0, moved = false
        var scansAtWrites: [Int] = []
        recording.afterRebuildSnapshot = { scans += 1 }
        recording.beforeWrite = {
            scansAtWrites.append(scans)
            guard !moved else { return }
            moved = true
            // This real commit lands after the queue's guard, inside the manifest writer.
            try self.commitOutsideCategory(fixture)
        }
        var reports: [String] = []
        let saves = ManifestSaveModel(manifest: recording, root: fixture.app, lockPath: fixture.base + "/sync.lock",
                                      log: { reports.append($0) })
        try renameKept(context, saves: saves)
        await saves.waitUntilIdle()
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports.first?.hasPrefix("The sync manifest was saved, but") == true)
        XCTAssertNil(saves.categoryNotice, "A published category edit is kept")
        let ingest = StoreIngestState.shared(for: context.container)
        XCTAssertTrue(moved)
        XCTAssertEqual(recording.writes.count, 1)
        XCTAssertTrue(ingest.needsRebuild, "Movement inside publication must leave ingestion pending")
        XCTAssertEqual(scans, alreadyIngested ? 0 : 1, "Do not bless the changed HEAD with a post-write scan")
        let scansBeforeRetry = scans
        let renamed = try XCTUnwrap(context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Renamed" })
        CategoryStore(manifestSaves: saves).rename(renamed, to: "Next", context: context)
        await saves.waitUntilIdle()
        XCTAssertEqual(scansAtWrites.last, scansBeforeRetry + 1, "The next writer must rebuild before writing")
        XCTAssertFalse(ingest.needsRebuild)
        XCTAssertTrue(try fixture.manifest.read(fromRoot: fixture.app).categories.contains { $0.name == "Next" })
    }

    private func checkMovingHead(timing: String) async throws {
        let fixture = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/moving-head-" + timing)
        }
        let context = try damageContext(fixture)
        try pullCategoryChange(fixture)
        let recording = RecordingSaveManifest()
        var scans = 0, commits = 0
        recording.afterRebuildSnapshot = {
            scans += 1
            if scans == 1, timing == "scan" {
                try self.commitOutsideCategory(fixture)
                commits += 1
            }
        }
        // The real acceptance save is after the scan's closing HEAD sample and before publication.
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave,
            object: context, queue: nil) { _ in
            guard timing == "acceptance", scans == 1, commits == 0 else { return }
            do {
                try NativeTestWork.run { try self.commitOutsideCategory(fixture) }
                commits += 1
            } catch { XCTFail("Outside commit failed: \(error)") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let saves = ManifestSaveModel(manifest: recording, root: fixture.app, lockPath: fixture.base + "/sync.lock")
        try renameKept(context, saves: saves)
        await saves.waitUntilIdle()
        XCTAssertEqual(commits, 1, timing)
        XCTAssertEqual(scans, 2, "One outside commit must retry within the three-attempt bound: " + timing)
        XCTAssertNil(saves.categoryNotice)
        XCTAssertEqual(saves.pendingCount, 0)
        XCTAssertEqual(try fixture.manifest.read(fromRoot: fixture.app).categories.map(\.name),
                       ["Added", "Outside", "Renamed"], timing)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(),
                       ["Added", "Outside", "Renamed"], timing)
    }

    func testQueuedRenameRefusesPersistentHeadMovementWithoutWriting() async throws {
        for finalPublication in [false, true] { try await checkPersistentMovement(finalPublication: finalPublication) }
    }

    private func checkPersistentMovement(finalPublication: Bool) async throws {
        let fixture = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/persistent-head-\(finalPublication)")
        }
        let context = try damageContext(fixture)
        try pullCategoryChange(fixture)
        let before = try ManifestSaveFixture.manifestBytes(root: fixture.app, files: fixture.files)
        let recording = RecordingSaveManifest()
        var scans = 0
        var acceptedHead: GitHeadStamp.State?
        recording.afterRebuildSnapshot = {
            scans += 1
            if finalPublication, scans == 3 { return }
            // Keep the manifest unchanged, while a real commit advances HEAD on each scan.
            // A broken unbounded retry still terminates so the test reports an assertion.
            guard scans <= 8 else { throw CocoaError(.fileReadUnknown) }
            try fixture.files.writeFile(at: fixture.app + "/outside.txt", content: "commit \(scans)")
            XCTAssertTrue(try fixture.git.stageAllAndCommit(at: fixture.app, message: "outside change \(scans)"))
        }
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave,
            object: context, queue: nil) { _ in
            guard finalPublication, scans == 3, acceptedHead == nil else { return }
            acceptedHead = GitHeadStamp().state(root: fixture.app)
            do {
                try NativeTestWork.run {
                    try fixture.files.writeFile(at: fixture.app + "/outside.txt", content: "commit 3")
                    XCTAssertTrue(try fixture.git.stageAllAndCommit(at: fixture.app, message: "outside change 3"))
                }
            } catch { XCTFail("Final outside commit failed: \(error)") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let saves = ManifestSaveModel(manifest: recording, root: fixture.app, lockPath: fixture.base + "/sync.lock")
        try renameKept(context, saves: saves)
        await saves.waitUntilIdle()
        XCTAssertEqual(scans, 3, "Persistent movement must exhaust exactly three attempts")
        XCTAssertTrue(recording.writes.isEmpty)
        XCTAssertEqual(try ManifestSaveFixture.manifestBytes(root: fixture.app, files: fixture.files), before)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(),
                       [finalPublication ? "Added" : "Deleted", "Kept"])
        XCTAssertEqual(saves.pendingCount, 0)
        let notice = try XCTUnwrap(saves.categoryNotice)
        XCTAssertEqual(notice.entries.count, 1)
        XCTAssertFalse(try XCTUnwrap(notice.entries.first).wasKept)
        XCTAssertTrue(notice.entries[0].text.contains("undone"))
        XCTAssertTrue(notice.entries[0].text.contains("store changed"))
        let ingest = StoreIngestState.shared(for: context.container)
        if finalPublication {
            XCTAssertFalse(ingest.needsRebuild, "A completed ingest must not fence push when only publication was refused")
            XCTAssertFalse(ingest.requiresRebuild(at: try XCTUnwrap(acceptedHead)))
            XCTAssertFalse(notice.message.contains("Rebuilding the local store failed"), notice.message)
            try await checkMissingAfterRefusal(fixture, context: context, saves: saves, recording: recording)
        } else { XCTAssertTrue(ingest.needsRebuild) }
    }

    private func checkMissingAfterRefusal(_ fixture: IncompleteIngestFixture, context: ModelContext,
                                          saves: ManifestSaveModel, recording: RecordingSaveManifest) async throws {
        recording.afterRebuildSnapshot = nil
        try fixture.files.deleteFile(at: fixture.app + "/manifest/manifest.yaml")
        saves.categoryNotice = nil
        try renameKept(context, saves: saves)
        await saves.waitUntilIdle()
        XCTAssertFalse(saves.pausedForRepair, "Missing manifest after completed ingestion is a fallback, not damage")
        XCTAssertEqual(saves.pendingCount, 0)
        XCTAssertNil(saves.categoryNotice)
        XCTAssertTrue(fixture.files.fileExists(at: fixture.app + "/manifest/manifest.yaml"))
    }

    func testQueuedEditRecreatesManifestDeletedByPullWithStableOrMovingHead() async throws {
        for timing in ["before-stable", "before-moving", "during-scan"] {
            let fixture = try NativeTestWork.run {
                try IncompleteIngestFixture(base: self.tempDir + "/missing-" + timing)
            }
            let context = try damageContext(fixture)
            if timing == "during-scan" { try pullCategoryChange(fixture) } else {
                try NativeTestWork.run { try self.pullMissingManifest(fixture) }
            }
            let recording = RecordingSaveManifest()
            var scans = 0
            recording.afterRebuildSnapshot = {
                scans += 1
                guard scans == 1 else { return }
                if timing == "during-scan" { try self.pullMissingManifest(fixture) }
                if timing == "before-moving" {
                    try fixture.files.writeFile(at: fixture.app + "/outside.txt", content: "outside commit")
                    XCTAssertTrue(try fixture.git.stageAllAndCommit(at: fixture.app, message: "outside change"))
                }
            }
            let saves = ManifestSaveModel(manifest: recording, root: fixture.app, lockPath: fixture.base + "/sync.lock")
            try renameKept(context, saves: saves)
            await saves.waitUntilIdle()
            XCTAssertGreaterThan(scans, timing == "before-stable" ? 0 : 1, timing)
            XCTAssertTrue(fixture.files.fileExists(at: fixture.app + "/manifest/manifest.yaml"), timing)
            XCTAssertFalse(recording.writes.isEmpty, timing)
            XCTAssertTrue(try fixture.manifest.read(fromRoot: fixture.app).categories.contains { $0.name == "Renamed" }, timing)
            XCTAssertFalse(try fixture.manifest.read(fromRoot: fixture.app).categories.contains { $0.name == "Kept" }, timing)
            XCTAssertNil(saves.categoryNotice, timing)
            XCTAssertFalse(saves.pausedForRepair, timing)
            XCTAssertEqual(saves.pendingCount, 0, timing)
        }
    }

    func testQueuedRenameKeepsCommitBetweenManifestReadAndScan() async throws {
        for unborn in [false, true] { try await checkStateChangeBeforePublication(unborn: unborn) }
        for alreadyIngested in [false, true] {
            let fixture = try NativeTestWork.run {
                try IncompleteIngestFixture(base: self.tempDir + "/read-bracket-\(alreadyIngested)")
            }
            let context = try damageContext(fixture)
            if !alreadyIngested { try pullCategoryChange(fixture) }
            let recording = RecordingSaveManifest()
            var moved = false
            recording.afterRead = {
                guard !moved else { return }
                moved = true
                try self.commitOutsideCategory(fixture)
            }
            let saves = ManifestSaveModel(manifest: recording, root: fixture.app, lockPath: fixture.base + "/sync.lock")
            try renameKept(context, saves: saves)
            await saves.waitUntilIdle()
            XCTAssertTrue(moved)
            XCTAssertNil(saves.categoryNotice)
            let expected = [alreadyIngested ? "Deleted" : "Added", "Outside", "Renamed"]
            XCTAssertEqual(try fixture.manifest.read(fromRoot: fixture.app).categories.map(\.name), expected)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), expected)
        }
    }

    private func checkStateChangeBeforePublication(unborn: Bool) async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        if unborn { try NativeTestWork.run { try TestPaths.git.initRepository(at: h.root) } }
        XCTAssertEqual(GitHeadStamp().state(root: h.root), unborn ? .unborn : .noRepository)
        let outsideWriter = RecordingSaveManifest()
        outsideWriter.beforeWrite = {
            // The outside writer changes metadata before the queue's publication guard.
            try h.files.writeFile(at: h.root + "/.git/HEAD", content: "malformed HEAD")
        }
        var moved = false, scans = 0
        var scansAtWrites: [Int] = []
        h.recording.afterRead = {
            guard !moved else { return }
            moved = true
            var outside = try h.manifest.read(fromRoot: h.root)
            outside.categories.append(CategoryRecord(name: "Outside", projectKeys: [], skillSlugs: []))
            try outsideWriter.write(outside, toRoot: h.root)
        }
        h.recording.afterRebuildSnapshot = { scans += 1 }
        h.recording.beforeWrite = { scansAtWrites.append(scans) }
        h.categories.rename(h.local, to: "Renamed", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertTrue(moved)
        XCTAssertEqual(GitHeadStamp().state(root: h.root), .unreadable)
        XCTAssertEqual(scansAtWrites, [1], "The changed State must retry before the first publication")
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.map(\.name), ["Outside", "Renamed", "ZDelete"])
        XCTAssertNil(h.saves.categoryNotice)
        XCTAssertEqual(h.saves.pendingCount, 0)
    }

    private func renameKept(_ context: ModelContext, saves: ManifestSaveModel) throws {
        let category = try XCTUnwrap(context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
        CategoryStore(manifestSaves: saves).rename(category, to: "Renamed", context: context)
    }

    private func pullCategoryChange(_ fixture: IncompleteIngestFixture) throws {
        try NativeTestWork.run {
            try fixture.changePeer()
            guard case .fastForwarded = try fixture.git.fastForwardOnly(at: fixture.app, credential: nil) else {
                return XCTFail("Fixture must pull the peer's category change")
            }
        }
    }

    nonisolated private func commitOutsideCategory(_ fixture: IncompleteIngestFixture) throws {
        var snapshot = try fixture.manifest.read(fromRoot: fixture.app)
        snapshot.categories.append(CategoryRecord(name: "Outside", projectKeys: [], skillSlugs: []))
        try fixture.manifest.write(snapshot, toRoot: fixture.app)
        XCTAssertTrue(try fixture.git.stageAllAndCommit(at: fixture.app, message: "outside category"))
    }

    nonisolated private func pullMissingManifest(_ fixture: IncompleteIngestFixture) throws {
        try fixture.files.deleteFile(at: fixture.peer + "/manifest/manifest.yaml")
        XCTAssertTrue(try fixture.git.stageAllAndCommit(at: fixture.peer, message: "remove manifest header"))
        try fixture.git.push(at: fixture.peer, credential: nil)
        guard case .fastForwarded = try fixture.git.fastForwardOnly(at: fixture.app, credential: nil) else {
            return XCTFail("Fixture must pull the manifest deletion")
        }
        XCTAssertFalse(fixture.files.fileExists(at: fixture.app + "/manifest/manifest.yaml"))
    }
}
