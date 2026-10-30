import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillRenameFlowTests: XCTestCase {
    private let original = "\u{feff}---\r\nname: alpha  # keep\r\ndescription: 'Alpha''s job'\r\n"
        + "metadata:\r\n  owner: me\r\n  flags: [one, two]\r\n---\r\n\r\nThe body.\r\n"
    private let script = Data([35, 33, 0, 255, 10])
    private struct Fixture {
        let context: ModelContext
        let skill: Skill
        let store: SkillStore
        let files: FileService
        let library: SkillLibraryViewModel
        let platform: PlatformViewModel
        let state: DeployStateStore
        let watcher: RecordingWatcher
        let projects: [Project]
        let category: Pensieve.Category
        let pairs: [(PlatformTarget, Project?)]
        let root: String
    }

    private func fixture() throws -> Fixture {
        let files = FileService(), root = TestPaths.storeRoot
        try files.createDirectory(at: root)
        addTeardownBlock { try? files.deleteDirectory(at: TestPaths.root) }
        let context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        let store = SkillStore(fileService: files, baseDir: TestPaths.skillsDir, storeRoot: root)
        _ = try store.createSkill(name: "alpha", description: "Alpha's job", body: "The body.")
        try store.writeBody(directoryName: "alpha", body: original)
        try files.writeData(at: store.baseDir + "/alpha/scripts/run.sh", data: script)
        let skill = Skill(name: "alpha", skillDescription: "Alpha's job", directoryName: "alpha")
        context.insert(skill)
        let projects = try ["keyed", "category", "keyless"].map { name -> Project in
            let project = Project(name: name, path: TestPaths.root + "/" + name)
            project.identityKey = name == "keyless" ? nil : "github.com/owner/" + name
            project.identityKind = project.identityKey == nil ? nil : "git"
            try files.createDirectory(at: project.path); context.insert(project); return project
        }
        let category = try seedRows(context: context, skill: skill, projects: projects, files: files)
        let watcher = RecordingWatcher()
        let manifest = RecordingDeletionManifest(files: files)
        let saves = ManifestSaveModel(manifest: manifest, root: root, lockPath: TestPaths.syncLockPath, files: files)
        let library = SkillLibraryViewModel(skillStore: store, fileService: files, fileWatchService: watcher,
            manifestRoot: root, manifestSaves: saves)
        library.startWatching(); _ = library.editorBody(for: skill)
        let state = DeployStateStore(fileService: files, appSupportDir: TestPaths.appSupportDir)
        let platform = PlatformViewModel(fileService: files, linkService: TestPaths.linkService(fileService: files),
            cursorCompiler: TestPaths.cursorCompiler(fileService: files),
            agentDetection: DeletionTestDetection(installed: [.claudeCode, .cursor]),
            deployStateStore: state, skillsDirectory: store.baseDir)
        let pairs: [(PlatformTarget, Project?)] = [(.claudeCode, nil), (.claudeCode, projects[0]),
            (.cursor, projects[1]), (.claudeCode, projects[2])]
        for (agent, project) in pairs {
            let batch = platform.deployBatch(skills: [skill], platforms: [agent],
                target: project.map { .project($0) } ?? .userWide, context: context)
            XCTAssertFalse(batch.hasFailures)
        }
        return Fixture(context: context, skill: skill, store: store, files: files, library: library,
            platform: platform, state: state, watcher: watcher, projects: projects, category: category, pairs: pairs, root: root)
    }

    private func seedRows(context: ModelContext, skill: Skill, projects: [Project],
                          files: FileService) throws -> Pensieve.Category {
        let category = Pensieve.Category(name: "Tools")
        category.skillSlugs = ["alpha"]; category.projectKeys = [projects[1].identityKey!]
        context.insert(category)
        let identity = MachineIdentity(fileService: files, appSupportDir: TestPaths.appSupportDir)
        let machine = try identity.identifier()
        context.insert(MachineDeployIntent(machineID: machine, skillSlug: "alpha",
            platformRaw: PlatformTarget.claudeCode.rawValue))
        context.insert(MachineDeployIntent(machineID: machine, skillSlug: "alpha",
            platformRaw: PlatformTarget.claudeCode.rawValue,
            projectKey: projects[0].identityKey))
        context.insert(MachineDeployIntent(machineID: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", skillSlug: "alpha",
            platformRaw: "codex"))
        context.insert(IntentAssignment(skillID: skill.id, platformRaw: PlatformTarget.claudeCode.rawValue))
        context.insert(IntentAssignment(skillID: skill.id, platformRaw: PlatformTarget.claudeCode.rawValue,
            projectID: projects[0].id))
        context.insert(SkillProjectAssignment(skillID: skill.id, projectID: projects[1].id, platform: .cursor))
        try context.save()
        return category
    }

    private func rename(_ f: Fixture, to name: String = "Beta Two",
                        persist: (ModelContext) throws -> Void = { try $0.save() }) -> Bool {
        SkillRenameFlow.rename(skill: f.skill, to: name, library: f.library, platformVM: f.platform,
            projects: f.projects, context: f.context, persist: persist)
    }

    private func path(_ f: Fixture, slug: String, pair: (PlatformTarget, Project?)) -> String {
        if let project = pair.1 {
            return DeployPaths.projectArtifactPath(directoryName: slug, platform: pair.0, projectPath: project.path)!
        }
        return TestPaths.deployPaths.linkPath(directoryName: slug, platform: pair.0, projectPath: nil)
    }

    private func assertArtifacts(_ f: Fixture, slug: String, unavailable: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let state = try f.state.read().records
        for pair in f.pairs where pair.1?.path != unavailable || unavailable == nil {
            let artifact = path(f, slug: slug, pair: pair)
            XCTAssertTrue(try f.files.entryExistsWithoutFollowingLinks(at: artifact), artifact, file: file, line: line)
            if pair.0.usesSymlinks {
                XCTAssertEqual(try f.files.symlinkTarget(at: artifact), f.store.baseDir + "/" + slug, file: file, line: line)
            } else {
                XCTAssertTrue(try f.files.readFile(at: artifact).contains("The body."), file: file, line: line)
            }
            XCTAssertTrue(state.contains { $0.slug == slug && $0.artifactPath == artifact }, file: file, line: line)
        }
    }

    func testRenameMovesFolderRewritesNameAndRekeysRecords() async throws {
        let f = try fixture(), id = f.skill.id
        let intents = try f.context.fetch(FetchDescriptor<MachineDeployIntent>()).map {
            $0.machineID + "|" + $0.platformRaw + "|" + ($0.projectKey ?? "")
        }.sorted()
        let revision = f.library.appWriteRevision
        XCTAssertTrue(rename(f), f.library.error ?? "")
        XCTAssertFalse(f.files.directoryExists(at: f.store.baseDir + "/alpha"))
        XCTAssertEqual(try f.files.readData(at: f.store.baseDir + "/beta-two/scripts/run.sh"), script)
        let written = try XCTUnwrap(String(validating: f.store.readData(directoryName: "beta-two"), as: UTF8.self))
        let parsed = SkillParser.parse(written, retainingBOM: true)
        XCTAssertEqual(parsed.name, "Beta Two"); XCTAssertEqual(parsed.description, "Alpha's job")
        XCTAssertTrue(written.hasPrefix("\u{feff}---\r\n"))
        XCTAssertFalse(written.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertTrue(written.contains("metadata:\r\n  owner: me\r\n  flags: [one, two]\r\n"))
        XCTAssertEqual(parsed.preservedFile?.rawBody, SkillParser.parse(original, retainingBOM: true).preservedFile?.rawBody)
        XCTAssertEqual(f.skill.id, id)
        XCTAssertEqual(f.skill.directoryName, "beta-two")
        XCTAssertEqual(f.skill.name, "Beta Two")
        let after = try f.context.fetch(FetchDescriptor<MachineDeployIntent>())
        XCTAssertEqual(after.map(\.skillSlug), Array(repeating: "beta-two", count: 3))
        XCTAssertEqual(after.map { $0.machineID + "|" + $0.platformRaw + "|" + ($0.projectKey ?? "") }.sorted(), intents)
        XCTAssertEqual(f.category.skillSlugs, ["beta-two"])
        try assertArtifacts(f, slug: "beta-two")
        for pair in f.pairs {
            XCTAssertFalse(try f.files.entryExistsWithoutFollowingLinks(at: path(f, slug: "alpha", pair: pair)))
        }
        XCTAssertTrue(try f.state.read().records.allSatisfy { $0.slug == "beta-two" })
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<IntentAssignment>()).filter { $0.skillID == id }.count, 2)
        XCTAssertFalse(try f.context.fetch(FetchDescriptor<SkillProjectAssignment>()).filter { $0.skillID == id }.isEmpty)
        let items = try XCTUnwrap(f.library.manifestSaves).items
        XCTAssertEqual(items.count, 1)
        if case .renameSkill("alpha", "beta-two") = items.first?.change {} else { XCTFail("Expected one rename") }
        XCTAssertEqual(f.library.lastWrittenBody["beta-two"], written)
        let token = f.library.reloadToken
        f.watcher.emit("alpha"); f.watcher.emit("beta-two")
        XCTAssertTrue(f.library.externallyModified.isEmpty); XCTAssertEqual(f.library.reloadToken, token)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertGreaterThan(f.library.appWriteRevision, revision)
        XCTAssertEqual(f.library.editorBody(for: f.skill), written)
        f.library.noteEditorChanged(f.skill, body: written.replacingOccurrences(of: "The body.", with: "Edited body."))
        XCTAssertTrue(f.library.saveDraft(f.skill))
        let saved = try XCTUnwrap(String(validating: f.store.readData(directoryName: "beta-two"), as: UTF8.self))
        let afterSave = SkillParser.parse(saved, retainingBOM: true)
        XCTAssertEqual(afterSave.name, "Beta Two")
        XCTAssertEqual(afterSave.preservedFile?.header, parsed.preservedFile?.header)
        XCTAssertTrue(saved.contains("Edited body."))
        await f.library.manifestSaves?.waitUntilIdle()
    }

    func testRenameRefusesTakenNamesAndKeepsTheSkillWhenTheMoveIsRefused() async throws {
        let f = try fixture()
        f.context.insert(Skill(name: "gamma", directoryName: "gamma")); try f.context.save()
        try f.files.writeFile(at: f.store.baseDir + "/delta", content: "occupant")
        try f.files.createSymlink(at: f.store.baseDir + "/epsilon", pointingTo: f.root + "/absent")
        try f.files.createDirectory(at: f.store.baseDir + "/Zeta")
        for name in ["", "   ", "Gamma", "delta", "epsilon", "zeta", "ZETA", "日本語", "!!!", String(repeating: "a", count: 65)] {
            let message = try XCTUnwrap(f.library.renameValidationMessage(name, skill: f.skill, context: f.context), name)
            if ["Gamma", "delta", "epsilon", "zeta", "ZETA"].contains(name) {
                XCTAssertTrue(message.lowercased().contains(SkillStore.slugify(name)), message)
            }
            if name == "日本語" || name == "!!!" { XCTAssertTrue(message.contains("letter or digit"), message) }
            if name.utf8.count == 65 { XCTAssertTrue(message.contains("64 bytes"), message) }
        }
        for name in ["Alpha!", "Alpha"] { XCTAssertNil(f.library.renameValidationMessage(name, skill: f.skill,
            context: f.context)) }
        let before = try f.state.read()
        let intentKeys = try f.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key).sorted()
        XCTAssertTrue(rename(f, to: "Alpha!"), f.library.error ?? "")
        XCTAssertEqual(f.skill.directoryName, "alpha")
        XCTAssertEqual(f.skill.name, "Alpha!")
        XCTAssertEqual(try f.state.read(), before); XCTAssertEqual(f.category.skillSlugs, ["alpha"])
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key).sorted(), intentKeys)
        XCTAssertEqual(f.library.manifestSaves?.items.count, 0)
        try assertArtifacts(f, slug: "alpha")
        let bytes = try f.store.readData(directoryName: "alpha")
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: TestPaths.syncLockPath))
        XCTAssertFalse(rename(f)); XCTAssertTrue(f.library.error?.contains("busy syncing") == true)
        XCTAssertEqual(try f.store.readData(directoryName: "alpha"), bytes); XCTAssertEqual(f.skill.name, "Alpha!")
        lock.release()
        XCTAssertNil(f.library.renameValidationMessage("Beta Two", skill: f.skill, context: f.context))
        try f.files.writeFile(at: f.store.baseDir + "/beta-two", content: "racing occupant")
        XCTAssertFalse(rename(f))
        XCTAssertTrue(f.library.error?.contains("beta-two") == true)
        XCTAssertEqual(try f.store.readData(directoryName: "alpha"), bytes)
        XCTAssertEqual(try f.files.readFile(at: f.store.baseDir + "/beta-two"), "racing occupant")
        XCTAssertEqual(f.skill.directoryName, "alpha"); XCTAssertEqual(f.category.skillSlugs, ["alpha"])
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key).sorted(), intentKeys)
        try assertArtifacts(f, slug: "alpha")
        XCTAssertTrue(try f.platform.waitingRemovalStore.read().isEmpty)
        await f.library.manifestSaves?.waitUntilIdle()
    }

    func testRenameRestoresTheSkillWhenAStepAfterTheMoveFails() async throws {
        let f = try fixture(), id = f.skill.id
        let keys = try f.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key).sorted()
        let unavailable = f.projects[0].path
        try f.files.deleteDirectory(at: unavailable)
        XCTAssertFalse(rename(f, persist: { _ in throw DeletionTestError() }))
        XCTAssertNotNil(f.library.error)
        XCTAssertFalse(f.files.directoryExists(at: f.store.baseDir + "/beta-two"))
        XCTAssertEqual(try f.store.readData(directoryName: "alpha"), Data(original.utf8))
        XCTAssertEqual(try f.files.readData(at: f.store.baseDir + "/alpha/scripts/run.sh"), script)
        XCTAssertEqual(f.skill.directoryName, "alpha"); XCTAssertEqual(f.skill.name, "alpha")
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key).sorted(), keys)
        XCTAssertEqual(f.category.skillSlugs, ["alpha"])
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<IntentAssignment>()).filter { $0.skillID == id }.count, 2)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<SkillProjectAssignment>()).filter { $0.skillID == id }.count, 1)
        XCTAssertFalse(f.context.hasChanges)
        try assertArtifacts(f, slug: "alpha", unavailable: unavailable)
        XCTAssertTrue(try f.platform.waitingRemovalStore.read().isEmpty)
        XCTAssertTrue(rename(f), f.library.error ?? "")
        XCTAssertTrue(f.library.error?.contains("will be removed when the folder is back") == true)
        let waiting = try f.platform.waitingRemovalStore.read()
        XCTAssertEqual(waiting.count, 1); XCTAssertEqual(waiting.first?.slug, "alpha")
        XCTAssertEqual(waiting.first?.artifactPath, path(f, slug: "alpha", pair: f.pairs[1]))
        XCTAssertTrue(try f.state.read().records.allSatisfy { $0.slug != "alpha" })
        await f.library.manifestSaves?.waitUntilIdle()
        let unsafe = "---\nname: X\ndescription: |\n  a\u{2028}  ---\u{2028}  name: hidden\u{2028}  ---\u{2028}  end\n"
            + "license: MIT\n---\n\nBody\n"
        try f.store.writeBody(directoryName: "beta-two", body: unsafe)
        let state = try f.state.read()
        XCTAssertFalse(rename(f, to: "Next"))
        XCTAssertTrue(f.library.error?.contains("frontmatter can't be rewritten safely") == true)
        XCTAssertEqual(try f.state.read(), state)
        XCTAssertEqual(try f.store.readBody(directoryName: "beta-two"), unsafe)
        XCTAssertFalse(f.files.directoryExists(at: f.store.baseDir + "/next"))
    }
}
