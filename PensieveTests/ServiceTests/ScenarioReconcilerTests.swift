import SwiftData
import XCTest
@testable import Pensieve
final class ScenarioReconcilerTests: XCTestCase {
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
    private func makeHarness(installed: [PlatformTarget]) -> ScenarioHarness {
        let fileService = ScenarioRecordingFileService()
        let linkService = ScenarioRecordingLinkService(fileService: fileService)
        let cursorCompiler = ScenarioRecordingCursorCompiler(fileService: fileService)
        let store = ScenarioStore(defaults: defaults)
        let deployStateStore = DeployStateStore(
            fileService: fileService,
            appSupportDir: "/tmp/ScenarioReconcilerTests-\(UUID().uuidString)"
        )
        let vm = PlatformViewModel(
            fileService: fileService,
            linkService: linkService,
            cursorCompiler: cursorCompiler,
            agentDetection: ScenarioStubDetection(installed: installed),
            deployStateStore: deployStateStore
        )
        return ScenarioHarness(
            store: store,
            reconciler: ScenarioReconciler(platformVM: vm, scenarioStore: store),
            fileService: fileService,
            linkService: linkService,
            cursorCompiler: cursorCompiler
        )
    }
    @MainActor
    private func makeSkill(_ slug: String, context: ModelContext) -> Skill {
        let skill = Skill(name: slug, directoryName: slug)
        context.insert(skill)
        return skill
    }
    @MainActor
    private func makeScenario(
        name: String,
        skills: [Skill],
        agents: [PlatformTarget],
        context: ModelContext
    ) -> Scenario {
        let scenario = Scenario(name: name)
        scenario.skillSlugs = skills.map(\.directoryName)
        scenario.agentRawValues = agents.map(\.rawValue)
        context.insert(scenario)
        return scenario
    }
    @MainActor
    private func ledgerRows(context: ModelContext) throws -> [ScenarioAssignment] {
        try context.fetch(FetchDescriptor<ScenarioAssignment>())
    }
}
extension ScenarioReconcilerTests {
    @MainActor
    func testActivateDeploysMembersAcrossEnabledInstalledAgents() throws {
        let context = try makeContext()
        let first = makeSkill("alpha", context: context)
        let second = makeSkill("bravo", context: context)
        let scenario = makeScenario(
            name: "Work",
            skills: [first, second],
            agents: [.claudeCode, .cursor, .codex],
            context: context
        )
        try context.save()
        let harness = makeHarness(installed: [.claudeCode, .cursor])
        let result = harness.store.activate(scenario, reconciler: harness.reconciler, context: context)
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(Set(harness.linkService.linkCalls), Set([
            ScenarioRecordedLink(directoryName: "alpha", platform: .claudeCode, projectPath: nil),
            ScenarioRecordedLink(directoryName: "bravo", platform: .claudeCode, projectPath: nil)
        ]))
        XCTAssertEqual(Set(harness.cursorCompiler.compileCalls), Set([
            ScenarioRecordedCursorCall(directoryName: "alpha", projectPath: nil),
            ScenarioRecordedCursorCall(directoryName: "bravo", projectPath: nil)
        ]))
        XCTAssertEqual(try ledgerRows(context: context).count, 4)
    }

    @MainActor
    func testManualDeploysSurviveSwitch() throws {
        let context = try makeContext()
        let manual = makeSkill("manual", context: context)
        let firstSkill = makeSkill("first", context: context)
        let secondSkill = makeSkill("second", context: context)
        let firstScenario = makeScenario(name: "First", skills: [firstSkill], agents: [.claudeCode], context: context)
        let secondScenario = makeScenario(name: "Second", skills: [secondSkill], agents: [.claudeCode], context: context)
        try context.save()
        let harness = makeHarness(installed: [.claudeCode])

        harness.store.setActiveScenarioID(nil)
        harness.reconciler.platformVM.deploy(skill: manual, platform: .claudeCode, target: .userWide, context: context)
        _ = harness.store.activate(firstScenario, reconciler: harness.reconciler, context: context)
        harness.linkService.unlinkCalls.removeAll()

        _ = harness.store.activate(secondScenario, reconciler: harness.reconciler, context: context)
        XCTAssertFalse(harness.linkService.unlinkCalls.contains {
            $0.directoryName == manual.directoryName && $0.platform == .claudeCode
        })
        XCTAssertTrue(harness.fileService.symlinks.contains(
            harness.linkService.linkPath(skill: manual, platform: .claudeCode, projectPath: nil)
        ))
    }

