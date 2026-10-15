import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testImportAndDeployRebuildPreserveQueuedCategoryAndSkillEdits() async throws {
        for writer in ["import", "deploy"] {
            let f = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir + "/queued-" + writer) }
            let context = try damageContext(f)
            try f.manifest.write(f.manifest.snapshot(from: context), toRoot: f.app)
            let library = queuedLibrary(f, context: context)
            let saves = try XCTUnwrap(library.manifestSaves)
            let category = try XCTUnwrap(try context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
            let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
            var peer = try f.manifest.read(fromRoot: f.app)
            peer.categories.append(CategoryRecord(name: "Peer", projectKeys: [], skillSlugs: []))
            peer.skills[0].tags = ["peer"]
            try f.manifest.write(peer, toRoot: f.app)
            StoreIngestState.shared(for: context.container).invalidate()
            CategoryStore(manifestSaves: saves).rename(category, to: "Waiting", context: context)
            library.updateMetadata(skill, tags: ["waiting"], scope: .project, context: context)
            // No suspension here: the window's writer gets sync.lock before the queued worker runs.
            if writer == "import" {
                let model = importModel(fixture: f, manifest: f.manifest)
                _ = model.importSelected(context: context)
                XCTAssertNil(model.error)
            } else {
                let model = intentModel(fixture: f, manifest: f.manifest, saveContext: { try $0.save() })
                try model.setRemote(true, machineID: ProjectIntentHarness.remoteID, projectKey: "github.com/owner/project",
                    skill: skill, platform: .codex, context: context)
            }
            XCTAssertEqual(saves.pendingCount, 2, "The writer rebuilt while the edits still waited")
            XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(),
                ["Deleted", "Peer", "Waiting"], writer)
            XCTAssertEqual(skill.tags, ["waiting"], writer)
            await saves.waitUntilIdle()
            let saved = try f.manifest.read(fromRoot: f.app)
            XCTAssertEqual(saved.categories.map(\.name), ["Deleted", "Peer", "Waiting"])
            XCTAssertEqual(saved.skills.first { $0.slug == "item" }?.tags, ["waiting"])
        }
    }

    func testPausedEditDoesNotBlockCoordinatorSyncOrConflictResolution() async throws {
        for conflict in [false, true] {
            let f = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir + "/paused-\(conflict)") }
            let context = try damageContext(f)
            let library = queuedLibrary(f, context: context)
            let saves = try XCTUnwrap(library.manifestSaves)
            let category = try XCTUnwrap(try context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
            try f.files.writeFile(at: f.app + "/manifest/manifest.yaml", content: "damage")
            CategoryStore(manifestSaves: saves).rename(category, to: "Waiting", context: context)
            await saves.waitUntilIdle()
            XCTAssertEqual(saves.pendingCount, 1)
            try f.files.writeFile(at: f.app + "/manifest/manifest.yaml", content: "schema_version: 5\n")
            if conflict {
                try NativeTestWork.run {
                    try f.changePeer(conflict: true)
                    try f.files.writeFile(at: f.app + "/skills/item/SKILL.md",
                        content: "---\nname: Item\ndescription: Item\n---\nlocal body\n")
                }
                try NativeTestWork.run(container: context.container) { other in
                    let engine = f.engine(rebuild: StoreRebuildService())
                    guard case .conflicts(let set) = try engine.inspectConflicts(root: f.app, credential: nil,
                        context: other) else { return XCTFail("Expected a real body conflict") }
                    XCTAssertFalse(set.items.isEmpty)
                    let picks = Dictionary(uniqueKeysWithValues: set.items.map {
                        ($0.path, ResolutionPick(side: .thisMachine, expectedThis: $0.thisMachine,
                            expectedOther: $0.otherMachine, expectedThisMode: $0.thisMode, expectedOtherMode: $0.otherMode))
                    })
                    do {
                        guard case .synced = try engine.resolveConflicts(root: f.app, picks: picks,
                            credential: nil, context: other) else { return XCTFail("Paused edit blocked conflict completion") }
                        XCTAssertFalse(try f.git.isRebaseInProgress(at: f.app))
                    } catch { XCTFail("Paused edit blocked conflict resolution: \(error)") }
                }
            } else {
                let coordinator = await makeIncompleteCoordinator(container: context.container, fixture: f,
                    rebuild: IncompleteIngestRebuild())
                let result = await coordinator.runCycle()
                if case .synced = result {} else { XCTFail("Paused edit blocked sync: \(result)") }
            }
            XCTAssertEqual(saves.pendingCount, 1, "The real sync path ran with the edit still in the queue")
            await saves.refreshAndRetry()
            await saves.waitUntilIdle()
            XCTAssertEqual(saves.pendingCount, 0)
            XCTAssertTrue(try f.manifest.read(fromRoot: f.app).categories.contains { $0.name == "Waiting" })
        }
    }
}
