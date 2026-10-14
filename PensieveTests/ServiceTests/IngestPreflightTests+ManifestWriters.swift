import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testImportAndProjectIntentAfterFailedPullKeepPeerCategoriesAndLocalEdit() async throws {
        for importsSkill in [true, false] {
            let fixture = try NativeTestWork.run {
                try IncompleteIngestFixture(base: self.tempDir + "/writer-\(importsSkill)")
            }
            let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            try NativeTestWork.run(container: container) { context in
                _ = StoreRebuildService().rebuild(fromRoot: fixture.app, context: context)
                try fixture.changePeer()
            }
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Deleted", "Kept"])
            let rebuild = IncompleteIngestRebuild()
            rebuild.failWhenAddedCategoryExists = true
            let coordinator = await makeIncompleteCoordinator(container: container, fixture: fixture, rebuild: rebuild)
            let failed = await coordinator.runCycle()
            XCTAssertEqual(failed, .failed(IncompleteIngestFixture.message))

            if importsSkill {
                importSkill(fixture: fixture, context: context)
            } else {
                try changeProjectIntent(fixture: fixture, context: context)
            }
            XCTAssertEqual(try fixture.manifest.read(fromRoot: fixture.app).categories.map(\.name).sorted(), ["Added", "Kept"],
                           "\(importsSkill ? "import" : "project intent") must not replace the pulled categories")
            rebuild.failWhenAddedCategoryExists = false
            guard case .synced = await coordinator.runCycle() else { return XCTFail("healthy sync failed") }
            try NativeTestWork.run {
                try fixture.assertRemoteCategories()
                let published = fixture.base + "/published"
                try fixture.git.clone(remote: fixture.remote, into: published, credential: nil)
                let snapshot = try fixture.manifest.read(fromRoot: published)
                if importsSkill {
                    let imported = try XCTUnwrap(snapshot.skills.first { $0.slug == "imported" })
                    XCTAssertEqual(imported.cursor, CursorAdapterConfig(globs: ["*.swift"], alwaysApply: false))
                    XCTAssertEqual(imported.origin, .imported(from: "cursor"))
                    XCTAssertTrue(fixture.files.fileExists(at: published + "/skills/imported/SKILL.md"))
                } else {
                    XCTAssertEqual(snapshot.deployIntents.map(\.projectKey), ["github.com/owner/project"])
                    XCTAssertEqual(snapshot.deployIntents.map(\.skillSlug), ["item"])
                }
            }
        }
    }

    private func importSkill(fixture: IncompleteIngestFixture, context: ModelContext) {
        let scanner = ImportScanner(fileService: fixture.files,
            claudeSkillsDir: fixture.base + "/claude", grokSkillsDir: fixture.base + "/grok",
            cursorRulesDir: fixture.base + "/cursor", codexSkillsDir: fixture.base + "/codex", storeRoot: fixture.app)
        let model = ImportViewModel(scanner: scanner,
            skillStore: SkillStore(fileService: fixture.files, baseDir: fixture.app + "/skills", storeRoot: fixture.app),
            lockPath: fixture.base + "/sync.lock", manifestService: fixture.manifest, manifestRoot: fixture.app)
        model.discoveredSkills = [DiscoveredSkill(name: "Imported", body: "imported body", sourcePlatform: "cursor",
            sourcePath: fixture.base + "/cursor/imported.mdc", skillDescription: "Imported",
            cursorConfig: CursorAdapterConfig(globs: ["*.swift"], alwaysApply: false))]
        model.selectedSkills = [fixture.base + "/cursor/imported.mdc"]
        model.importSelected(context: context)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.importedSkillCount, 1)
    }

    private func changeProjectIntent(fixture: IncompleteIngestFixture, context: ModelContext) throws {
        let files = DeployRecordingFileService()
        let platform = PlatformViewModel(fileService: files, linkService: DeployRecordingLinkService(fileService: files),
            cursorCompiler: DeployRecordingCursorCompiler(fileService: files),
            agentDetection: DeployStubDetection(installed: []), deployStateStore: .memoryBacked,
            skillsDirectory: fixture.app + "/skills")
        let model = DeployIntentModel(platformVM: platform, dependencies: .live(
            identity: InertMachineIdentity(), stateService: InertMachineStateService(), root: fixture.app,
            lockPath: fixture.base + "/sync.lock", notifier: {}, reconcile: { _ in BatchResult() }))
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        try model.setRemote(true, machineID: "22222222-2222-4222-8222-222222222222",
            projectKey: "github.com/owner/project", skill: skill, platform: .codex, context: context)
    }
}
