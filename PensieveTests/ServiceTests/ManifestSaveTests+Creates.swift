import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func testCreatesPreservePeerOverlaysAcrossQueuedAndRefusedRebuilds() async throws {
        for refusedFirst in [false, true] {
            for committedPeer in [false, true] {
                for unreadableWindow in [false, true] {
                    try await checkPeerCreate(refusedFirst: refusedFirst, committedPeer: committedPeer,
                                              unreadableWindow: unreadableWindow)
                }
            }
        }
    }

    private func checkPeerCreate(refusedFirst: Bool, committedPeer: Bool, unreadableWindow: Bool) async throws {
        let fixture = try peerCreateFixture()
        let f = fixture.fixture, context = fixture.context, peer = fixture.peer
        defer { try? f.files.deleteDirectory(at: f.base) }
        let container = context.container
        let local = try XCTUnwrap(f.manifest.snapshot(from: context).skills.first)
        let manifest = RecordingSaveManifest()
        manifest.failingWrites = 1
        manifest.failingSnapshots = unreadableWindow ? .max : 0
        let saves = ManifestSaveModel(manifest: manifest, root: f.app, lockPath: f.base + "/sync.lock")
        var reports: [Error?] = []
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: f.base + "/sync.lock"))
        defer { held.release() }
        saves.submit(.createSkill(local), context: context) { reports.append($0) }
        if !refusedFirst {
            try publishPeerOverlay(peer, fixture: f, committed: committedPeer)
            try assertPeerCreateWindow(f, container: container, peer: peer)
        }
        held.release()
        await saves.waitUntilIdle()
        XCTAssertEqual(manifest.failingWrites, 0, "The create must reach the failing manifest write")
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first.flatMap { $0 } != nil, refusedFirst)
        XCTAssertEqual(saves.refused.count, refusedFirst ? 1 : 0)
        if refusedFirst { try publishPeerOverlay(peer, fixture: f, committed: committedPeer) }
        try assertPeerCreateWindow(f, container: container, peer: peer)
        try syncPeerCreate(f, container: container, peer: peer)
        saves.refreshRefused(durable: try f.manifest.read(fromRoot: f.app))
        XCTAssertTrue(saves.refused.isEmpty, "The first writer's slug acknowledges the create by presence")
        XCTAssertEqual(reports.count, 1, "Rebuild, sync and acknowledgement must not report again")
        XCTAssertFalse(StoreIngestState.shared(for: container).needsRebuild)
    }

    private struct PeerCreateFixture {
        let fixture: IncompleteIngestFixture
        let context: ModelContext
        let peer: ManifestSnapshot
    }

    private func peerCreateFixture() throws -> PeerCreateFixture {
        let base = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString).path
        let f = try NativeTestWork.run { try IncompleteIngestFixture(base: base) }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        try NativeTestWork.run(container: container) { worker in
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: f.app, context: worker)
        }
        let context = ModelContext(container)
        let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first)
        skill.tags = ["local"]
        skill.scope = .project
        skill.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        try context.save()
        let local = try XCTUnwrap(f.manifest.snapshot(from: context).skills.first)
        var peer = try f.manifest.read(fromRoot: f.app)
        var overlay = local
        overlay.tags = ["peer"]
        overlay.scope = .user
        overlay.origin = .imported(from: "cursor")
        peer.skills = [overlay]
        peer.deployIntents = [DeployIntentRecord(machineID: ProjectIntentHarness.remoteID, skillSlug: "item",
            platformRaw: "claude", projectKey: nil)]
        return PeerCreateFixture(fixture: f, context: context, peer: peer)
    }

    private func assertPeerCreateWindow(_ f: IncompleteIngestFixture, container: ModelContainer,
                                        peer: ManifestSnapshot) throws {
        try NativeTestWork.run(container: container) { worker in
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: f.app, context: worker)
            let window = try f.manifest.snapshot(from: worker)
            XCTAssertEqual(window.skills, peer.skills, "A create cannot replace an existing peer overlay")
            XCTAssertEqual(window.deployIntents, peer.deployIntents)
        }
    }

    private func syncPeerCreate(_ f: IncompleteIngestFixture, container: ModelContainer, peer: ManifestSnapshot) throws {
        try NativeTestWork.run(container: container) { worker in
            guard case .synced = try f.engine(rebuild: StoreRebuildService()).sync(root: f.app,
                message: "keep first writer", credential: nil, context: worker) else {
                return XCTFail("Sync must remain unfenced")
            }
            let published = f.base + "/published"
            try f.git.clone(remote: f.remote, into: published, credential: nil)
            let durable = try f.manifest.read(fromRoot: published)
            XCTAssertEqual(durable.skills, peer.skills)
            XCTAssertEqual(durable.deployIntents, peer.deployIntents)
        }
    }
}
