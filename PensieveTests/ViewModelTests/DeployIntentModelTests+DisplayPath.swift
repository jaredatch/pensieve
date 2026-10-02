import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension DeployIntentModelTests {
    func testPublishedProjectPathIsInertForIntentReloadAndApply() throws {
        let withoutPath = try intentSnapshot(projectPath: nil)
        let withPath = try intentSnapshot(projectPath: "~/Projects/Remote")

        XCTAssertEqual(withPath, withoutPath)
    }
}

@MainActor
private extension DeployIntentModelTests {
    struct IntentSnapshot: Equatable {
        let machines: [DeployIntentMachine]
        let platforms: [PlatformTarget]
        let selectionBefore: Set<String>
        let selectionAfter: Set<String>
        let intentKeys: [String]
        let linkCalls: [ScenarioRecordedLink]
        let files: Set<String>
        let symlinks: Set<String>
    }

    func intentSnapshot(projectPath: String?) throws -> IntentSnapshot {
        let state = MachineState(
            schemaVersion: 1,
            machineID: remoteID,
            name: "Mini",
            appVersion: "test",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            agents: [PlatformTarget.hermes.rawValue],
            projects: [MachineStateProject(
                identityKey: "github.com/example/remote",
                kind: "git-remote",
                name: "Remote",
                path: projectPath
            )],
            userDeploys: [],
            projectDeploys: []
        )
        let harness = try makeHarness(states: [state])
        let skill = try insertSkill(context: harness.context)
        harness.model.reload(context: harness.context)
        let machines = harness.model.machines
        let platforms = harness.model.availablePlatforms
        let selectionBefore = try harness.model.selectedMachineIDs(
            skills: [skill], platforms: [.codex], context: harness.context
        )
        _ = try harness.model.apply(
            skills: [skill], platforms: [.codex], selectedMachineIDs: [localID, remoteID],
            context: harness.context
        )
        let selectionAfter = try harness.model.selectedMachineIDs(
            skills: [skill], platforms: [.codex], context: harness.context
        )
        return IntentSnapshot(
            machines: machines,
            platforms: platforms,
            selectionBefore: selectionBefore,
            selectionAfter: selectionAfter,
            intentKeys: try harness.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key).sorted(),
            linkCalls: harness.linkService.linkCalls,
            files: harness.linkService.fileService.files,
            symlinks: harness.linkService.fileService.symlinks
        )
    }
}
