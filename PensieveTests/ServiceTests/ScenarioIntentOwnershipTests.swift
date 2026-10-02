import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ScenarioIntentOwnershipTests: XCTestCase {
    func testIntentOwnedDeploySurvivesScenarioRetraction() throws {
        let context = ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
        let fileService = ScenarioRecordingFileService()
        let linkService = ScenarioRecordingLinkService(fileService: fileService)
        let platformVM = PlatformViewModel(
            fileService: fileService,
            linkService: linkService,
            cursorCompiler: ScenarioRecordingCursorCompiler(fileService: fileService),
            agentDetection: ScenarioStubDetection(installed: [.codex]),
            deployStateStore: DeployStateStore(fileService: fileService)
        )
        let defaults = try isolatedDefaults()
        let store = ScenarioStore(defaults: defaults)
        let reconciler = ScenarioReconciler(platformVM: platformVM, scenarioStore: store)
        let skill = Skill(name: "Shared", directoryName: "shared")
        let scenario = Scenario(name: "Shared")
        scenario.skillSlugs = [skill.directoryName]
        scenario.agentRawValues = [PlatformTarget.codex.rawValue]
        context.insert(skill)
        context.insert(scenario)
        try context.save()
        _ = store.activate(scenario, reconciler: reconciler, context: context)
        context.insert(IntentAssignment(skillID: skill.id, platformRaw: PlatformTarget.codex.rawValue))
        try context.save()
        let path = linkService.linkPath(skill: skill, platform: .codex, projectPath: nil)
        linkService.unlinkCalls.removeAll()

        let result = store.deactivate(reconciler: reconciler, context: context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(linkService.unlinkCalls.isEmpty)
        XCTAssertTrue(fileService.symlinks.contains(path))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScenarioAssignment>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
    }
}
