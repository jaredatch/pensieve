import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
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
    func checkRefusedCreateAcknowledgesCurrentOverlay() async throws {
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
        skill.cursorConfig = CursorAdapterConfig(globs: ["*.swift"], alwaysApply: false)
        skill.importedFrom = "cursor"
        try context.save()
        let overlay = try XCTUnwrap(f.manifest.snapshot(from: context).skills.first)
        let manifest = RecordingSaveManifest()
        manifest.failingWrites = 1
        let saves = ManifestSaveModel(manifest: manifest, root: f.app, lockPath: base + "/sync.lock")
        saves.submit(.createSkill(overlay), context: context) { XCTAssertNotNil($0) }
        await saves.waitUntilIdle()
        XCTAssertEqual(saves.refused.count, 1)
        skill.tags = ["current"]
        skill.scope = .user
        try context.save()
        saves.submit(.skillMetadata("item", skill.tags, skill.scope), context: context) { XCTAssertNotNil($0) }
        await saves.waitUntilIdle()
        let current = try XCTUnwrap(f.manifest.snapshot(from: context).skills.first)
        try publishRefusedCreate(f, container: container, expected: current)
        saves.refreshRefused(durable: try f.manifest.read(fromRoot: f.app))
        XCTAssertTrue(saves.refused.isEmpty, "Publication of the current overlay acknowledges the refused create")
        XCTAssertFalse(StoreIngestState.shared(for: container).needsRebuild)
    }

    private func publishRefusedCreate(_ f: IncompleteIngestFixture, container: ModelContainer,
                                      expected: SkillOverlay) throws {
        try NativeTestWork.run(container: container) { worker in
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: f.app, context: worker)
            XCTAssertEqual(try f.manifest.snapshot(from: worker).skills.first { $0.slug == "item" }, expected)
            guard case .synced = try f.engine(rebuild: StoreRebuildService()).sync(root: f.app,
                message: "publish refused create", credential: nil, context: worker) else {
                return XCTFail("The refused create must publish through sync")
            }
            let published = f.base + "/published"
            try f.git.clone(remote: f.remote, into: published, credential: nil)
            var durable = expected
            durable.createdAt = Date(timeIntervalSince1970: 1_700_000_000.123)
            XCTAssertEqual(try f.manifest.read(fromRoot: published).skills.first { $0.slug == "item" }, durable)
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
