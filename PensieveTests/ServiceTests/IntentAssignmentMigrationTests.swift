import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class IntentAssignmentMigrationTests: XCTestCase {
    func testPreProjectIntentStoreOpensWithRowsAndKeysUnchanged() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PreProjectIntent.store")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PensieveProjectIntentMigration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: fixture, to: storeURL)

        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: storeURL))
        let context = ModelContext(container)
        let intents = try context.fetch(FetchDescriptor<MachineDeployIntent>())
        let assignments = try context.fetch(FetchDescriptor<IntentAssignment>())

        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents[0].key, "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA|existing|codex")
        XCTAssertNil(intents[0].projectKey)
        XCTAssertEqual(assignments.count, 1)
        XCTAssertEqual(assignments[0].key, "11111111-1111-4111-8111-111111111111|codex")
        XCTAssertNil(assignments[0].projectID)
    }

    func testExistingStoreOpensUnderIntentAssignmentSchema() throws {
        let directory = NSTemporaryDirectory() + "PensieveIntentAssignmentMigration-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let url = URL(fileURLWithPath: directory + "/default.store")
        let priorSchema = Schema([
            Skill.self, Project.self, SkillProjectAssignment.self, ScenarioAssignment.self,
            DeployRecord.self, Category.self, Scenario.self, RepoUpdateCursor.self,
            MachineDeployIntent.self
        ])
        do {
            let priorContainer = try ModelContainer(
                for: priorSchema, configurations: ModelConfiguration(url: url)
            )
            let priorContext = ModelContext(priorContainer)
            priorContext.insert(Skill(
                name: "Existing", skillDescription: "Existing description", tags: [],
                scope: .user, directoryName: "existing", cursorConfig: nil, importedFrom: nil
            ))
            try priorContext.save()
        }

        let extended = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: url))
        let context = ModelContext(extended)
        let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first)
        context.insert(IntentAssignment(skillID: skill.id, platformRaw: PlatformTarget.codex.rawValue))
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
    }
}
