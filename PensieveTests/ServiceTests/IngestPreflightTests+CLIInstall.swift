import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testCLIInstallIngestsExternalFastForwardBeforeReply() async throws {
        for unreadableHead in [false, true] {
            let f = try CLILibraryFixture()
            defer { f.stop() }
            try await f.start()
            let container = f.runtime.container
            let root = f.paths.storeRoot, remote = f.root + "/remote.git", peer = f.root + "/peer"
            let manifest = ManifestService()
            try manifest.write(IncompleteIngestFixture.snapshot(["Deleted", "Kept"]), toRoot: root)
            try await f.rawGit(["init", "--bare", "--initial-branch=main", remote])
            try await BlockingWork.run {
                try f.git.initRepository(at: root)
                try f.git.setRemote("file://" + remote, at: root)
                _ = try f.git.stageAllAndCommit(at: root, message: "seed")
                try f.git.push(at: root, credential: nil)
                try f.git.clone(remote: "file://" + remote, into: peer, credential: nil)
            }
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: root, context: f.context)
            XCTAssertEqual(try f.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Deleted", "Kept"])
            try await BlockingWork.run {
                try manifest.write(IncompleteIngestFixture.snapshot(["Added", "Kept"]), toRoot: peer)
                _ = try f.git.stageAllAndCommit(at: peer, message: "peer categories")
                try f.git.push(at: peer, credential: nil)
                guard case .fastForwarded = try f.git.fastForwardOnly(at: root, credential: nil) else {
                    return XCTFail("Outside process did not fast-forward")
                }
            }
            let headPath = root + "/.git/HEAD", head = try f.files.readFile(at: root + "/.git/HEAD")
            if unreadableHead { try f.files.writeFile(at: headPath, content: "unreadable head\n") }
            defer { if unreadableHead { try? f.files.writeFile(at: headPath, content: head) } }
            let reply = await CLILibraryHandler(runtime: f.runtime, files: f.files).handle(CLIRequest(command: "install",
                arguments: [f.sourceURL], library: CLILibraryOptions(confirmed: true)))
            XCTAssertTrue(reply.envelope.ok, String(describing: reply.envelope.error))
            XCTAssertEqual(try f.skill().directoryName, "foo")
            XCTAssertEqual(try f.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Added", "Kept"])
            XCTAssertEqual(try manifest.read(fromRoot: root).categories.map(\.name).sorted(), ["Added", "Kept"])
            if unreadableHead { try f.files.writeFile(at: headPath, content: head) }
            try await BlockingWork.run {
                let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: f.git), manifestService: manifest,
                    storeRebuildService: StoreRebuildService(), lockPath: f.paths.syncLockPath)
                guard case .synced = try engine.sync(root: root, message: "after CLI install", credential: nil,
                    context: ModelContext(container)) else { return XCTFail("Next sync failed") }
                let check = f.root + "/check"
                try f.git.clone(remote: "file://" + remote, into: check, credential: nil)
                XCTAssertEqual(try manifest.read(fromRoot: check).categories.map(\.name).sorted(), ["Added", "Kept"])
            }
        }
    }
}
