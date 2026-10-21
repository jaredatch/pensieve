import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func testStagedRefusalCompletionsFollowQueueOrderWhenHeadAcceptanceFails() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        var pulled = try h.manifest.read(fromRoot: h.root)
        pulled.categories.append(CategoryRecord(name: "Peer", projectKeys: [], skillSlugs: []))
        try h.manifest.write(pulled, toRoot: h.root)
        StoreIngestState.shared(for: h.context.container).invalidate()
        let gate = TestWait.Gate(owner: self)
        defer { gate.open() }
        h.recording.afterRebuildSnapshot = { try gate.wait() }
        var reports: [String] = []
        for (category, name) in [(h.local, "Head"), (h.doomed, "Peer")] {
            let change = ManifestChange.renameCategory(category.name, name)
            let edit = CategorySaveEdit(category: category, context: h.context, change: change)
            category.name = name
            try edit.save(in: h.context)
            h.saves.submit(change, context: h.context, categoryEdit: edit) { error in
                XCTAssertNotNil(error)
                reports.append(name)
            }
        }
        await TestWait.until(failureMessage: "The pre-save scan must reach acceptance") { gate.waiterCount == 1 }
        let fault = try CategoryFetchFault(in: h.context, entityName: "Skill")
        defer { fault.stop() }
        gate.open()
        await h.saves.waitUntilIdle()
        fault.stop()
        XCTAssertTrue(h.recording.writes.isEmpty)
        XCTAssertEqual(reports, ["Head", "Peer"], "Completions must follow submission order even when the head refuses last")
        XCTAssertEqual(h.saves.categoryNotice?.entries.count, 2)
    }

    func testHealedEditKeepsPublicationFactWhenItsPreSaveRebuildFails() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try h.files.deleteDirectory(at: h.root + "/manifest")
        h.alpha.tags = ["alpha-kept"]
        h.beta.tags = ["beta-kept"]
        try h.context.save()
        var reports: [Error?] = []
        h.recording.afterWrite = {
            do {
                try h.files.writeFile(at: h.root + "/.git/HEAD", content: "unreadable")
            } catch { XCTFail("Could not move fixture HEAD: \(error)") }
            h.recording.failingRebuildSnapshots = 1
        }
        h.saves.submit(.skillMetadata("alpha", ["alpha-kept"], nil), context: h.context) { reports.append($0) }
        h.saves.submit(.skillMetadata("beta", ["beta-kept"], nil), context: h.context) { reports.append($0) }
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.recording.writes.count, 1, "The fallback must publish both queued edits")
        XCTAssertEqual(h.recording.failingRebuildSnapshots, 0, "The healed item's pre-save scan must fail")
        XCTAssertEqual(reports.count, 2)
        let failure = try XCTUnwrap(reports.last.flatMap { $0 }) as? ManifestSaveError
        guard case .rebuildFailed(_, manifestSaved: true) = failure else {
            return XCTFail("A pre-save failure must keep the healed item's earlier publication fact")
        }
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "beta" }?.tags, ["beta-kept"])
    }

    func testScanAcrossUnreadableAndUnbornHeadRetriesBeforeRecordingCompletion() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try NativeTestWork.run { try TestPaths.git.initRepository(at: h.root) }
        let headPath = h.root + "/.git/HEAD"
        let original = try h.files.readFile(at: headPath)
        let ingest = StoreIngestState.shared(for: h.context.container)
        ingest.invalidate()
        var reads = 0, scans = 0
        var scansAtWrites: [Int] = []
        h.recording.afterRead = {
            reads += 1
            if reads == 1 { try h.files.writeFile(at: headPath, content: "unreadable during pull") }
        }
        h.recording.afterRebuildSnapshot = {
            scans += 1
            if scans == 1 { try h.files.writeFile(at: headPath, content: original) }
        }
        h.recording.beforeWrite = { scansAtWrites.append(scans) }
        h.categories.rename(h.local, to: "Kept", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(scansAtWrites, [2], "A scan across different nil-OID states cannot count as complete")
        XCTAssertFalse(ingest.needsRebuild)
        XCTAssertNil(h.saves.categoryNotice)
        XCTAssertTrue(try h.manifest.read(fromRoot: h.root).categories.contains { $0.name == "Kept" })
    }

    func testHeadMovementAfterPublicationKeepsSkillReportsAndNudgesSync() async throws {
        let cause = "the store changed on disk at the same moment. Pensieve reads it again before your next change."
        for consumer in ["metadata", "deletion", "retirement"] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            try NativeTestWork.run {
                try TestPaths.git.initRepository(at: h.root)
                XCTAssertTrue(try TestPaths.git.stageAllAndCommit(at: h.root, message: "seed"))
            }
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: h.root, context: h.context)
            var commits = 0, nudges = 0
            h.saves.didSave = { nudges += 1 }
            h.recording.beforeWrite = {
                commits += 1
                try h.files.writeFile(at: h.root + "/outside.txt", content: "outside \(commits)")
                XCTAssertTrue(try TestPaths.git.stageAllAndCommit(at: h.root, message: "outside change"))
            }
            let presentation = SkillLibraryViewModel.DeletionPresentation(presentsInWindow: false)
            switch consumer {
            case "metadata":
                h.library.updateMetadata(h.alpha, tags: ["kept"], scope: .user, context: h.context)
            case "deletion":
                _ = h.library.deleteSkillEntry(h.alpha, context: h.context, presentation: presentation)
            default:
                let files = MemoryDeployFileService()
                let platform = PlatformViewModel(fileService: files, linkService: DeletionTestLinkService(),
                    cursorCompiler: DeletionTestCursorCompiler(), agentDetection: DeletionTestDetection(installed: []),
                    deployStateStore: DeployStateStore(fileService: files, appSupportDir: h.root + "/deploy-state"),
                    skillsDirectory: h.root + "/skills")
                XCTAssertTrue(SkillDeletionFlow.delete(skill: h.alpha, library: h.library, platformVM: platform,
                    projects: [], context: h.context, presentation: presentation))
            }
            await h.saves.waitUntilIdle()
            XCTAssertEqual(commits, consumer == "retirement" ? 2 : 1, consumer)
            XCTAssertEqual(nudges, 1, "A durable edit must nudge sync: " + consumer)
            XCTAssertTrue(StoreIngestState.shared(for: h.context.container).needsRebuild)
            let disk = try h.manifest.read(fromRoot: h.root)
            if consumer == "metadata" {
                XCTAssertEqual(disk.skills.first { $0.slug == "alpha" }?.tags, ["kept"])
                XCTAssertEqual(h.library.error, "The sync manifest was saved, but rebuilding the local store failed: " + cause)
            } else {
                XCTAssertFalse(disk.skills.contains { $0.slug == "alpha" })
                let notice = try XCTUnwrap(presentation.notice)
                XCTAssertEqual(notice.title, "Skill deleted, but the library didn't refresh")
                XCTAssertTrue(notice.message.contains(cause), notice.message)
                if consumer == "retirement" {
                    XCTAssertTrue(notice.message.contains("Couldn't publish retired deploy records: The sync manifest was saved"),
                                  "The retirement completion must retain the publication fact: " + notice.message)
                }
            }
        }
    }
}
