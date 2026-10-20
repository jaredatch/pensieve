import SwiftData
import XCTest
@testable import Pensieve

extension ConflictResolutionModelTests {
    func testFailedConflictFinishReportsReasonAndRetryPreservesPeerCategories() async throws {
        let base = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString).path
        let fixture = try NativeTestWork.run { try IncompleteIngestFixture(base: base) }
        defer { try? fixture.files.deleteDirectory(at: base) }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let rebuild = IncompleteIngestRebuild()
        let engine = fixture.engine(rebuild: rebuild)
        try NativeTestWork.run(container: container) { context in
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: fixture.app, context: context)
            try fixture.changePeer(conflict: true)
            try fixture.files.writeFile(at: fixture.app + "/skills/item/SKILL.md",
                                        content: "---\nname: Item\ndescription: Item\n---\nthis body\n")
            guard case .conflicted = try engine.sync(root: fixture.app, message: "conflict", credential: nil,
                                                      context: context) else { return XCTFail("no real conflict") }
        }
        let sync = SyncModel(git: fixture.git, root: fixture.app)
        sync.apply(.conflicted(["skills/item/SKILL.md"]))
        let model = ConflictResolutionModel(engine: engine, git: fixture.git, credentials: IngestEmptyCredentials(),
            root: fixture.app, steps: SyncStepModel(), onResolutionStarted: { { sync.apply($0) } })
        let saves = try await refuseCursorMetadata(fixture, container: container)
        defer { withExtendedLifetime(saves) {} }
        await model.loadAndReport(container: container)
        let groups = try readyGroups(from: model.phase)
        let inspected = try XCTUnwrap(try fixture.manifest.read(fromRoot: fixture.app).skills.first { $0.slug == "item" })
        XCTAssertEqual(inspected.cursor, CursorAdapterConfig(globs: ["*.swift"], alwaysApply: false))
        XCTAssertEqual(inspected.origin, .imported(from: "cursor"))
        XCTAssertEqual(groups.flatMap(\.items).map(\.path), ["skills/item/SKILL.md"])
        model.choose("skill:item", .thisMachine)
        rebuild.failWhenAddedCategoryExists = true
        let remoteBefore = try NativeTestWork.run { try fixture.remoteHead() }
        await model.applyAndReport(container: container)
        XCTAssertEqual(model.phase, .error(IncompleteIngestFixture.message))
        XCTAssertTrue(sync.isConflicted, "a failed finish must not report success to the sync model")
        XCTAssertEqual(try NativeTestWork.run { try fixture.remoteHead() }, remoteBefore)
        XCTAssertEqual(try fixture.manifest.read(fromRoot: fixture.app).categories.map(\.name).sorted(), ["Added", "Kept"])

        rebuild.failWhenAddedCategoryExists = false
        await model.loadAndReport(container: container)
        XCTAssertEqual(model.phase, .empty, "retry inspection finishes the already resolved rebase")
        XCTAssertFalse(sync.isConflicted)
        try NativeTestWork.run { try fixture.assertRemoteCategories() }
        let retried = try XCTUnwrap(try fixture.manifest.read(fromRoot: fixture.app).skills.first { $0.slug == "item" })
        XCTAssertEqual(retried.cursor, CursorAdapterConfig(globs: ["*.swift"], alwaysApply: false))
        XCTAssertEqual(retried.origin, .imported(from: "cursor"))
        try NativeTestWork.run(container: container) { context in
            guard case .synced = try engine.sync(root: fixture.app, message: "ordinary", credential: nil,
                                                 context: context) else { return XCTFail("ordinary sync stayed blocked") }
        }
    }

    private func refuseCursorMetadata(_ fixture: IncompleteIngestFixture,
                                      container: ModelContainer) async throws -> ManifestSaveModel {
        // Submit the saved metadata through the production queue and refuse its manifest write.
        let context = ModelContext(container)
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        let cursor = CursorAdapterConfig(globs: ["*.swift"], alwaysApply: false)
        skill.cursorConfig = cursor
        skill.importedFrom = "cursor"
        try context.save()
        let manifest = RecordingSaveManifest()
        manifest.failingWrites = 1
        let saves = ManifestSaveModel(manifest: manifest, root: fixture.app, lockPath: fixture.base + "/sync.lock")
        var refusal: Error?
        saves.submit(.skillMetadata("item", nil, nil, cursor: .some(cursor), origin: .imported(from: "cursor")),
                     context: context) { refusal = $0 }
        await saves.waitUntilIdle()
        XCTAssertNotNil(refusal)
        XCTAssertEqual(saves.refused.count, 1)
        XCTAssertTrue(manifest.writes.isEmpty)
        return saves
    }

    func testRefusedMetadataSurvivesInspectionRebuildAndRetiresAfterAcknowledgement() async throws {
        let base = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString).path
        let f = try NativeTestWork.run { try IncompleteIngestFixture(base: base) }
        defer { try? f.files.deleteDirectory(at: base) }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let rebuild = IncompleteIngestRebuild()
        let engine = f.engine(rebuild: rebuild)
        try NativeTestWork.run(container: container) { context in
            guard case .synced = try engine.sync(root: f.app, message: "seed overlay", credential: nil,
                                                 context: context) else { return XCTFail("Initial sync failed") }
            _ = try f.git.fastForwardOnly(at: f.peer, credential: nil)
        }
        let context = ModelContext(container)
        let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first)
        let manifest = RecordingSaveManifest()
        manifest.failingWrites = 1
        let saves = ManifestSaveModel(manifest: manifest, root: f.app, lockPath: base + "/sync.lock")
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: f.files, baseDir: f.app + "/skills", storeRoot: f.app),
            fileWatchService: FileWatchService(rootDir: f.app + "/skills"), manifestRoot: f.app, manifestSaves: saves)
        library.updateMetadata(skill, tags: ["refused"], scope: .project, context: context)
        await saves.waitUntilIdle()
        XCTAssertNotNil(library.error)
        XCTAssertEqual(saves.refused.count, 1)
        try NativeTestWork.run {
            try f.files.writeFile(at: f.peer + "/skills/item/SKILL.md",
                content: "---\nname: Item\ndescription: Item\n---\nother body\n")
            _ = try f.git.stageAllAndCommit(at: f.peer, message: "peer body")
            try f.git.push(at: f.peer, credential: nil)
            try f.files.writeFile(at: f.app + "/skills/item/SKILL.md",
                content: "---\nname: Item\ndescription: Outside description\n---\nthis body\n")
            _ = try f.git.stageAllAndCommit(at: f.app, message: "outside edit")
        }
        let model = ConflictResolutionModel(engine: engine, git: f.git, credentials: IngestEmptyCredentials(),
            root: f.app, steps: SyncStepModel())
        let before = rebuild.calls
        await model.loadAndReport(container: container)
        let groups = try readyGroups(from: model.phase)
        XCTAssertGreaterThan(rebuild.calls, before, "Inspection must rebuild after the outside commit")
        XCTAssertEqual(groups.flatMap(\.items).map(\.path), ["skills/item/SKILL.md"])
        let inspected = try XCTUnwrap(f.manifest.read(fromRoot: f.app).skills.first { $0.slug == "item" })
        XCTAssertEqual(inspected.tags, ["refused"], "Inspection must publish the refused window field")
        XCTAssertEqual(inspected.scope, .project)
        XCTAssertFalse(StoreIngestState.shared(for: container).needsRebuild)
        model.choose("skill:item", .thisMachine)
        await model.applyAndReport(container: container)
        XCTAssertEqual(model.phase, .done, "A retained refusal must not fence conflict finish or push")
        let published = base + "/published"
        try NativeTestWork.run { try f.git.clone(remote: f.remote, into: published, credential: nil) }
        XCTAssertEqual(try f.manifest.read(fromRoot: published).skills.first?.tags, ["refused"])
        try await assertRefusalAcknowledgement(library, skill: skill, saves: saves, fixture: f, container: container)
    }

    private func assertRefusalAcknowledgement(_ library: SkillLibraryViewModel, skill: Skill, saves: ManifestSaveModel,
                                              fixture f: IncompleteIngestFixture, container: ModelContainer) async throws {
        let context = try XCTUnwrap(skill.modelContext)
        // A subsequent save's disk read acknowledges the published fields. A later outside
        // edit must then reach a rebuild without an obsolete refused projection overwriting it.
        library.updateMetadata(skill, tags: ["refused"], scope: .project, context: context)
        await saves.waitUntilIdle()
        XCTAssertTrue(saves.refused.isEmpty)
        try NativeTestWork.run(container: container) { worker in
            var disk = try f.manifest.read(fromRoot: f.app)
            disk.skills[0].tags = ["outside-after-ack"]
            disk.skills[0].scope = .user
            try f.manifest.write(disk, toRoot: f.app)
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: f.app, context: worker)
            let observed = try XCTUnwrap(worker.fetch(FetchDescriptor<Skill>()).first)
            XCTAssertEqual(observed.tags, ["outside-after-ack"])
            XCTAssertEqual(observed.scope, .user)
        }
    }

}
