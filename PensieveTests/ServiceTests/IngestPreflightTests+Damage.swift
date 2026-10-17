import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testDamagedManifestRefusesSyncConflictMigrationImportDeployAndRemovalAtSameHead() async throws {
        for writer in ["sync", "conflict retry", "migration", "import", "deploy", "removal"] {
            let f = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir + "/" + writer) }
            let context = try damageContext(f)
            let head = GitHeadStamp().read(root: f.app)
            try f.files.writeFile(at: f.app + "/manifest/manifest.yaml", content: "damaged")
            let before = try ManifestSaveFixture.manifestBytes(root: f.app, files: f.files)
            XCTAssertFalse(StoreIngestState.shared(for: context.container).needsRebuild)
            switch writer {
            case "sync":
                await checkDamagedSync(f, context: context, head: head)
            case "conflict retry":
                try NativeTestWork.run(container: context.container) { other in
                    XCTAssertThrowsError(try f.engine(rebuild: StoreRebuildService()).resolveConflicts(
                        root: f.app, picks: [:], credential: nil, context: other))
                }
            case "migration":
                let result = StoreMigrationService(skillStore: SkillStore(fileService: f.files,
                    baseDir: f.app + "/skills", storeRoot: f.app)).migrateIfNeeded(fromRoot: f.app, context: context)
                XCTAssertFalse(result.manifestWritten)
                XCTAssertTrue(result.warnings.contains { $0.contains("damaged") })
            case "import":
                let model = importModel(fixture: f, manifest: f.manifest)
                _ = model.importSelected(context: context)
                XCTAssertNotNil(model.error)
            case "deploy":
                let model = intentModel(fixture: f, manifest: f.manifest, saveContext: { try $0.save() })
                let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
                XCTAssertThrowsError(try model.setRemote(true, machineID: ProjectIntentHarness.remoteID,
                    projectKey: "github.com/owner/project", skill: skill, platform: .codex, context: context))
            default:
                let project = Project(name: "Local", path: f.base + "/project")
                try f.files.createDirectory(at: project.path)
                context.insert(project)
                try context.save()
                let platform = intentPlatform(fixture: f, installed: []).platform
                let result = removeRegisteredProject(project, reconciler: NoopProjectCategoryReconciler(),
                    manifestService: f.manifest, manifestRoot: f.app, platformVM: platform,
                    context: context, lockPath: f.base + "/sync.lock")
                XCTAssertTrue(result.hasFailures)
                XCTAssertTrue(try context.fetch(FetchDescriptor<Project>()).contains { $0.id == project.id })
            }
            XCTAssertEqual(try ManifestSaveFixture.manifestBytes(root: f.app, files: f.files), before, writer)
            XCTAssertEqual(GitHeadStamp().read(root: f.app), head, writer)
        }
    }

    private func checkDamagedSync(_ f: IncompleteIngestFixture, context: ModelContext, head: String?) async {
        let coordinator = await makeIncompleteCoordinator(container: context.container, fixture: f,
            rebuild: IncompleteIngestRebuild())
        await coordinator.seedLastIngestedHeadStamp(head)
        let result = await coordinator.runCycle()
        guard case .manifestDamaged(let message) = result else { return XCTFail("Expected damage: \(result)") }
        let library = queuedLibrary(f, context: context)
        library.applySyncCycleOutcome(result)
        XCTAssertFalse(library.categoryEditsFenced, "A damage cycle must not fence category edits")
        XCTAssertTrue(library.addsFenced)
        XCTAssertEqual(library.addFenceReason,
            "Pensieve can't add to this library until the damaged library file is repaired.")
        XCTAssertTrue(message.contains("damaged"))
        XCTAssertFalse(message.contains("newer"))
        StoreIngestState.shared(for: context.container).invalidate()
        guard case .manifestDamaged(let retryMessage) = await coordinator.runCycle() else {
            return XCTFail("Pending ingestion must still report the damaged file")
        }
        XCTAssertTrue(retryMessage.contains("damaged"))
        XCTAssertFalse(retryMessage.contains("newer"))
    }

    func testRepairPushesWaitingCategoryAndSkillEdits() async throws {
        let f = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir + "/repair") }
        let context = try damageContext(f)
        let library = queuedLibrary(f, context: context)
        let saves = try XCTUnwrap(library.manifestSaves)
        let category = try XCTUnwrap(try context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        try f.files.writeFile(at: f.app + "/manifest/manifest.yaml", content: "damaged")
        CategoryStore(manifestSaves: saves).rename(category, to: "Edited", context: context)
        library.updateMetadata(skill, tags: ["waiting"], scope: .user, context: context)
        await saves.waitUntilIdle()
        saves.requestRepair()
        await saves.replaceWithThisMac(context: context)
        await saves.waitUntilIdle()
        XCTAssertNil(saves.repairError)
        let coordinator = await makeIncompleteCoordinator(container: context.container, fixture: f,
            rebuild: IncompleteIngestRebuild())
        guard case .synced = await coordinator.runCycle() else { return XCTFail("The repaired library must sync") }
        let fresh = f.base + "/fresh"
        try NativeTestWork.run { try f.git.clone(remote: f.remote, into: fresh, credential: nil) }
        let remote = try f.manifest.read(fromRoot: fresh)
        XCTAssertEqual(remote.categories.map(\.name), ["Deleted", "Edited"])
        XCTAssertEqual(remote.skills.first?.tags, ["waiting"])
    }

    func testPeerRepairResumesWaitingEditsWithoutLocalRepair() async throws {
        let f = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir + "/peer-repair") }
        let context = try damageContext(f)
        let library = queuedLibrary(f, context: context)
        let saves = try XCTUnwrap(library.manifestSaves)
        // The damaged file is already synced; a later remote commit replaces it normally.
        try NativeTestWork.run {
            try f.files.writeFile(at: f.app + "/manifest/manifest.yaml", content: "damaged")
            _ = try f.git.stageAllAndCommit(at: f.app, message: "damaged file")
            try f.git.push(at: f.app, credential: nil)
            _ = try f.git.fastForwardOnly(at: f.peer, credential: nil)
        }
        let category = try XCTUnwrap(try context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
        CategoryStore(manifestSaves: saves).rename(category, to: "Waiting", context: context)
        await saves.waitUntilIdle()
        XCTAssertTrue(saves.libraryDamaged)
        XCTAssertTrue(library.addsFenced)
        XCTAssertFalse(library.categoryEditsFenced)
        try NativeTestWork.run {
            try f.files.writeFile(at: f.peer + "/manifest/manifest.yaml", content: "schema_version: 5\n")
            try f.changePeer()
            _ = try f.git.fastForwardOnly(at: f.app, credential: nil)
        }
        await saves.refreshAndRetry()
        await saves.waitUntilIdle()
        XCTAssertFalse(saves.libraryDamaged)
        XCTAssertFalse(library.addsFenced, "A readable peer file lifts the damage fence")
        XCTAssertEqual(saves.pendingCount, 0)
        XCTAssertEqual(try f.manifest.read(fromRoot: f.app).categories.map(\.name), ["Added", "Waiting"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Added", "Waiting"])
    }

    func damageContext(_ fixture: IncompleteIngestFixture) throws -> ModelContext {
        let context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: fixture.app, context: context)
        return context
    }

    func queuedLibrary(_ f: IncompleteIngestFixture, context: ModelContext) -> SkillLibraryViewModel {
        let saves = ManifestSaveModel(manifest: f.manifest, root: f.app, lockPath: f.base + "/sync.lock", waitSeconds: 0.01)
        return SkillLibraryViewModel(skillStore: SkillStore(fileService: f.files, baseDir: f.app + "/skills", storeRoot: f.app),
            fileWatchService: FileWatchService(rootDir: f.app + "/skills"), manifestRoot: f.app, manifestSaves: saves)
    }
}
