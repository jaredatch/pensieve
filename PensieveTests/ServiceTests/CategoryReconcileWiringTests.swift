import SwiftData
import XCTest
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

private struct RecordedLink: Hashable {
    let directoryName: String
    let platform: PlatformTarget
    let projectPath: String?
}

private struct StubFailure: LocalizedError {
    let errorDescription: String? = "stub failure"
}

private struct SeededRule {
    let skill: Skill
    let project: Project
    let category: PensieveCategory
}

private final class RecordingLinkService: LinkServiceProtocol {
    var linked: Set<RecordedLink> = []
    var linkCalls: [RecordedLink] = []
    var unlinkCalls: [RecordedLink] = []
    var throwOnLink: Set<PlatformTarget> = []
    var throwOnUnlink: Set<PlatformTarget> = []

    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        linkCalls.append(RecordedLink(directoryName: skill.directoryName, platform: platform, projectPath: projectPath))
        if throwOnLink.contains(platform) { throw StubFailure() }
        linked.insert(RecordedLink(directoryName: skill.directoryName, platform: platform, projectPath: projectPath))
    }

    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        unlinkCalls.append(RecordedLink(directoryName: skill.directoryName, platform: platform, projectPath: projectPath))
        if throwOnUnlink.contains(platform) { throw StubFailure() }
        linked.remove(RecordedLink(directoryName: skill.directoryName, platform: platform, projectPath: projectPath))
    }

    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        linked.contains(RecordedLink(directoryName: skill.directoryName, platform: platform, projectPath: projectPath))
    }

    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/links/" + platform.rawValue + "/" + skill.directoryName
    }

    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/targets/" + platform.rawValue + "/" + skill.directoryName
    }

    func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
}

private final class StubDetection: AgentDetectionServiceProtocol {
    var installed: [PlatformTarget]

    init(installed: [PlatformTarget]) {
        self.installed = installed
    }

    func isInstalled(_ platform: PlatformTarget) -> Bool { installed.contains(platform) }
    func installedPlatforms() -> [PlatformTarget] { installed }
}

private struct StubFileService: FileServiceProtocol {
    let linkService: RecordingLinkService
    func readFile(at path: String) throws -> String { "" }
    func writeFile(at path: String, content: String) throws {}
    func deleteFile(at path: String) throws {}
    func fileExists(at path: String) -> Bool { isSymlink(at: path) }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { false }
    func directoryExistsFollowingLinks(at path: String) throws -> Bool { path.hasPrefix("/tmp/") }
    func createDirectory(at path: String) throws {}
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
    func symlinkTarget(at path: String) throws -> String { "" }
    func isSymlink(at path: String) -> Bool {
        linkService.linked.contains { recorded in
            (recorded.projectPath ?? "/tmp/user-wide") + "/links/" + recorded.platform.rawValue
                + "/" + recorded.directoryName == path
        }
    }
    func isRegularFile(at path: String) -> Bool { true }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String { "hash" }
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

    func deleteSkill(directoryName: String) throws {
        deletedDirectoryNames.append(directoryName)
    }

    func listSkills() throws -> [String] { [] }
}

final class CategoryReconcileWiringTests: XCTestCase {

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeReconciler(
        installed: [PlatformTarget] = [.claudeCode, .codex],
        linkService: RecordingLinkService
    ) -> CategoryReconciler {
        CategoryReconciler(platformVM: PlatformViewModel(
            fileService: StubFileService(linkService: linkService),
            linkService: linkService,
            agentDetection: StubDetection(installed: installed),
            deployStateStore: .memoryBacked
        ))
    }

    @MainActor
    private func makeSkill(directoryName: String = "skill-s", context: ModelContext) -> Skill {
        let skill = Skill(name: "Skill S", directoryName: directoryName)
        context.insert(skill)
        return skill
    }

    @MainActor
    private func makeProject(path: String = "/tmp/project-p", key: String = "project-key", context: ModelContext) -> Project {
        let project = Project(name: "Project P", path: path)
        project.identityKey = key
        context.insert(project)
        return project
    }

    @MainActor
    private func makeCategory(
        name: String = "Category C",
        skills: [Skill],
        projects: [Project],
        context: ModelContext
    ) -> PensieveCategory {
        let category = PensieveCategory(name: name)
        category.skillSlugs = skills.map(\.directoryName)
        category.projectKeys = projects.compactMap(\.identityKey)
        context.insert(category)
        return category
    }

