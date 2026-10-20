import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func checkCreateCollisions() async throws {
        try checkPeerOverlayWithoutCreate()
        for peerCommitted in [false, true] {
            for unreadableWindow in [false, true] {
                try await checkRefusedCreateKeepsOverlay(unreadableWindow: unreadableWindow, peerCommitted: peerCommitted)
            }
        }
        try await checkRefusedCreateKeepsOverlay(unreadableWindow: true, peerCommitted: true, writeFails: false)
    }

    func checkPeerOverlayWithoutCreate() throws {
        let base = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString).path
        let f = try NativeTestWork.run { try IncompleteIngestFixture(base: base) }
        defer { try? f.files.deleteDirectory(at: base) }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        var peer = try f.manifest.read(fromRoot: f.peer)
        let overlay = SkillOverlay(slug: "item", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            scope: .user, tags: ["peer"], cursor: nil, agents: ["claude"], origin: .imported(from: "claude"))
        let intent = DeployIntentRecord(machineID: ProjectIntentHarness.remoteID, skillSlug: "item",
                                        platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil)
        peer.skills = [overlay]
        peer.deployIntents = [intent]
        try publishPeerOverlay(peer, fixture: f, committed: true)
        try NativeTestWork.run(container: container) { worker in
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: f.app, context: worker)
            guard case .synced = try f.engine(rebuild: StoreRebuildService()).sync(root: f.app,
                message: "sync peer overlay without any local create", credential: nil, context: worker) else {
                return XCTFail("The control sync must publish")
            }
            let published = base + "/published"
            try f.git.clone(remote: f.remote, into: published, credential: nil)
            let durable = try f.manifest.read(fromRoot: published)
            XCTAssertEqual(durable.skills.first { $0.slug == "item" }?.agents, [],
                           "This legacy field stays empty; deployment intent is stored separately")
            XCTAssertEqual(durable.skills.first { $0.slug == "item" }?.origin, .imported(from: "claude"))
            XCTAssertEqual(durable.deployIntents, [intent], "Actual peer deployment intent survives the control sync")
        }
    }

    func testHeldManifestScanCannotRestoreIdentityBeforeEditorSaveOrHistoryRestore() async throws {
        for restore in [false, true] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let held = TestWait.Gate(owner: self)
            defer { held.open() }
            h.recording.afterRebuildSnapshot = { try held.wait() }
            _ = h.library.editorBody(for: h.alpha)
            h.library.updateMetadata(h.beta, tags: ["queued"], scope: .user, context: h.context)
            await TestWait.until(failureMessage: "The manifest scan did not finish") { held.waiterCount == 1 }
            let document = try XCTUnwrap(h.library.readSkillDocument(h.alpha))
                .replacingOccurrences(of: "description: description", with: "description: New description")
            if restore {
                try restoreSkillHistoryVersion(skill: h.alpha, body: document, store: h.library.skillStore,
                    library: h.library, notifier: {})
            } else {
                h.library.noteEditorChanged(h.alpha, body: document)
                XCTAssertTrue(h.library.saveDraft(h.alpha))
            }
            XCTAssertEqual(h.alpha.skillDescription, "New description")
            held.open()
            await h.saves.waitUntilIdle()
            XCTAssertEqual(h.alpha.skillDescription, "New description")
            XCTAssertEqual(h.alpha.name, "Alpha")
            XCTAssertEqual(h.beta.tags, ["queued"], "Overlay acceptance still applies")
            XCTAssertEqual(h.library.readSkillDocument(h.alpha), document)
        }
    }
    func checkRefusedCreateKeepsOverlay(unreadableWindow: Bool, peerCommitted: Bool,
                                        writeFails: Bool = true) async throws {
        let base = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString).path
        let f = try NativeTestWork.run { try IncompleteIngestFixture(base: base) }
        defer { try? f.files.deleteDirectory(at: base) }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        try NativeTestWork.run(container: container) { context in
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: f.app, context: context)
        }
        let context = ModelContext(container)
        let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first)
        skill.createdAt = Date(timeIntervalSince1970: 1_700_000_000.123456)
        skill.tags = ["local"]
        skill.scope = .project
        try context.save()
        let overlay = try XCTUnwrap(f.manifest.snapshot(from: context).skills.first)
        var peer = try f.manifest.read(fromRoot: f.app)
        var different = overlay
        different.createdAt = Date(timeIntervalSince1970: 1_700_000_000.123)
        different.tags = ["peer"]
        different.scope = .user
        different.origin = .imported(from: "claude")
        peer.skills = [different]
        peer.deployIntents = [DeployIntentRecord(machineID: ProjectIntentHarness.remoteID, skillSlug: "item",
            platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil)]
        try publishPeerOverlay(peer, fixture: f, committed: peerCommitted)
        let manifest = RecordingSaveManifest()
        manifest.failingWrites = writeFails ? 1 : 0
        manifest.failingSnapshots = unreadableWindow ? .max : 0
        let saves = ManifestSaveModel(manifest: manifest, root: f.app, lockPath: base + "/sync.lock")
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: base + "/sync.lock"))
        defer { held.release() }
        var reports: [String] = []
        saves.submit(.createSkill(overlay), context: context) { reports.append($0?.localizedDescription ?? "saved") }
        if !peerCommitted { try assertPeerCreateRebuild(f, container: container, expected: peer) }
        held.release()
        await saves.waitUntilIdle()
        XCTAssertEqual(manifest.failingWrites, 0, "The failed-write fixture must reach the manifest write")
        XCTAssertEqual(saves.refused.count, 1, "A different same-slug overlay is a collision, never a saved create")
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports.first?.contains("item") == true)
        XCTAssertTrue(reports.first?.contains("Another Mac already has") == true)
        try assertPeerCreateRebuild(f, container: container, expected: peer)
        saves.refreshRefused(durable: try f.manifest.read(fromRoot: f.app))
        try publishPeerCreate(f, container: container, expected: peer)
        saves.refreshRefused(durable: try f.manifest.read(fromRoot: f.app))
        XCTAssertEqual(saves.refused.count, 1, "A rebuilt peer row cannot acknowledge the submitted create")
        XCTAssertEqual(reports.count, 1, "Rebuild, refresh and sync must not repeat the collision report")
        XCTAssertFalse(StoreIngestState.shared(for: container).needsRebuild)
    }

    private func assertPeerCreateRebuild(_ f: IncompleteIngestFixture, container: ModelContainer,
                                         expected: ManifestSnapshot) throws {
        try NativeTestWork.run(container: container) { worker in
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: f.app, context: worker)
            let window = try f.manifest.snapshot(from: worker)
            XCTAssertEqual(window.skills, expected.skills, "Queued and refused creates cannot replace the peer overlay")
            XCTAssertEqual(window.deployIntents, expected.deployIntents)
        }
    }

    private func publishPeerCreate(_ f: IncompleteIngestFixture, container: ModelContainer,
                                   expected: ManifestSnapshot) throws {
        try NativeTestWork.run(container: container) { worker in
            guard case .synced = try f.engine(rebuild: StoreRebuildService()).sync(root: f.app,
                message: "preserve peer create", credential: nil, context: worker) else {
                return XCTFail("Sync must preserve the first writer's overlay")
            }
            let published = f.base + "/published"
            try f.git.clone(remote: f.remote, into: published, credential: nil)
            let durable = try f.manifest.read(fromRoot: published)
            XCTAssertEqual(durable.skills, expected.skills)
            XCTAssertEqual(durable.deployIntents, expected.deployIntents)
        }
    }
    private func publishPeerOverlay(_ snapshot: ManifestSnapshot, fixture: IncompleteIngestFixture, committed: Bool) throws {
        try fixture.manifest.write(snapshot, toRoot: committed ? fixture.peer : fixture.app)
        guard committed else { return }
        try NativeTestWork.run {
            _ = try fixture.git.stageAllAndCommit(at: fixture.peer, message: "peer overlay for the same slug")
            try fixture.git.push(at: fixture.peer, credential: nil)
            _ = try fixture.git.fastForwardOnly(at: fixture.app, credential: nil)
        }
    }

}
