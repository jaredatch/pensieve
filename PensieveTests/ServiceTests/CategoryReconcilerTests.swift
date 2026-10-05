import XCTest
import SwiftData
@testable import Pensieve

private typealias PensieveCategory = CategoryFixturePensieveCategory
private typealias RecordedLink = CategoryFixtureRecordedLink
private typealias RecordedCursorCall = CategoryFixtureRecordedCursorCall
private typealias SeededCategory = CategoryFixtureSeededCategory
private typealias StubFailure = CategoryFixtureStubFailure
private typealias StubDetection = CategoryFixtureStubDetection
private typealias RecordingLinkService = CategoryFixtureRecordingLinkService
private typealias RecordingCursorCompiler = CategoryFixtureRecordingCursorCompiler
private typealias StubFileService = CategoryFixtureStubFileService

final class CategoryReconcilerTests: XCTestCase {
    private let files = StubFileService()

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self,
            IntentAssignment.self, DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    private func makeSkill(
        name: String = "Skill S",
        directoryName: String = "skill-s",
        context: ModelContext
    ) -> Skill {
        let skill = Skill(name: name, directoryName: directoryName)
        context.insert(skill)
        return skill
    }

    @MainActor
    private func makeProject(name: String, path: String, key: String, context: ModelContext) -> Project {
        let project = Project(name: name, path: path)
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
    private func seedTwoProjectCategory(
        context: ModelContext
    ) throws -> SeededCategory {
        let skill = makeSkill(context: context)
        let firstProject = makeProject(name: "P1", path: "/tmp/p1", key: "key-p1", context: context)
        let secondProject = makeProject(name: "P2", path: "/tmp/p2", key: "key-p2", context: context)
        let category = makeCategory(skills: [skill], projects: [firstProject, secondProject], context: context)
        try context.save()
        return SeededCategory(skill: skill, firstProject: firstProject, secondProject: secondProject, category: category)
    }

    @MainActor
    private func ledgerRows(context: ModelContext) throws -> [SkillProjectAssignment] {
        try context.fetch(FetchDescriptor<SkillProjectAssignment>())
    }

    @MainActor
    func testAssignFansOutToMembersAndInstalledAgents() throws {
        let context = try makeContext()
        let seed = try seedTwoProjectCategory(context: context)
        let linkService = RecordingLinkService()
        let reconciler = makeReconciler(installed: [.claudeCode, .codex], linkService: linkService)

        let result = reconciler.reconcile(context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(Set(linkService.linkCalls), Set([
            RecordedLink(directoryName: seed.skill.directoryName, platform: .claudeCode, projectPath: seed.firstProject.path),
            RecordedLink(directoryName: seed.skill.directoryName, platform: .codex, projectPath: seed.firstProject.path),
            RecordedLink(directoryName: seed.skill.directoryName, platform: .claudeCode, projectPath: seed.secondProject.path),
            RecordedLink(directoryName: seed.skill.directoryName, platform: .codex, projectPath: seed.secondProject.path)
        ]))
        XCTAssertEqual(try ledgerRows(context: context).count, 4)
    }

    @MainActor
    func testReconcileIsIdempotentAndNewlyInstalledAgentFansOutOnlyToMissingPlatform() throws {
        let context = try makeContext()
        let seed = try seedTwoProjectCategory(context: context)
        let initialLinkService = RecordingLinkService()
        let initialReconciler = makeReconciler(
            installed: [.claudeCode, .codex],
            linkService: initialLinkService
        )

        _ = initialReconciler.reconcile(context: context)
        initialLinkService.linkCalls.removeAll()
        _ = initialReconciler.reconcile(context: context)

        XCTAssertTrue(initialLinkService.linkCalls.isEmpty)
        XCTAssertEqual(try ledgerRows(context: context).count, 4)

        let cursorCompiler = RecordingCursorCompiler()
        let newLinkService = RecordingLinkService()
        let newReconciler = makeReconciler(
            installed: [.claudeCode, .codex, .cursor],
            linkService: newLinkService,
            cursorCompiler: cursorCompiler
        )
        _ = newReconciler.reconcile(context: context)

        XCTAssertTrue(newLinkService.linkCalls.isEmpty)
        XCTAssertEqual(Set(cursorCompiler.compileCalls), Set([
            RecordedCursorCall(directoryName: seed.skill.directoryName, projectPath: seed.firstProject.path),
            RecordedCursorCall(directoryName: seed.skill.directoryName, projectPath: seed.secondProject.path)
        ]))
        let ledger = try ledgerRows(context: context)
        XCTAssertEqual(ledger.count, 6)
        XCTAssertEqual(ledger.filter { $0.platform == .cursor }.count, 2)
    }

    @MainActor
    func testUnassignRemovesEveryTupleAndDropsLedgerRows() throws {
        let context = try makeContext()
        let seed = try seedTwoProjectCategory(context: context)
        let linkService = RecordingLinkService()
        let reconciler = makeReconciler(installed: [.claudeCode, .codex], linkService: linkService)
        _ = reconciler.reconcile(context: context)
        linkService.unlinkCalls.removeAll()

        seed.category.skillSlugs = []
        let result = reconciler.reconcile(context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(linkService.unlinkCalls.count, 4)
        XCTAssertEqual(try ledgerRows(context: context).count, 0)
    }

    @MainActor
    func testMembershipAddDeploysOnlyNewProject() throws {
        let context = try makeContext()
        let seed = try seedTwoProjectCategory(context: context)
        let linkService = RecordingLinkService()
        let reconciler = makeReconciler(installed: [.claudeCode, .codex], linkService: linkService)
        _ = reconciler.reconcile(context: context)
        linkService.linkCalls.removeAll()

        let thirdProject = makeProject(name: "P3", path: "/tmp/p3", key: "key-p3", context: context)
        seed.category.projectKeys.append("key-p3")
        try context.save()
        _ = reconciler.reconcile(context: context)

        XCTAssertEqual(Set(linkService.linkCalls), Set([
            RecordedLink(directoryName: seed.skill.directoryName, platform: .claudeCode, projectPath: thirdProject.path),
            RecordedLink(directoryName: seed.skill.directoryName, platform: .codex, projectPath: thirdProject.path)
        ]))
        XCTAssertEqual(try ledgerRows(context: context).count, 6)
    }

    @MainActor
    func testOverlapAcrossCategoriesDoesNotDuplicateOrRemoveStillDesiredTuples() throws {
        let context = try makeContext()
        let skill = makeSkill(context: context)
        let project = makeProject(name: "P", path: "/tmp/p", key: "key-p", context: context)
        let firstCategory = makeCategory(name: "C1", skills: [skill], projects: [project], context: context)
        _ = makeCategory(name: "C2", skills: [skill], projects: [project], context: context)
        try context.save()
        let linkService = RecordingLinkService()
        let reconciler = makeReconciler(installed: [.claudeCode, .codex], linkService: linkService)

        _ = reconciler.reconcile(context: context)
        XCTAssertEqual(linkService.linkCalls.count, 2)
        XCTAssertEqual(try ledgerRows(context: context).count, 2)

        linkService.unlinkCalls.removeAll()
        firstCategory.skillSlugs = []
        try context.save()
        _ = reconciler.reconcile(context: context)

        XCTAssertTrue(linkService.unlinkCalls.isEmpty)
        XCTAssertEqual(try ledgerRows(context: context).count, 2)
    }

    @MainActor
    func testPartialDeployFailureIsNotLedgeredAndRetriesNextRun() throws {
        let context = try makeContext()
        _ = try seedTwoProjectCategory(context: context)
        let linkService = RecordingLinkService()
        linkService.throwOnLink = [.codex]
        let reconciler = makeReconciler(installed: [.claudeCode, .codex], linkService: linkService)

        let failedResult = reconciler.reconcile(context: context)

        XCTAssertEqual(failedResult.failures.count, 2)
        var ledger = try ledgerRows(context: context)
        XCTAssertEqual(ledger.count, 2)
        XCTAssertTrue(ledger.allSatisfy { $0.platform == .claudeCode })

        linkService.linkCalls.removeAll()
        linkService.throwOnLink = []
        let retryResult = reconciler.reconcile(context: context)

        XCTAssertFalse(retryResult.hasFailures)
        XCTAssertEqual(linkService.linkCalls.map(\.platform), [.codex, .codex])
        ledger = try ledgerRows(context: context)
        XCTAssertEqual(ledger.count, 4)
        XCTAssertEqual(ledger.filter { $0.platform == .codex }.count, 2)
    }

    @MainActor
    func testPartialUnlinkFailureKeepsLedgerRowAndRetriesNextRun() throws {
        let context = try makeContext()
        let seed = try seedTwoProjectCategory(context: context)
        let linkService = RecordingLinkService()
        let reconciler = makeReconciler(installed: [.claudeCode, .codex], linkService: linkService)
        _ = reconciler.reconcile(context: context)

        linkService.throwOnUnlink = [.codex]
        seed.category.skillSlugs = []
        let failedResult = reconciler.reconcile(context: context)

        XCTAssertEqual(failedResult.failures.count, 2)
        var ledger = try ledgerRows(context: context)
        XCTAssertEqual(ledger.count, 2)
        XCTAssertTrue(ledger.allSatisfy { $0.platform == .codex })

        linkService.unlinkCalls.removeAll()
        linkService.throwOnUnlink = []
        let retryResult = reconciler.reconcile(context: context)

        XCTAssertFalse(retryResult.hasFailures)
        XCTAssertEqual(linkService.unlinkCalls.map(\.platform), [.codex, .codex])
        ledger = try ledgerRows(context: context)
        XCTAssertTrue(ledger.isEmpty)
    }

    @MainActor
    func testZeroInstalledAgentsIsCalmNoOp() throws {
        let context = try makeContext()
        _ = try seedTwoProjectCategory(context: context)
        let linkService = RecordingLinkService()
        let cursorCompiler = RecordingCursorCompiler()
        let reconciler = makeReconciler(
            installed: [],
            linkService: linkService,
            cursorCompiler: cursorCompiler
        )

        let result = reconciler.reconcile(context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(linkService.linkCalls.isEmpty)
        XCTAssertTrue(cursorCompiler.compileCalls.isEmpty)
        XCTAssertTrue(try ledgerRows(context: context).isEmpty)
    }

    @MainActor
    func testDanglingIdsAreSkippedWithoutTrapping() throws {
        let context = try makeContext()
        let category = PensieveCategory(name: "Dangling")
        category.skillSlugs = ["missing-skill"]
        category.projectKeys = ["missing-project"]
        context.insert(category)
        try context.save()
        let linkService = RecordingLinkService()
        let cursorCompiler = RecordingCursorCompiler()
        let reconciler = makeReconciler(
            installed: [.claudeCode, .codex, .cursor],
            linkService: linkService,
            cursorCompiler: cursorCompiler
        )

        let result = reconciler.reconcile(context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(linkService.linkCalls.isEmpty)
        XCTAssertTrue(cursorCompiler.compileCalls.isEmpty)
    }
}

extension CategoryReconcilerTests {
    private func makeReconciler(
        installed: [PlatformTarget],
        linkService: RecordingLinkService = RecordingLinkService(),
        cursorCompiler: RecordingCursorCompiler = RecordingCursorCompiler()
    ) -> CategoryReconciler {
        linkService.fileService = files
        cursorCompiler.fileService = files
        let vm = PlatformViewModel(
            fileService: files,
            linkService: linkService,
            cursorCompiler: cursorCompiler,
            agentDetection: StubDetection(installed: installed), deployStateStore: .memoryBacked
        )
        return CategoryReconciler(platformVM: vm)
    }
}
