import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension SyncCoordinatorTests {
    func testSyncAfterLockOrWriteRefusalKeepsOriginalCategoryAndAcceptsPeerMembership() async throws {
        for refusal in ["lock", "write"] {
            let h = try makeRemoteHarness()
            let files = FileService(), manifest = ManifestService()
            defer {
                let seed = (h.clone as NSString).deletingLastPathComponent + "/seed"
                for path in [h.clone, h.remotePath, seed] { try? files.deleteDirectory(at: path) }
            }
            let context = h.container.mainContext
            let category = Pensieve.Category(name: "Writing")
            context.insert(category)
            try context.save()
            try manifest.write(try manifest.snapshot(from: context), toRoot: h.clone)
            let coordinator = await configuredCoordinator(container: h.container, engine: h.engine,
                                                           git: h.allowlistedGit, root: h.clone)
            try requireSynced(await coordinator.runCycle())
            let peer = h.clone + "-peer-" + refusal
            defer { try? files.deleteDirectory(at: peer) }
            try NativeTestWork.run { [self] in try h.git.clone(remote: h.remote, into: peer, credential: nil) }
            let recording = RecordingSaveManifest()
            let lockPath = h.clone + "/../undo-" + refusal + ".lock"
            if refusal == "lock" { try files.createDirectory(at: lockPath) } else { recording.failingWrites = 1 }
            let saves = ManifestSaveModel(manifest: recording, root: h.clone, lockPath: lockPath)
            CategoryStore(manifestSaves: saves).rename(category, to: "Drafts", context: context)
            await saves.waitUntilIdle()
            XCTAssertEqual(category.name, "Writing")
            let notice = try XCTUnwrap(saves.categoryNotice).message
            XCTAssertTrue(notice.contains("Writing"))
            XCTAssertTrue(notice.contains(refusal == "lock" ? POSIXError(.EISDIR).localizedDescription
                                           : CocoaError(.fileWriteNoPermission).localizedDescription))
            if refusal == "lock" { try files.deleteDirectory(at: lockPath) }
            try requireSynced(await coordinator.runCycle())
            try assertRemoteCategory(h, name: "Writing", projects: [])
            var pulled = try manifest.read(fromRoot: peer)
            pulled.categories[0].projectKeys = ["peer-project"]
            try manifest.write(pulled, toRoot: peer)
            XCTAssertTrue(try NativeTestWork.run { [self] in try h.git.stageAllAndCommit(at: peer, message: "peer membership") })
            try NativeTestWork.run { [self] in try h.git.push(at: peer, credential: nil) }
            try requireSynced(await coordinator.runCycle())
            let refreshed = try XCTUnwrap(try ModelContext(h.container).fetch(FetchDescriptor<Pensieve.Category>()).first)
            XCTAssertEqual(refreshed.name, "Writing")
            XCTAssertEqual(refreshed.projectKeys, ["peer-project"], "A refused rename must leave no projection over a later pull")
            try assertRemoteCategory(h, name: "Writing", projects: ["peer-project"])
        }
    }

    private func requireSynced(_ result: SyncCycleResult) throws {
        guard case .synced = result else { XCTFail("Expected sync, got \(result)"); throw CocoaError(.fileReadUnknown) }
    }

    private func assertRemoteCategory(_ h: RemoteHarness, name: String, projects: [String]) throws {
        let directory = "manifest/categories/"
        let path = directory + ManifestService.categoryFileName(name)
        let names = try rawGitOutput(["--git-dir", h.remotePath, "ls-tree", "-r", "--name-only", "HEAD", directory])
        XCTAssertEqual(names, path, "The next sync must publish only the original category")
        let record = try rawGitOutput(["--git-dir", h.remotePath, "show", "HEAD:" + path])
        XCTAssertTrue(record.contains("Writing"))
        for key in projects { XCTAssertTrue(record.contains(key)) }
    }
}
