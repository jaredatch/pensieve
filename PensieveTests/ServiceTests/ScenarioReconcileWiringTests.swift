import SwiftData
import XCTest
@testable import Pensieve

private struct RecordedLink: Hashable {
    let directoryName: String
    let platform: PlatformTarget
    let projectPath: String?
}

private struct StubFailure: LocalizedError {
    let errorDescription: String? = "stub failure"
}

private struct StubDetection: AgentDetectionServiceProtocol {
    let installed: [PlatformTarget]

    func isInstalled(_ platform: PlatformTarget) -> Bool { installed.contains(platform) }
    func installedPlatforms() -> [PlatformTarget] { installed }
}

private struct NoopCategoryReconciler: CategoryReconcilerProtocol {
    func reconcile(context: ModelContext) -> BatchResult { BatchResult() }
}

private final class RecordingFileService: FileServiceProtocol {
    var files: Set<String> = []
    var symlinks: Set<String> = []
    var contents: [String: String] = [:]

    func readFile(at path: String) throws -> String { contents[path] ?? "" }
    func writeFile(at path: String, content: String) throws {
        files.insert(path)
        contents[path] = content
    }
    func deleteFile(at path: String) throws {
        files.remove(path)
        symlinks.remove(path)
        contents.removeValue(forKey: path)
    }
    func fileExists(at path: String) -> Bool { files.contains(path) || contents[path] != nil }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { false }
    func createDirectory(at path: String) throws {}
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws { symlinks.insert(linkPath) }
    func symlinkTarget(at path: String) throws -> String { "" }
    func isSymlink(at path: String) -> Bool { symlinks.contains(path) }
    func isRegularFile(at path: String) -> Bool { true }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String { "hash" }
}

private final class RecordingLinkService: LinkServiceProtocol {
    let fileService: RecordingFileService
    var linkCalls: [RecordedLink] = []
    var unlinkCalls: [RecordedLink] = []
    var throwOnUnlink: Set<PlatformTarget> = []

    init(fileService: RecordingFileService) {
        self.fileService = fileService
    }

    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        linkCalls.append(RecordedLink(directoryName: skill.directoryName, platform: platform, projectPath: projectPath))
        fileService.symlinks.insert(linkPath(skill: skill, platform: platform, projectPath: projectPath))
    }

    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        unlinkCalls.append(RecordedLink(directoryName: skill.directoryName, platform: platform, projectPath: projectPath))
        if throwOnUnlink.contains(platform) { throw StubFailure() }
        try fileService.deleteFile(at: linkPath(skill: skill, platform: platform, projectPath: projectPath))
    }

    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool { false }

    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/links/" + platform.rawValue + "/" + skill.directoryName
    }

    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/targets/" + platform.rawValue + "/" + skill.directoryName
    }

    func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
}

private struct NoopCursorCompiler: CursorCompilerProtocol {
    func compile(skill: Skill, projectPath: String?) throws {}
    func remove(skill: Skill, projectPath: String?) throws {}
    func isUpToDate(skill: Skill, projectPath: String?) -> Bool { false }
    func outputPath(skill: Skill, projectPath: String?) -> String { "/tmp/cursor/" + skill.directoryName + ".mdc" }
}

private final class RecordingSkillStore: SkillStoreProtocol {
    private(set) var deletedDirectoryNames: [String] = []
    private(set) var writeCount = 0

    func createSkill(name: String, description: String, body: String) throws -> String { "created" }
    func readBody(directoryName: String) throws -> String { "" }
    func rewriteSkill(directoryName: String, body: String, preserving parsed: ParsedSkill,
                      fallbackName: String, fallbackDescription: String) throws -> SkillRewriteResult {
        writeCount += 1
        return SkillRewriteResult(content: body, didChange: true)
    }
    func writeBody(directoryName: String, body: String) throws { writeCount += 1 }
    func deleteSkill(directoryName: String) throws { deletedDirectoryNames.append(directoryName) }
    func listSkills() throws -> [String] { [] }
}

private struct WiringHarness {
    let store: ScenarioStore
    let reconciler: ScenarioReconciler
    let linkService: RecordingLinkService
}

final class ScenarioReconcileWiringTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = isolatedDefaultsSuite()
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, ScenarioAssignment.self,
            IntentAssignment.self, DeployRecord.self, Category.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeHarness() -> WiringHarness {
        let fileService = RecordingFileService()
        let linkService = RecordingLinkService(fileService: fileService)
        let store = ScenarioStore(defaults: defaults)
        let deployStateStore = DeployStateStore(
            fileService: fileService,
            appSupportDir: "/tmp/ScenarioReconcileWiringTests-\(UUID().uuidString)"
        )
        let vm = PlatformViewModel(
            fileService: fileService,
            linkService: linkService,
            cursorCompiler: NoopCursorCompiler(),
            agentDetection: StubDetection(installed: [.claudeCode]),
            deployStateStore: deployStateStore
        )
        return WiringHarness(
            store: store,
            reconciler: ScenarioReconciler(platformVM: vm, scenarioStore: store),
            linkService: linkService
        )
    }

    @MainActor
    private func makeSkill(context: ModelContext) -> Skill {
        let skill = Skill(name: "Skill S", directoryName: "skill-s")
        context.insert(skill)
        return skill
    }

    @MainActor
    private func makeScenario(name: String, skill: Skill, context: ModelContext) -> Scenario {
        let scenario = Scenario(name: name)
        scenario.skillSlugs = [skill.directoryName]
        scenario.agentRawValues = [PlatformTarget.claudeCode.rawValue]
        context.insert(scenario)
        return scenario
    }

    @MainActor
    private func skillCount(context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<Skill>()).count
    }

    @MainActor
    private func ledgerRows(context: ModelContext) throws -> [ScenarioAssignment] {
        try context.fetch(FetchDescriptor<ScenarioAssignment>())
    }

    @MainActor
    func testDeleteSkillPrunesEveryScenarioAndRemovesActiveDeploysWhileSkillIsLive() throws {
        let context = try makeContext()
        let skill = makeSkill(context: context)
        let active = makeScenario(name: "Active", skill: skill, context: context)
        _ = makeScenario(name: "Inactive", skill: skill, context: context)
        try context.save()
        let harness = makeHarness()
        _ = harness.store.activate(active, reconciler: harness.reconciler, context: context)
        harness.linkService.unlinkCalls.removeAll()
        let skillStore = RecordingSkillStore()
        let library = SkillLibraryViewModel(skillStore: skillStore, scenarioStore: harness.store)

        library.deleteSkill(
            skill,
            context: context,
            categoryReconciler: NoopCategoryReconciler(),
            scenarioReconciler: harness.reconciler
        )

        XCTAssertNil(library.error)
        let scenarios = try context.fetch(FetchDescriptor<Scenario>())
        XCTAssertTrue(scenarios.allSatisfy { !$0.skillSlugs.contains(skill.directoryName) })
        XCTAssertEqual(harness.linkService.unlinkCalls, [
            RecordedLink(directoryName: skill.directoryName, platform: .claudeCode, projectPath: nil)
        ])
        XCTAssertEqual(skillStore.deletedDirectoryNames, [skill.directoryName])
        XCTAssertEqual(try skillCount(context: context), 0)
        XCTAssertTrue(try ledgerRows(context: context).isEmpty)
    }

    @MainActor
    func testDeleteSkillScenarioUnlinkFailureRetainsSkill() throws {
        let context = try makeContext()
        let skill = makeSkill(context: context)
        let active = makeScenario(name: "Active", skill: skill, context: context)
        try context.save()
        let harness = makeHarness()
        _ = harness.store.activate(active, reconciler: harness.reconciler, context: context)
        harness.linkService.throwOnUnlink = [.claudeCode]
        let skillStore = RecordingSkillStore()
        let library = SkillLibraryViewModel(
            skillStore: skillStore,
            scenarioStore: harness.store
        )
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "edited")

        library.deleteSkill(
            skill,
            context: context,
            categoryReconciler: NoopCategoryReconciler(),
            scenarioReconciler: harness.reconciler
        )

        XCTAssertNotNil(library.error)
        XCTAssertEqual(try skillCount(context: context), 1)
        XCTAssertTrue(skillStore.deletedDirectoryNames.isEmpty)
        XCTAssertEqual(try ledgerRows(context: context).count, 1)
        XCTAssertTrue(library.hasUnsavedChanges(for: skill))
        XCTAssertTrue(library.saveDraft(skill))
        XCTAssertEqual(skillStore.writeCount, 1)
    }
}
