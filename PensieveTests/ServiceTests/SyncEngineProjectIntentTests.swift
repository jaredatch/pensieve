import SwiftData
import XCTest
@testable import Pensieve

extension SyncEngineTests {
    func makeContext() throws -> ModelContext {
        let schema = Schema([
            Skill.self, Project.self, SkillProjectAssignment.self, ScenarioAssignment.self,
            DeployRecord.self, Pensieve.Category.self, Scenario.self, RepoUpdateCursor.self,
            MachineDeployIntent.self, IntentAssignment.self
        ])
        return ModelContext(try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
    }

    func seedProjectIntent(in context: ModelContext) throws {
        context.insert(MachineDeployIntent(
            machineID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
            skillSlug: "durable-intent",
            platformRaw: "codex",
            projectKey: "github.com/owner/project"
        ))
        try context.save()
    }

    func testConflictInspectionPreparationKeepsProjectIntent() throws {
        let git = StubGit()
        git.pullResult = .conflicted(["skills/x/SKILL.md"])
        let context = try makeContext()
        try seedProjectIntent(in: context)
        let manifest = ManifestService()
        try manifest.write(try manifest.snapshot(from: context), toRoot: tempDir)

        let inspection = try makeEngine(git: git).inspectConflicts(
            root: tempDir,
            credential: nil,
            context: context
        )

        guard case .conflicts = inspection else { return XCTFail("expected conflicts") }
        XCTAssertEqual(
            try manifest.read(fromRoot: tempDir).deployIntents.first?.projectKey,
            "github.com/owner/project"
        )
    }
}
