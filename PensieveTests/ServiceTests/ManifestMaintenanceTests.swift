import SwiftData
import XCTest
@testable import Pensieve

/// FileService whose writes/dir-creates always throw — to prove a manifest failure is surfaced, not silent.
private struct ThrowingWriteFileService: FileServiceProtocol {
    struct Boom: Error {}
    func readFile(at path: String) throws -> String { "" }
    func writeFile(at path: String, content: String) throws { throw Boom() }
    func deleteFile(at path: String) throws {}
    func fileExists(at path: String) -> Bool { false }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { false }
    func createDirectory(at path: String) throws { throw Boom() }
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
    func symlinkTarget(at path: String) throws -> String { "" }
    func isSymlink(at path: String) -> Bool { false }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String { "" }
}

/// Reconciler that always succeeds with an empty batch (project-remove path needs a clean reconcile).
private struct NoopReconciler: CategoryReconcilerProtocol {
    func reconcileRemovingProject(_ projectID: UUID, preservingProjects: Set<UUID>, context: ModelContext) -> BatchResult {
        reconcile(context: context)
    }

    func reconcile(context: ModelContext) -> BatchResult { BatchResult() }
}

final class ManifestMaintenanceTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var manifest: ManifestService!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveManifestMaint-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        manifest = ManifestService(fileService: fileService)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
    }

    @MainActor
    private func seedProjectIntent(_ context: ModelContext) throws {
        context.insert(MachineDeployIntent(
            machineID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
            skillSlug: "durable-intent",
            platformRaw: "codex",
            projectKey: "github.com/owner/project"
        ))
        try context.save()
    }

    private func assertProjectIntentSurvives(file: StaticString = #filePath, line: UInt = #line) throws {
        let records = try manifest.read(fromRoot: tempDir).deployIntents
        XCTAssertEqual(records.count, 1, file: file, line: line)
        XCTAssertEqual(records.first?.projectKey, "github.com/owner/project", file: file, line: line)
    }

    private func overlayExists(slug: String) -> Bool {
        fileService.fileExists(at: tempDir + "/manifest/skills/\(slug).yaml")
    }

    // MARK: - Skills

    @MainActor
    func testCreatingSkillWritesOverlay() throws {
        let context = try makeContext()
        let store = SkillStore(fileService: fileService, baseDir: tempDir + "/skills")
        let vm = SkillLibraryViewModel(skillStore: store, manifestService: manifest, manifestRoot: tempDir)
        vm.createSkill(name: "My Skill", description: "d", body: "# b", tags: ["x"], context: context)
        XCTAssertTrue(overlayExists(slug: "my-skill"))
        let read = try manifest.read(fromRoot: tempDir)
        XCTAssertEqual(read.skills.first { $0.slug == "my-skill" }?.tags, ["x"])
    }

    @MainActor
    func testCreatingSkillUsesUserScopeInRecordAndOverlay() throws {
        let context = try makeContext()
        let store = SkillStore(fileService: fileService, baseDir: tempDir + "/skills")
        let vm = SkillLibraryViewModel(skillStore: store, manifestService: manifest, manifestRoot: tempDir)

        vm.createSkill(name: "Scoped", description: "d", body: "# b", tags: [], context: context)

        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(record.scope, .user)
        let overlay = try XCTUnwrap(try manifest.read(fromRoot: tempDir).skills.first { $0.slug == "scoped" })
        XCTAssertEqual(overlay.scope, .user)
    }

    /// Bulk-import regression: bulk import used to write SKILL.md + SwiftData rows but NO manifest
    /// overlay. Once PLAN-12 / 12.3 made the launch rebuild treat the manifest as
    /// authoritative, that deferral became a data-loss path: fresh-install → import → relaunch rebuilt the
    /// imported skills off an overlay-less manifest and reset their `cursorConfig`/`importedFrom`/tags/scope
    /// to defaults. Import must now regenerate the overlay, so it survives the next rebuild.
    @MainActor
    func testImportWritesOverlayWithCursorAndOrigin() throws {
        let context = try makeContext()
        try seedProjectIntent(context)
        let store = SkillStore(fileService: fileService, baseDir: tempDir + "/skills")
        let vm = ImportViewModel(skillStore: store, manifestService: manifest, manifestRoot: tempDir)
        let discovered = DiscoveredSkill(
            name: "Imported Skill",
            body: "# imported body",
            sourcePlatform: "claude",
            sourcePath: "/some/source/imported-skill",
            skillDescription: "an imported skill",
            cursorConfig: CursorAdapterConfig(description: "cfg", globs: ["*.swift"], alwaysApply: false)
        )
        vm.discoveredSkills = [discovered]
        vm.selectedSkills = [discovered.sourcePath]
        vm.importSelected(context: context)

        // The imported skill's row lands in SwiftData...
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).count, 1)
        // ...and its manifest overlay exists with the Cursor config + imported origin preserved. Without the
        // regenerate call this overlay is absent, so a launch rebuild would reset these to defaults.
        let overlay = try XCTUnwrap(try manifest.read(fromRoot: tempDir).skills.first { $0.origin != .authored })
        XCTAssertNotNil(overlay.cursor)
        XCTAssertEqual(overlay.origin, .imported(from: "claude"))
        try assertProjectIntentSurvives()
        XCTAssertNil(vm.error)
    }

    @MainActor
    func testUpdatingMetadataReflectsInOverlay() throws {
        let context = try makeContext()
        try seedProjectIntent(context)
        let store = SkillStore(fileService: fileService, baseDir: tempDir + "/skills")
        let vm = SkillLibraryViewModel(skillStore: store, manifestService: manifest, manifestRoot: tempDir)
        vm.createSkill(name: "Editable", description: "d", body: "# b", tags: [], context: context)
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        vm.updateMetadata(skill, tags: ["edited"], scope: .project, context: context)
        let overlay = try XCTUnwrap(try manifest.read(fromRoot: tempDir).skills.first { $0.slug == "editable" })
        XCTAssertEqual(overlay.tags, ["edited"])
        XCTAssertEqual(overlay.scope, .project)
        try assertProjectIntentSurvives()
    }

    @MainActor
    func testDeletingSkillPrunesOverlay() throws {
        let context = try makeContext()
        let store = SkillStore(fileService: fileService, baseDir: tempDir + "/skills")
        let vm = SkillLibraryViewModel(skillStore: store, manifestService: manifest, manifestRoot: tempDir)
        vm.createSkill(name: "Doomed", description: "d", body: "# b", tags: [], context: context)
        XCTAssertTrue(overlayExists(slug: "doomed"))
        let legacyPath = tempDir + "/manifest/scenarios/legacy.yaml"
        let legacyBytes = Data([255, 0, 10]) + Data("name: Old\nskill_slugs: [doomed]\n".utf8)
        try fileService.writeData(at: legacyPath, data: legacyBytes)
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertTrue(SkillDeletionFlow.delete(
            skill: skill, library: vm,
            platformVM: PlatformViewModel(agentDetection: DeployStubDetection(installed: []),
                                          deployStateStore: .memoryBacked),
            projects: [], context: context
        ))
        XCTAssertFalse(overlayExists(slug: "doomed"))
        XCTAssertEqual(try fileService.readData(at: legacyPath), legacyBytes)
    }

    @MainActor
    func testManifestFailureIsSurfacedButMutationSucceeds() throws {
        let context = try makeContext()
        let store = SkillStore(fileService: fileService, baseDir: tempDir + "/skills")
        let failing = ManifestService(fileService: ThrowingWriteFileService())
        let vm = SkillLibraryViewModel(skillStore: store, manifestService: failing, manifestRoot: tempDir)
        vm.createSkill(name: "Resilient", description: "d", body: "# b", tags: [], context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).count, 1)
        XCTAssertNotNil(vm.error)
    }

    // MARK: - Categories

    @MainActor
    func testCategoryCreateEditDeleteMaintainsManifest() throws {
        let context = try makeContext()
        try seedProjectIntent(context)
        let store = CategoryStore(manifestService: manifest, manifestRoot: tempDir)
        let category = try XCTUnwrap(store.create(name: "Swift", context: context))
        let file = tempDir + "/manifest/categories/" + ManifestService.categoryFileName("Swift")
        XCTAssertTrue(fileService.fileExists(at: file))

        let skill = Skill(name: "S", directoryName: "swift-style")
        context.insert(skill)
        store.setSkill(skill, inCategory: category, assigned: true, context: context)
        XCTAssertTrue(try fileService.readFile(at: file).contains("swift-style"))

        store.delete(category, context: context)
        XCTAssertFalse(fileService.fileExists(at: file))
        try assertProjectIntentSurvives()
    }

    // MARK: - Projects

    @MainActor
    func testRegisterAndRemoveProjectMaintainsProjectsYaml() throws {
        let context = try makeContext()
        try seedProjectIntent(context)
        let project = Project(name: "App", path: "/tmp/app")
        project.identityKey = "git:github.com/me/app"
        project.identityKind = "remote"

        registerProject(project, manifestService: manifest, manifestRoot: tempDir, context: context)
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/manifest/projects.yaml"), "projects:\n")
        let intentPath = tempDir + "/manifest/deploys/AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA/durable-intent.yaml"
        let intentBytesBeforeRemoval = try fileService.readFile(at: intentPath)

        _ = removeRegisteredProject(
            project,
            reconciler: NoopReconciler(),
            manifestService: manifest,
            manifestRoot: tempDir,
            platformVM: PlatformViewModel(fileService: fileService,
                agentDetection: DeployStubDetection(installed: []), deployStateStore: .memoryBacked),
            localMachineID: ProjectIntentHarness.localID,
            context: context
        )
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/manifest/projects.yaml"), "projects:\n")
        XCTAssertEqual(try fileService.readFile(at: intentPath), intentBytesBeforeRemoval)
        try assertProjectIntentSurvives()
    }
}
