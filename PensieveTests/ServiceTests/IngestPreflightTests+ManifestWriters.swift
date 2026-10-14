import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testImportAndProjectIntentAfterFailedPullKeepPeerCategoriesAndLocalEdit() async throws {
        try await assertRemovedDeploySelections()
        try await assertContentFreeWriterIngest()
        for importsSkill in [true, false] {
            for fault in WriterFault.allCases {
                try await assertWriterRecovery(importsSkill: importsSkill, fault: fault)
            }
        }
    }

    private func assertWriterRecovery(importsSkill: Bool, fault: WriterFault) async throws {
        let fixture = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/writer-\(importsSkill)-\(fault)")
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

        try assertWriterFailuresAndRetry(importsSkill: importsSkill, fault: fault, fixture: fixture, context: context)
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
                XCTAssertEqual(snapshot.skills.map(\.slug).sorted(), ["imported", "item"])
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

    private func assertWriterFailuresAndRetry(
        importsSkill: Bool, fault: WriterFault, fixture: IncompleteIngestFixture, context: ModelContext
    ) throws {
        let manifest = ControlledWriterManifest()
        manifest.failsRead = fault == .read
        if fault == .newerSchema {
            try fixture.files.writeFile(at: fixture.app + "/manifest/manifest.yaml", content: "schema_version: 999\n")
        }
        var failsSave = fault == .save
        let save: (ModelContext) throws -> Void = { context in
            if failsSave { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }
        let attempt: () -> Bool
        let reportedError: () -> String?
        if importsSkill {
            let model = importModel(fixture: fixture, manifest: manifest)
            attempt = {
                if case .refused = model.importSelected(context: context, saveContext: save) { return true }
                return false
            }
            reportedError = { model.error }
        } else {
            let model = intentModel(fixture: fixture, manifest: manifest, saveContext: save)
            let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
            attempt = { self.attemptIntentChange(model: model, skill: skill, context: context, fault: fault) }
            reportedError = { model.error }
        }
        for _ in 0..<2 {
            XCTAssertTrue(attempt(), "\(importsSkill ? "import" : "intent") must refuse a repeated \(fault) failure")
            let expected = fault == .save ? (importsSkill
                ? "Import couldn't update this Mac's library. Try importing again."
                : "Deployment couldn't update this Mac's library. Try deploying again.")
                : SyncError.storeUnreadable([]).localizedDescription
            XCTAssertEqual(reportedError(), expected)
            XCTAssertTrue(StoreIngestState.shared(for: context.container).needsRebuild)
            XCTAssertEqual(manifest.writes, 0, "refused ingestion must not reach the manifest writer")
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Skill>()), 1)
            XCTAssertFalse(fixture.files.directoryExists(at: fixture.app + "/skills/imported"))
        }
        failsSave = false
        manifest.failsRead = false
        if fault == .newerSchema {
            try fixture.files.writeFile(at: fixture.app + "/manifest/manifest.yaml",
                content: "schema_version: \(ManifestService.currentSchemaVersion)\n")
        }
        XCTAssertFalse(attempt(), "the same selection must recover after its dependency does")
        XCTAssertNil(reportedError())
        XCTAssertEqual(manifest.writes, 1)
    }

    private func attemptIntentChange(model: DeployIntentModel, skill: Skill,
                                     context: ModelContext, fault: WriterFault) -> Bool {
        do {
            try model.setRemote(true, machineID: "22222222-2222-4222-8222-222222222222",
                projectKey: "github.com/owner/project", skill: skill, platform: .codex, context: context)
            return false
        } catch {
            if fault != .save {
                guard case let SyncError.storeUnreadable(warnings) = error else {
                    XCTFail("Expected the unreadable-store explanation, got \(error)")
                    return true
                }
                XCTAssertFalse(warnings.isEmpty, "Retain the rebuild's diagnostic detail")
            }
            return true
        }
    }

    private func assertRemovedDeploySelections() async throws {
        for alreadyIngested in [false, true] {
            for action in RemovedSelectionAction.allCases {
                try await assertRemovedDeploySelection(action, alreadyIngested: alreadyIngested)
            }
        }
    }

    private func assertRemovedDeploySelection(_ action: RemovedSelectionAction, alreadyIngested: Bool) async throws {
        let fixture = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/removed-\(action)-\(alreadyIngested)", includingSurvivor: true)
        }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        try NativeTestWork.run(container: container) { context in
            _ = StoreRebuildService().rebuild(fromRoot: fixture.app, context: context)
            try fixture.files.deleteDirectory(at: fixture.peer + "/skills/item")
            try fixture.changePeer()
        }
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<Skill>())
        let selected = try XCTUnwrap(rows.first { $0.directoryName == "item" })
        let survivor = try XCTUnwrap(rows.first { $0.directoryName == "survivor" })
        let project = Project(name: "Project", path: fixture.base + "/project")
        project.identityKey = "github.com/owner/project"
        context.insert(project)
        try context.save()
        let rebuild = IncompleteIngestRebuild()
        rebuild.failWhenAddedCategoryExists = true
        let coordinator = await makeIncompleteCoordinator(container: container, fixture: fixture, rebuild: rebuild)
        let failed = await coordinator.runCycle()
        XCTAssertEqual(failed, .failed(IncompleteIngestFixture.message))
        if alreadyIngested {
            rebuild.failWhenAddedCategoryExists = false
            guard case .synced = await coordinator.runCycle() else { return XCTFail("earlier ingest failed") }
            XCTAssertFalse(StoreIngestState.shared(for: container).needsRebuild)
        }
        let (platform, links) = intentPlatform(fixture: fixture, installed: [.codex])
        var writes = 0
        let model = DeployIntentModel(platformVM: platform, dependencies: DeployIntentDependencies(
            identity: InertMachineIdentity(), stateService: InertMachineStateService(), root: fixture.app,
            writeManifest: { context in
                writes += 1
                try fixture.manifest.write(try fixture.manifest.snapshot(from: context), toRoot: fixture.app)
            }, notifier: {}, lockPath: fixture.base + "/sync.lock"))
        assertSelectionRefused(model) {
            try action.perform(model, skills: [survivor, selected], project: project, context: context)
        }
        XCTAssertEqual(writes, 0, "\(action): a removed selection must not write the manifest")
        XCTAssertTrue(links.linkCalls.isEmpty, "\(action): a removed selection must not deploy")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0, "\(action)")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).map(\.directoryName), ["survivor"],
                       "\(action): ingestion must keep the peer's skill removal")
        rebuild.failWhenAddedCategoryExists = false
        guard case .synced = await coordinator.runCycle() else { return XCTFail("sync after refusal failed") }
        try NativeTestWork.run { try fixture.assertRemoteCategories() }
        XCTAssertTrue(try fixture.manifest.read(fromRoot: fixture.app).deployIntents.isEmpty)
    }

    private func assertSelectionRefused(_ model: DeployIntentModel, action: () throws -> Void) {
        let message = "A selected skill was removed while the library updated. Choose the skills again."
        XCTAssertThrowsError(try action()) { error in
            XCTAssertEqual(error.localizedDescription, message)
            guard case DeployIntentModelError.selectionChanged = error else { return XCTFail("Wrong refusal: \(error)") }
        }
        XCTAssertEqual(model.error, message)
    }

    func importModel(fixture: IncompleteIngestFixture, manifest: ManifestSnapshotting) -> ImportViewModel {
        let scanner = ImportScanner(fileService: fixture.files,
            claudeSkillsDir: fixture.base + "/claude", grokSkillsDir: fixture.base + "/grok",
            cursorRulesDir: fixture.base + "/cursor", codexSkillsDir: fixture.base + "/codex", storeRoot: fixture.app)
        let model = ImportViewModel(scanner: scanner,
            skillStore: SkillStore(fileService: fixture.files, baseDir: fixture.app + "/skills", storeRoot: fixture.app),
            lockPath: fixture.base + "/sync.lock", manifestService: manifest, manifestRoot: fixture.app)
        model.discoveredSkills = [DiscoveredSkill(name: "Imported", body: "imported body", sourcePlatform: "cursor",
            sourcePath: fixture.base + "/cursor/imported.mdc", skillDescription: "Imported",
            cursorConfig: CursorAdapterConfig(globs: ["*.swift"], alwaysApply: false))]
        model.selectedSkills = [fixture.base + "/cursor/imported.mdc"]
        return model
    }

    func intentModel(fixture: IncompleteIngestFixture, manifest: ManifestSnapshotting,
                     saveContext: @escaping (ModelContext) throws -> Void) -> DeployIntentModel {
        let platform = intentPlatform(fixture: fixture, installed: []).platform
        return DeployIntentModel(platformVM: platform, dependencies: DeployIntentDependencies(
            identity: InertMachineIdentity(), stateService: InertMachineStateService(), root: fixture.app,
            manifestService: manifest,
            writeManifest: { context in try manifest.write(try manifest.snapshot(from: context), toRoot: fixture.app) },
            saveContext: saveContext, notifier: {}, lockPath: fixture.base + "/sync.lock"))
    }

    func intentPlatform(fixture: IncompleteIngestFixture, installed: [PlatformTarget])
        -> (platform: PlatformViewModel, links: DeployRecordingLinkService) {
        let files = DeployRecordingFileService()
        let links = DeployRecordingLinkService(fileService: files)
        let platform = PlatformViewModel(fileService: files, linkService: links,
            cursorCompiler: DeployRecordingCursorCompiler(fileService: files),
            agentDetection: DeployStubDetection(installed: installed), deployStateStore: .memoryBacked,
            skillsDirectory: fixture.app + "/skills")
        return (platform, links)
    }
}