    @MainActor
    private func makeSeededRule(context: ModelContext) throws -> SeededRule {
        let skill = makeSkill(context: context)
        let project = makeProject(context: context)
        let category = makeCategory(skills: [skill], projects: [project], context: context)
        try context.save()
        return SeededRule(skill: skill, project: project, category: category)
    }

    @MainActor
    private func ledgerRows(context: ModelContext) throws -> [SkillProjectAssignment] {
        try context.fetch(FetchDescriptor<SkillProjectAssignment>())
    }

    @MainActor
    private func skillCount(context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<Skill>()).count
    }

    @MainActor
    private func projectCount(context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<Project>()).count
    }

    @MainActor
    func testSetSkillReconcilesAssignAndUnassign() throws {
        let context = try makeContext()
        let skill = makeSkill(context: context)
        let project = makeProject(context: context)
        let category = makeCategory(skills: [], projects: [project], context: context)
        try context.save()
        let linkService = RecordingLinkService()
        let reconciler = makeReconciler(linkService: linkService)

        let assignResult = CategoryStore().setSkill(
            skill,
            inCategory: category,
            assigned: true,
            reconciler: reconciler,
            context: context
        )

        XCTAssertFalse(assignResult.hasFailures)
        XCTAssertEqual(assignResult.successes.count, 2)
        XCTAssertEqual(Set(linkService.linkCalls), Set([
            RecordedLink(directoryName: skill.directoryName, platform: .claudeCode, projectPath: project.path),
            RecordedLink(directoryName: skill.directoryName, platform: .codex, projectPath: project.path)
        ]))

        linkService.unlinkCalls.removeAll()
        let unassignResult = CategoryStore().setSkill(
            skill,
            inCategory: category,
            assigned: false,
            reconciler: reconciler,
            context: context
        )

        XCTAssertFalse(unassignResult.hasFailures)
        XCTAssertEqual(unassignResult.successes.count, 2)
        XCTAssertEqual(Set(linkService.unlinkCalls), Set([
            RecordedLink(directoryName: skill.directoryName, platform: .claudeCode, projectPath: project.path),
            RecordedLink(directoryName: skill.directoryName, platform: .codex, projectPath: project.path)
        ]))
    }

    @MainActor
    func testRemoveRegisteredProjectUnlinksWhileLiveThenDeletesRecord() throws {
        let context = try makeContext()
        let seed = try makeSeededRule(context: context)
        let linkService = RecordingLinkService()
        let reconciler = makeReconciler(linkService: linkService)
        _ = reconciler.reconcile(context: context)
        linkService.unlinkCalls.removeAll()

        let result = removeRegisteredProject(
            seed.project,
            categoryStore: CategoryStore(),
            reconciler: reconciler,
            context: context
        )

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(Set(linkService.unlinkCalls), Set([
            RecordedLink(directoryName: seed.skill.directoryName, platform: .claudeCode, projectPath: seed.project.path),
            RecordedLink(directoryName: seed.skill.directoryName, platform: .codex, projectPath: seed.project.path)
        ]))
        XCTAssertTrue(try ledgerRows(context: context).filter { $0.projectID == seed.project.id }.isEmpty)
        XCTAssertEqual(try projectCount(context: context), 0)
    }

    @MainActor
    func testRemoveRegisteredProjectRetainsRecordAndFailedLedgerOnFailedUnlink() throws {
        let context = try makeContext()
        let seed = try makeSeededRule(context: context)
        let linkService = RecordingLinkService()
        let reconciler = makeReconciler(linkService: linkService)
        _ = reconciler.reconcile(context: context)
        linkService.throwOnUnlink = [.codex]

        let result = removeRegisteredProject(
            seed.project,
            categoryStore: CategoryStore(),
            reconciler: reconciler,
            context: context
        )

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try projectCount(context: context), 1)
        let retainedRows = try ledgerRows(context: context)
        XCTAssertEqual(retainedRows.count, 1)
        XCTAssertEqual(retainedRows.first?.platform, .codex)
    }

    @MainActor
    func testDeleteSkillUnlinksWhileLiveThenDeletesFilesAndRecord() throws {
        // Category reconciliation seeds the deploys; SkillDeletionFlow unlinks and retires them.
        let context = try makeContext()
        let seed = try makeSeededRule(context: context)
        let linkService = RecordingLinkService()
        let reconciler = makeReconciler(linkService: linkService)
        _ = reconciler.reconcile(context: context)
        linkService.unlinkCalls.removeAll()
        let skillStore = RecordingSkillStore()
        let library = SkillLibraryViewModel(skillStore: skillStore)

        SkillDeletionFlow.delete(
            skill: seed.skill, library: library, platformVM: reconciler.platformVM,
            projects: try context.fetch(FetchDescriptor<Project>()), context: context
        )

        XCTAssertNil(library.error)
        XCTAssertEqual(Set(linkService.unlinkCalls), Set([
            RecordedLink(directoryName: seed.skill.directoryName, platform: .claudeCode, projectPath: seed.project.path),
            RecordedLink(directoryName: seed.skill.directoryName, platform: .codex, projectPath: seed.project.path)
        ]))
        XCTAssertEqual(skillStore.deletedDirectoryNames, [seed.skill.directoryName])
        XCTAssertEqual(try skillCount(context: context), 0)
        XCTAssertTrue(try ledgerRows(context: context).isEmpty)
    }

    @MainActor
    func testDeleteSkillRetainsRecordAndDoesNotDeleteFilesOnFailedUnlink() throws {
        // Live deletion keeps both ledger rows and the skill when any owned unlink fails.
        let context = try makeContext()
        _ = try makeSeededRule(context: context)
        let linkService = RecordingLinkService()
        let reconciler = makeReconciler(linkService: linkService)
        _ = reconciler.reconcile(context: context)
        linkService.throwOnUnlink = [.codex]
        let skill = try context.fetch(FetchDescriptor<Skill>()).first!
        let skillStore = RecordingSkillStore()
        let library = SkillLibraryViewModel(skillStore: skillStore)

        SkillDeletionFlow.delete(
            skill: skill, library: library, platformVM: reconciler.platformVM,
            projects: try context.fetch(FetchDescriptor<Project>()), context: context
        )

        XCTAssertNotNil(library.deletionNotice)
        XCTAssertEqual(try skillCount(context: context), 1)
        XCTAssertTrue(skillStore.deletedDirectoryNames.isEmpty)
        let retainedRows = try ledgerRows(context: context)
        XCTAssertEqual(retainedRows.count, 2)
        XCTAssertEqual(Set(retainedRows.map(\.platform)), [.claudeCode, .codex])
    }

    @MainActor
    func testDeleteSkillWithFailedReconcileKeepsPendingEditSoItIsNotLost() throws {
        // SkillDeletionFlow retains the skill and its draft when an owned unlink fails.
        // The retained draft must still save; clean deletion cancellation is covered by SkillLibrarySaveTests.
        let context = try makeContext()
        _ = try makeSeededRule(context: context)
        let linkService = RecordingLinkService()
        let reconciler = makeReconciler(linkService: linkService)
        _ = reconciler.reconcile(context: context)
        linkService.throwOnUnlink = [.codex]                       // force a failed unlink; retain the skill
        let skill = try context.fetch(FetchDescriptor<Skill>()).first!

        let skillStore = RecordingSkillStore()
        let library = SkillLibraryViewModel(skillStore: skillStore)
        _ = library.editorBody(for: skill)
        library.noteEditorChanged(skill, body: "edited")           // an unsaved draft for this skill

        SkillDeletionFlow.delete(
            skill: skill, library: library, platformVM: reconciler.platformVM,
            projects: try context.fetch(FetchDescriptor<Project>()), context: context
        )
        XCTAssertNotNil(library.deletionNotice)                             // failure surfaced by SkillDeletionFlow
        XCTAssertEqual(try skillCount(context: context), 1)        // skill retained for retry

        XCTAssertTrue(library.hasUnsavedChanges(for: skill))       // the draft must still be live
        XCTAssertTrue(library.saveDraft(skill))
        XCTAssertEqual(skillStore.writeCount, 1)                   // the draft WAS saved, not silently dropped
    }

    @MainActor
    func testOverlapHoldsThroughSetSkillWiring() throws {
        let context = try makeContext()
        let skill = makeSkill(context: context)
        let project = makeProject(context: context)
        let firstCategory = makeCategory(name: "C1", skills: [skill], projects: [project], context: context)
        _ = makeCategory(name: "C2", skills: [skill], projects: [project], context: context)
        try context.save()
        let linkService = RecordingLinkService()
        let reconciler = makeReconciler(linkService: linkService)
        _ = reconciler.reconcile(context: context)
        linkService.unlinkCalls.removeAll()

        let result = CategoryStore().setSkill(
            skill,
            inCategory: firstCategory,
            assigned: false,
            reconciler: reconciler,
            context: context
        )

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(linkService.unlinkCalls.isEmpty)
        XCTAssertEqual(try ledgerRows(context: context).count, 2)
    }
}
