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
}
