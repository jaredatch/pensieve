import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testRebuildOwnerReadsHeadExactlyBeforeAndAfterTheScan() throws {
        let files = RebuildReadFileService()
        let h = try ManifestSaveFixture(rebuildFiles: files)
        defer { h.cleanup() }
        try NativeTestWork.run { try TestPaths.git.initRepository(at: h.root) }
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(fileService: files),
                                        root: h.root, context: h.context, files: files)
        XCTAssertEqual(files.headReads.value, 2, "One owner samples HEAD around each rebuild")
    }

    func testFirstQueuedSaveAfterPullScansSkillsOnce() async throws {
        let f = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir + "/one-queue-scan") }
        let context = try damageContext(f)
        try NativeTestWork.run {
            try f.changePeer()
            guard case .fastForwarded = try f.git.fastForwardOnly(at: f.app, credential: nil) else {
                return XCTFail("Fixture must pull an outside commit")
            }
        }
        let files = RebuildReadFileService()
        let saves = ManifestSaveModel(manifest: f.manifest, root: f.app, lockPath: f.base + "/sync.lock", files: files)
        let category = try XCTUnwrap(context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
        CategoryStore(manifestSaves: saves).rename(category, to: "Edited", context: context)
        await saves.waitUntilIdle()
        XCTAssertNil(saves.categoryNotice)
        XCTAssertEqual(files.skillListings.value, 1, "Pre-save ingestion and post-save acceptance share one scan")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).map(\.directoryName), ["item"],
                       "Reusing the scan must retain canonical skills without an explicit manifest overlay")
        XCTAssertEqual(try f.manifest.read(fromRoot: f.app).categories.map(\.name).sorted(), ["Added", "Edited"])
    }

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
}
