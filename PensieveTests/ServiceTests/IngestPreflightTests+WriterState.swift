import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func assertContentFreeWriterIngest() async throws {
        for path in ["import", "intent", "sync"] {
            let fixture = try NativeTestWork.run {
                try IncompleteIngestFixture(base: self.tempDir + "/content-free-" + path)
            }
            let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            _ = StoreRebuildService().rebuild(fromRoot: fixture.app, context: context)
            context.insert(MachineDeployIntent(machineID: InertMachineIdentity.value,
                skillSlug: "item", platformRaw: "codex", projectKey: "github.com/owner/kept"))
            try context.save()
            try fixture.files.deleteDirectory(at: fixture.app + "/manifest")
            try fixture.files.writeFile(at: fixture.app + "/manifest/manifest.yaml", content: "schema_version: 1\n")
            StoreIngestState.shared(for: container).invalidate()
            if path == "import" {
                let model = importModel(fixture: fixture, manifest: fixture.manifest)
                if case .refused = model.importSelected(context: context) { XCTFail(model.error ?? "import refused") }
            } else if path == "intent" {
                let model = intentModel(fixture: fixture, manifest: fixture.manifest, saveContext: { try $0.save() })
                try model.setRemote(true, machineID: "22222222-2222-4222-8222-222222222222",
                    projectKey: "github.com/owner/new", skill: XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first),
                    platform: .codex, context: context)
            } else {
                let coordinator = await makeIncompleteCoordinator(container: container, fixture: fixture,
                                                                  rebuild: IncompleteIngestRebuild())
                guard case .synced = await coordinator.runCycle() else { return XCTFail("content-free sync failed") }
            }
            XCTAssertTrue(try fixture.manifest.read(fromRoot: fixture.app).deployIntents.contains {
                $0.projectKey == "github.com/owner/kept"
            }, "\(path) must preserve local intents when the manifest has no authority")
        }
    }

    func assertQueuedWriterEdits() async throws {
        for importsSkill in [true, false] {
            for refusesQueue in [false, true] {
                try await assertQueuedWriterEdit(importsSkill: importsSkill, refusesQueue: refusesQueue)
            }
        }
    }

    private func assertQueuedWriterEdit(importsSkill: Bool, refusesQueue: Bool) async throws {
        let fixture = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/queued-\(importsSkill)-\(refusesQueue)")
        }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        _ = StoreRebuildService().rebuild(fromRoot: fixture.app, context: context)
        let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first)
        try fixture.manifest.write(fixture.manifest.snapshot(from: context), toRoot: fixture.app)
        let recording = RecordingSaveManifest()
        recording.failingWrites = refusesQueue ? 2 : 0
        let saves = ManifestSaveModel(manifest: recording, root: fixture.app, lockPath: fixture.base + "/sync.lock")
        StoreIngestState.shared(for: container).invalidate()
        skill.tags = ["queued"]
        skill.scope = .project
        try context.save()
        saves.submit(.skillMetadata("item", ["queued"], nil), context: context) { _ in }
        saves.submit(.skillMetadata("item", nil, .project), context: context) { _ in }
        let attempt = writerAttempt(importsSkill: importsSkill, fixture: fixture, context: context, skill: skill)
        XCTAssertTrue(attempt(), "pending ingestion must wait for unpublished edits")
        XCTAssertEqual(skill.tags, ["queued"])
        XCTAssertEqual(skill.scope, .project)
        XCTAssertTrue(StoreIngestState.shared(for: container).needsRebuild)
        await saves.waitUntilIdle()
        if refusesQueue {
            XCTAssertTrue(recording.writes.isEmpty)
            XCTAssertTrue(attempt(), "a refused queued edit still needs protection")
            XCTAssertEqual(skill.tags, ["queued"])
            XCTAssertEqual(skill.scope, .project)
            saves.submit(.skillMetadata("item", ["queued"], .project), context: context) { _ in }
            await saves.waitUntilIdle()
        }
        XCTAssertEqual(recording.writes.count, refusesQueue ? 1 : 2)
        XCTAssertFalse(attempt(), "the writer can retry after the queue saves")
        XCTAssertEqual(skill.tags, ["queued"])
        XCTAssertEqual(skill.scope, .project)
        let snapshot = try fixture.manifest.read(fromRoot: fixture.app)
        XCTAssertEqual(snapshot.skills.first { $0.slug == "item" }?.tags, ["queued"])
        XCTAssertEqual(snapshot.skills.first { $0.slug == "item" }?.scope, .project)
    }

    private func writerAttempt(importsSkill: Bool, fixture: IncompleteIngestFixture,
                               context: ModelContext, skill: Skill) -> () -> Bool {
        if importsSkill {
            let model = importModel(fixture: fixture, manifest: fixture.manifest)
            return { if case .refused = model.importSelected(context: context) { return true }; return false }
        }
        let model = intentModel(fixture: fixture, manifest: fixture.manifest, saveContext: { try $0.save() })
        return {
            do {
                try model.setRemote(true, machineID: "22222222-2222-4222-8222-222222222222",
                    projectKey: "github.com/owner/project", skill: skill, platform: .codex, context: context)
                return false
            } catch { return true }
        }
    }
}
