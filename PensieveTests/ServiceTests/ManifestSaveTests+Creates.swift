import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func testSameSlugCreateFromAnotherMacIsRefusedOnceAndKeepsBothMacsValues() async throws {
        for committed in [false, true] {
            for unreadable in [false, true] {
                let h = try CollisionCreateFixture(committed: committed, unreadable: unreadable)
                defer { h.cleanup() }
                await h.saves.waitUntilIdle()
                XCTAssertEqual(h.library.error, CollisionCreateFixture.message("item"))
                XCTAssertEqual(h.saves.refused.count, 1)
                try h.assertPeer()
                try h.assertLocal()
                h.library.error = "notice already read"
                let ingest = StoreIngestState.shared(for: h.context.container)
                XCTAssertFalse(ingest.requiresRebuild(at: GitHeadStamp(fileService: h.f.files).state(root: h.f.app)))
                try h.sync() // No fixture rebuild: worker rows still contain this Mac's create.
                try h.assertPeer()
                try h.assertLocal()
                try h.rebuild()
                try h.assertLocal()
                try h.sync()
                try h.assertPeer()
                try h.assertLocal()
                h.saves.refreshRefused(durable: try h.f.manifest.read(fromRoot: h.f.app))
                XCTAssertEqual(h.saves.refused.count, 1)
                let other = Skill(name: "Other", directoryName: "other")
                h.context.insert(other)
                try h.f.files.writeFile(at: h.f.app + "/skills/other/SKILL.md",
                    content: "---\nname: Other\ndescription: job\n---\nbody\n")
                try h.context.save()
                let dependencies = DeployIntentDependencies.live(
                    identity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
                    stateService: InertMachineStateService(), root: h.f.app,
                    lockPath: h.f.base + "/sync.lock", notifier: {}, reconcile: { _ in BatchResult() })
                let deploy = DeployMutationService(platformVM: h.platform, dependencies: dependencies)
                try deploy.setRemote(true, machineID: ProjectIntentHarness.remoteID, projectKey: nil,
                    skill: other, platform: .claudeCode, context: h.context)
                try h.assertPeer()
                XCTAssertEqual(h.library.error, "notice already read", "Refusal reports only once")
                // Identity acknowledges even when the tags and scope differ from the submitted create.
                var own = try h.f.manifest.read(fromRoot: h.f.app)
                var edited = h.local
                edited.tags = ["later"]
                edited.scope = .project
                own.skills = [edited]
                try h.f.manifest.write(own, toRoot: h.f.app)
                h.saves.refreshRefused(durable: try h.f.manifest.read(fromRoot: h.f.app))
                XCTAssertTrue(h.saves.refused.isEmpty)
            }
        }
    }

    func testEditsAndDeleteOnARefusedCreateStayWithIt() async throws {
        for failDelete in [false, true] {
            let h = try CollisionCreateFixture(failDelete: failDelete)
            defer { h.cleanup() }
            await h.saves.waitUntilIdle()
            h.library.updateMetadata(h.skill, tags: ["edited"], scope: .project, context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertEqual(h.library.error, CollisionCreateFixture.message("item"))
            try h.assertPeer()
            try h.assertLocal(tags: ["edited"], scope: .project)
            try h.sync()
            try h.assertPeer()
            try h.assertLocal(tags: ["edited"], scope: .project)
            h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.localID, skillSlug: "item",
                platformRaw: PlatformTarget.claudeCode.rawValue))
            try h.context.save()
            XCTAssertEqual(SkillDeletionFlow.delete(skill: h.skill, library: h.library, platformVM: h.platform,
                projects: [], context: h.context), !failDelete)
            await h.saves.waitUntilIdle()
            try h.assertPeer()
            let durable = try h.f.manifest.read(fromRoot: h.f.app)
            XCTAssertFalse(durable.deployIntents.contains {
                $0.machineID == ProjectIntentHarness.localID && $0.skillSlug == "item"
            })
            XCTAssertEqual(h.saves.refused.isEmpty, !failDelete)
            if failDelete {
                try h.assertLocal(tags: ["edited"], scope: .project)
            } else {
                XCTAssertTrue(try h.context.fetch(FetchDescriptor<Skill>()).isEmpty)
            }
        }
    }

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
            try assertPeerCreateWindow(f, container: container, peer: peer, local: local)
        }
        held.release()
        await saves.waitUntilIdle()
        if refusedFirst { XCTAssertEqual(manifest.failingWrites, 0, "The absent create reaches the failing write") }
        XCTAssertEqual(reports.count, 1)
        XCTAssertNotNil(reports.first.flatMap { $0 })
        if !refusedFirst {
            XCTAssertEqual(reports.first.flatMap { $0 }?.localizedDescription, CollisionCreateFixture.message("item"))
        }
        XCTAssertEqual(saves.refused.count, 1)
        if refusedFirst { try publishPeerOverlay(peer, fixture: f, committed: committedPeer) }
        try assertPeerCreateWindow(f, container: container, peer: peer, local: local)
        try syncPeerCreate(f, container: container, peer: peer)
        saves.refreshRefused(durable: try f.manifest.read(fromRoot: f.app))
        XCTAssertEqual(saves.refused.count, 1, "Another Mac's creation date cannot acknowledge this create")
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
        overlay.createdAt = Date(timeIntervalSince1970: 1_600_000_000.321)
        overlay.tags = ["peer"]
        overlay.scope = .user
        overlay.origin = .imported(from: "cursor")
        peer.skills = [overlay]
        peer.categories[0].skillSlugs = ["item"]
        peer.deployIntents = [DeployIntentRecord(machineID: ProjectIntentHarness.remoteID, skillSlug: "item",
            platformRaw: "claude", projectKey: nil)]
        return PeerCreateFixture(fixture: f, context: context, peer: peer)
    }

    private func assertPeerCreateWindow(_ f: IncompleteIngestFixture, container: ModelContainer,
                                        peer: ManifestSnapshot, local: SkillOverlay) throws {
        try NativeTestWork.run(container: container) { worker in
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: f.app, context: worker)
            let window = try f.manifest.snapshot(from: worker)
            XCTAssertEqual(window.skills, [local], "A rebuild keeps this Mac's current values in its rows")
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
