import XCTest
@testable import Pensieve

extension DeployIntentModelTests {
    func testIntentChangeForDifferentSkillKeepsProjectIntent() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        harness.context.insert(MachineDeployIntent(
            machineID: remoteID,
            skillSlug: "durable-intent",
            platformRaw: "cursor",
            projectKey: "github.com/owner/project"
        ))
        try harness.context.save()

        _ = try harness.model.setSelected(
            true, machineID: remoteID, skill: skill, platform: .codex, context: harness.context
        )

        let records = try ManifestService(fileService: harness.manifestFileService)
            .read(fromRoot: harness.root).deployIntents
        XCTAssertEqual(records.first { $0.skillSlug == "durable-intent" }?.projectKey,
                       "github.com/owner/project")
    }
}
