import SwiftData
import XCTest
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

final class StoreRebuildScenarioTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var manifest: ManifestService!
    private var service: StoreRebuildService!

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveRebuildScenarioTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        manifest = ManifestService(fileService: fileService)
        service = StoreRebuildService(fileService: fileService, manifestService: manifest)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self,
            PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func writeManifest(scenarios: [LegacyScenarioDefinition]) throws {
        try manifest.write(
            ManifestSnapshot(
                schemaVersion: ManifestService.currentSchemaVersion,
                categories: [],
                    projects: [],
                skills: []
            ),
            toRoot: tempDir
        )
        for record in scenarios {
            try fileService.writeFile(
                at: tempDir + "/manifest/scenarios/" + LegacyScenarioDefinition.fileName(name: record.name, id: record.id),
                content: LegacyScenarioDefinition.serialize(record)
            )
        }
    }

    @MainActor
    func testManifestScenarioAbsentLocallyIsNotInserted() throws {
        let context = try makeContext()
        let id = UUID()
        try writeManifest(scenarios: [
            LegacyScenarioDefinition(id: id.uuidString, name: "Frontend", skillSlugs: ["react"], agents: ["cursor"])
        ])

        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Scenario>()).isEmpty)
    }

    @MainActor
    func testPresentButDifferentScenarioIsPreserved() throws {
        let context = try makeContext()
        let id = UUID()
        let scenario = Scenario(id: id, name: "Old")
        scenario.skillSlugs = ["old"]
        scenario.agentRawValues = ["claudeCode"]
        context.insert(scenario)
        try context.save()

        try writeManifest(scenarios: [
            LegacyScenarioDefinition(id: id.uuidString, name: "New", skillSlugs: ["new"], agents: ["codex", "cursor"])
        ])

        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Scenario>()).count, 1)
        XCTAssertEqual(scenario.id, id)
        XCTAssertEqual(scenario.name, "Old")
        XCTAssertEqual(scenario.skillSlugs, ["old"])
        XCTAssertEqual(scenario.agentRawValues, ["claudeCode"])
    }

    @MainActor
    func testRebuildLeavesLocalNameAndActiveReferenceAlone() throws {
        let context = try makeContext()
        let id = UUID()
        let scenario = Scenario(id: id, name: "Local Name")
        context.insert(scenario)
        try context.save()
        let defaults = try isolatedDefaults()
        defaults.set(id.uuidString, forKey: ScenarioHandover.activeKey)

        try writeManifest(scenarios: [
            LegacyScenarioDefinition(id: id.uuidString, name: "Remote Rename", skillSlugs: [], agents: ["cursor"])
        ])

        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Scenario>()).count, 1)
        XCTAssertEqual(scenario.id, id)
        XCTAssertEqual(scenario.name, "Local Name")
        XCTAssertEqual(defaults.string(forKey: ScenarioHandover.activeKey), id.uuidString)
    }

    @MainActor
    func testLocallyPresentButAbsentFromManifestIsPreserved() throws {
        let context = try makeContext()
        context.insert(Scenario(name: "Local Only"))
        try context.save()
        try writeManifest(scenarios: [])

        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Scenario>()).first?.name, "Local Only")
    }

    @MainActor
    func testCorruptScenarioFileDoesNotBlockRebuild() throws {
        let context = try makeContext()
        let scenario = Scenario(name: "Preserve Me")
        scenario.skillSlugs = ["keep"]
        context.insert(scenario)
        try context.save()

        try writeManifest(scenarios: [
            LegacyScenarioDefinition(id: UUID().uuidString, name: "Remote", skillSlugs: ["remote"], agents: ["cursor"])
        ])
        let scenarioDir = tempDir + "/manifest/scenarios"
        let scenarioFile = try XCTUnwrap(try fileService.listDirectory(at: scenarioDir).first { $0.hasSuffix(".yaml") })
        try fileService.writeFile(at: scenarioDir + "/" + scenarioFile, content: ":\n  - [\n")

        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertFalse(result.storeUnreadable)
        let scenarios = try context.fetch(FetchDescriptor<Scenario>())
        XCTAssertEqual(scenarios.count, 1)
        XCTAssertEqual(scenarios.first?.id, scenario.id)
        XCTAssertEqual(scenarios.first?.name, "Preserve Me")
        XCTAssertEqual(scenarios.first?.skillSlugs, ["keep"])
    }
}