    @MainActor
    func testSwitchOverlapDoesNotChurn() throws {
        let context = try makeContext()
        let alpha = makeSkill("alpha", context: context)
        let overlap = makeSkill("overlap", context: context)
        let charlie = makeSkill("charlie", context: context)
        let firstScenario = makeScenario(name: "First", skills: [alpha, overlap], agents: [.claudeCode], context: context)
        let secondScenario = makeScenario(name: "Second", skills: [overlap, charlie], agents: [.claudeCode], context: context)
        try context.save()
        let harness = makeHarness(installed: [.claudeCode])
        _ = harness.store.activate(firstScenario, reconciler: harness.reconciler, context: context)
        harness.linkService.linkCalls.removeAll()
        harness.linkService.unlinkCalls.removeAll()
        _ = harness.store.activate(secondScenario, reconciler: harness.reconciler, context: context)
        XCTAssertEqual(harness.linkService.linkCalls, [
            ScenarioRecordedLink(directoryName: "charlie", platform: .claudeCode, projectPath: nil)
        ])
        XCTAssertEqual(harness.linkService.unlinkCalls, [
            ScenarioRecordedLink(directoryName: "alpha", platform: .claudeCode, projectPath: nil)
        ])
    }

    @MainActor
    func testDeactivateRemovesAllManagedDeploys() throws {
        let context = try makeContext()
        let alpha = makeSkill("alpha", context: context)
        let scenario = makeScenario(name: "Work", skills: [alpha], agents: [.claudeCode, .cursor], context: context)
        try context.save()
        let harness = makeHarness(installed: [.claudeCode, .cursor])
        _ = harness.store.activate(scenario, reconciler: harness.reconciler, context: context)
        harness.linkService.unlinkCalls.removeAll()
        harness.cursorCompiler.removeCalls.removeAll()
        let result = harness.store.deactivate(reconciler: harness.reconciler, context: context)
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(harness.linkService.unlinkCalls, [
            ScenarioRecordedLink(directoryName: "alpha", platform: .claudeCode, projectPath: nil)
        ])
        XCTAssertEqual(harness.cursorCompiler.removeCalls, [
            ScenarioRecordedCursorCall(directoryName: "alpha", projectPath: nil)
        ])
        XCTAssertTrue(try ledgerRows(context: context).isEmpty)
        XCTAssertNil(harness.store.activeScenarioID())
    }