private enum WriterFault: CaseIterable { case save, read, newerSchema }

/// Real manifest I/O with a controllable read refusal and a count of writes reaching the boundary.
private final class ControlledWriterManifest: ManifestSnapshotting {
    private let manifest = ManifestService()
    var failsRead = false
    private(set) var writes = 0
    func read(fromRoot root: String) throws -> ManifestSnapshot {
        if failsRead { throw CocoaError(.fileReadUnknown) }
        return try manifest.read(fromRoot: root)
    }
    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        writes += 1
        try manifest.write(snapshot, toRoot: root)
    }
    func snapshot(from context: ModelContext) throws -> ManifestSnapshot { try manifest.snapshot(from: context) }
}

private enum RemovedSelectionAction: CaseIterable {
    case remoteProject, local, localProject, projectBulk, selected, apply, retract

    @MainActor
    func perform(_ model: DeployIntentModel, skills: [Skill], project: Project, context: ModelContext) throws {
        let skill = try XCTUnwrap(skills.last)
        switch self {
        case .remoteProject:
            try model.setRemote(true, machineID: "22222222-2222-4222-8222-222222222222",
                projectKey: project.identityKey, skill: skill, platform: .codex, context: context)
        case .local:
            _ = try model.set(true, skill: skill, platform: .codex, target: .userWide, context: context)
        case .localProject:
            _ = try model.set(true, skill: skill, platform: .codex, target: .project(project), context: context)
        case .projectBulk:
            _ = try model.setProjectSelection(true, skills: skills, platforms: [.codex], project: project, context: context)
        case .selected:
            _ = try model.setSelected(true, machineID: InertMachineIdentity.value, skill: skill,
                                      platform: .codex, context: context)
        case .apply:
            _ = try model.apply(skills: skills, platforms: [.codex],
                                selectedMachineIDs: [InertMachineIdentity.value], context: context)
        case .retract:
            _ = try model.retract(skills: skills, platforms: [.codex], machineIDs: [InertMachineIdentity.value], context: context)
        }
    }
}