    @MainActor
    func testInactiveEditPerformsNoFileOps() throws {
        let context = try makeContext()
        let alpha = makeSkill("alpha", context: context)
        let beta = makeSkill("beta", context: context)
        let active = makeScenario(name: "Active", skills: [alpha], agents: [.claudeCode], context: context)
        let inactive = makeScenario(name: "Inactive", skills: [], agents: [.claudeCode], context: context)
        try context.save()
        let harness = makeHarness(installed: [.claudeCode])
        _ = harness.store.activate(active, reconciler: harness.reconciler, context: context)
        harness.linkService.linkCalls.removeAll()
        harness.linkService.unlinkCalls.removeAll()

        let result = harness.store.setSkill(beta, inScenario: inactive, assigned: true,
                                            reconciler: harness.reconciler, context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
    }

    @MainActor
    func testDanglingActiveReferenceConvergesOnNextReconcile() throws {
        let context = try makeContext()
        let skill = makeSkill("alpha", context: context)
        context.insert(ScenarioAssignment(skillID: skill.id, platform: .claudeCode))
        try context.save()
        let harness = makeHarness(installed: [.claudeCode])
        harness.store.setActiveScenarioID(UUID())
        harness.fileService.symlinks.insert(
            harness.linkService.linkPath(skill: skill, platform: .claudeCode, projectPath: nil)
        )

        let result = harness.reconciler.reconcile(context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(harness.linkService.unlinkCalls, [
            ScenarioRecordedLink(directoryName: "alpha", platform: .claudeCode, projectPath: nil)
        ])
        XCTAssertTrue(try ledgerRows(context: context).isEmpty)
    }

    @MainActor
    func testStaleCursorArtifactRemovedOnSwitchAway() throws {
        let context = try makeContext()
        let skill = makeSkill("alpha", context: context)
        let first = makeScenario(name: "First", skills: [skill], agents: [.cursor], context: context)
        let second = makeScenario(name: "Second", skills: [], agents: [.cursor], context: context)
        try context.save()
        let harness = makeHarness(installed: [.cursor])
        _ = harness.store.activate(first, reconciler: harness.reconciler, context: context)
        harness.cursorCompiler.removeCalls.removeAll()

        let result = harness.store.activate(second, reconciler: harness.reconciler, context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(harness.cursorCompiler.removeCalls, [
            ScenarioRecordedCursorCall(directoryName: "alpha", projectPath: nil)
        ])
        XCTAssertTrue(try ledgerRows(context: context).isEmpty)
    }

    @MainActor
    func testFailedUnlinkKeepsLedgerRow() throws {
        let context = try makeContext()
        let skill = makeSkill("alpha", context: context)
        let first = makeScenario(name: "First", skills: [skill], agents: [.claudeCode], context: context)
        let second = makeScenario(name: "Second", skills: [], agents: [.claudeCode], context: context)
        try context.save()
        let harness = makeHarness(installed: [.claudeCode])
        _ = harness.store.activate(first, reconciler: harness.reconciler, context: context)
        harness.linkService.throwOnUnlink = [.claudeCode]

        let result = harness.store.activate(second, reconciler: harness.reconciler, context: context)

        XCTAssertEqual(result.failures.count, 1)
        let rows = try ledgerRows(context: context)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.platform, .claudeCode)
    }

    @MainActor
    func testSecondReconcileIsNoOp() throws {
        let context = try makeContext()
        let skill = makeSkill("alpha", context: context)
        let scenario = makeScenario(name: "Work", skills: [skill], agents: [.claudeCode, .cursor], context: context)
        try context.save()
        let harness = makeHarness(installed: [.claudeCode, .cursor])
        _ = harness.store.activate(scenario, reconciler: harness.reconciler, context: context)
        harness.linkService.linkCalls.removeAll()
        harness.linkService.unlinkCalls.removeAll()
        harness.cursorCompiler.compileCalls.removeAll()
        harness.cursorCompiler.removeCalls.removeAll()

        let result = harness.reconciler.reconcile(context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
        XCTAssertTrue(harness.cursorCompiler.compileCalls.isEmpty)
        XCTAssertTrue(harness.cursorCompiler.removeCalls.isEmpty)
    }

    @MainActor
    func testWrongTargetSymlinkStillRemovedOnSwitchAway() throws {
        let context = try makeContext()
        let skill = makeSkill("alpha", context: context)
        context.insert(ScenarioAssignment(skillID: skill.id, platform: .claudeCode))
        try context.save()
        let harness = makeHarness(installed: [.claudeCode])
        harness.store.setActiveScenarioID(nil)
        harness.fileService.symlinks.insert(
            harness.linkService.linkPath(skill: skill, platform: .claudeCode, projectPath: nil)
        )

        let result = harness.reconciler.reconcile(context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(harness.linkService.unlinkCalls, [
            ScenarioRecordedLink(directoryName: "alpha", platform: .claudeCode, projectPath: nil)
        ])
        XCTAssertTrue(try ledgerRows(context: context).isEmpty)
    }

    @MainActor
    func testDeleteActiveScenarioRemovesManagedDeploys() throws {
        let context = try makeContext()
        let skill = makeSkill("alpha", context: context)
        let scenario = makeScenario(name: "Work", skills: [skill], agents: [.claudeCode], context: context)
        try context.save()
        let harness = makeHarness(installed: [.claudeCode])
        _ = harness.store.activate(scenario, reconciler: harness.reconciler, context: context)
        harness.linkService.unlinkCalls.removeAll()

        let result = harness.store.delete(scenario, reconciler: harness.reconciler, context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(harness.linkService.unlinkCalls, [
            ScenarioRecordedLink(directoryName: "alpha", platform: .claudeCode, projectPath: nil)
        ])
        XCTAssertNil(harness.store.activeScenarioID())
        XCTAssertEqual(try context.fetch(FetchDescriptor<Scenario>()).count, 0)
        XCTAssertTrue(try ledgerRows(context: context).isEmpty)
    }

    @MainActor
    func testEmptyScenarioDoesNothing() throws {
        let context = try makeContext()
        let scenario = makeScenario(name: "Empty", skills: [], agents: [.claudeCode], context: context)
        try context.save()
        let harness = makeHarness(installed: [.claudeCode])

        let result = harness.store.activate(scenario, reconciler: harness.reconciler, context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertTrue(try ledgerRows(context: context).isEmpty)
    }

    @MainActor
    func testDanglingMemberSlugIsSkipped() throws {
        let context = try makeContext()
        let scenario = Scenario(name: "Dangling")
        scenario.skillSlugs = ["missing"]
        scenario.agentRawValues = [PlatformTarget.claudeCode.rawValue]
        context.insert(scenario)
        try context.save()
        let harness = makeHarness(installed: [.claudeCode])

        let result = harness.store.activate(scenario, reconciler: harness.reconciler, context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
    }

    @MainActor
    func testUninstalledAgentRowClearsWhenArtifactAbsent() throws {
        let context = try makeContext()
        let skill = makeSkill("alpha", context: context)
        context.insert(ScenarioAssignment(skillID: skill.id, platform: .hermes))
        try context.save()
        let harness = makeHarness(installed: [.claudeCode])

        let result = harness.reconciler.reconcile(context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
        XCTAssertTrue(try ledgerRows(context: context).isEmpty)
    }

    @MainActor
    func testFailedDeployDoesNotLedgerAndRetries() throws {
        let context = try makeContext()
        let skill = makeSkill("alpha", context: context)
        let scenario = makeScenario(name: "Work", skills: [skill], agents: [.claudeCode], context: context)
        try context.save()
        let harness = makeHarness(installed: [.claudeCode])
        harness.linkService.throwOnLink = [.claudeCode]

        let failed = harness.store.activate(scenario, reconciler: harness.reconciler, context: context)

        XCTAssertEqual(failed.failures.count, 1)
        XCTAssertTrue(try ledgerRows(context: context).isEmpty)

        harness.linkService.throwOnLink = []
        harness.linkService.linkCalls.removeAll()
        let retry = harness.reconciler.reconcile(context: context)

        XCTAssertFalse(retry.hasFailures)
        XCTAssertEqual(harness.linkService.linkCalls, [
            ScenarioRecordedLink(directoryName: "alpha", platform: .claudeCode, projectPath: nil)
        ])
        XCTAssertEqual(try ledgerRows(context: context).count, 1)
    }
}
