import SwiftData
import XCTest
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

private final class RecordingManifest: ManifestSnapshotting {
    private(set) var writtenSnapshots: [ManifestSnapshot] = []

    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        writtenSnapshots.append(snapshot)
    }

    func read(fromRoot root: String) throws -> ManifestSnapshot {
        ManifestSnapshot(schemaVersion: ManifestService.currentSchemaVersion,
                         categories: [], scenarios: [], projects: [], skills: [])
    }

    func snapshot(from context: ModelContext) throws -> ManifestSnapshot {
        let scenarios = try context.fetch(FetchDescriptor<Scenario>())
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
            .map {
                ScenarioRecord(
                    id: $0.id.uuidString,
                    name: $0.name,
                    skillSlugs: $0.skillSlugs,
                    agents: $0.agentRawValues
                )
            }
        return ManifestSnapshot(
            schemaVersion: ManifestService.currentSchemaVersion,
            categories: [],
            scenarios: scenarios,
            projects: [],
            skills: []
        )
    }
}

final class ScenarioStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var manifest: RecordingManifest!
    private var store: ScenarioStore!

    override func setUpWithError() throws {
        suiteName = isolatedDefaultsSuite()
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        manifest = RecordingManifest()
        store = ScenarioStore(manifestService: manifest, manifestRoot: "/tmp/scenarios", defaults: defaults)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
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

    @MainActor
    private func scenarioCount(in context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<Scenario>()).count
    }

    @MainActor
    func testCreateDefaultsToAllAgentsTrimsNameAndRejectsBlankName() throws {
        let context = try makeContext()

        let scenario = try XCTUnwrap(store.create(name: "  React Frontend  ", context: context))

        XCTAssertEqual(scenario.name, "React Frontend")
        XCTAssertEqual(scenario.agentRawValues, PlatformTarget.allCases.map(\.rawValue))
        XCTAssertEqual(try scenarioCount(in: context), 1)
        XCTAssertNil(store.create(name: "   ", context: context))
        XCTAssertEqual(try scenarioCount(in: context), 1)
        XCTAssertEqual(manifest.writtenSnapshots.count, 1)
    }

    @MainActor
    func testRenameKeepsIdentitySoActiveReferenceStillResolves() throws {
        let context = try makeContext()
        let scenario = try XCTUnwrap(store.create(name: "Old Name", context: context))
        let id = scenario.id
        store.setActiveScenarioID(id)

        store.rename(scenario, to: "New Name", context: context)

        XCTAssertEqual(scenario.id, id)
        XCTAssertEqual(scenario.name, "New Name")
        XCTAssertEqual(store.activeScenarioID(), id)
    }

    @MainActor
    func testSetSkillAndSetAgentToggleIdempotently() throws {
        let context = try makeContext()
        let scenario = try XCTUnwrap(store.create(name: "Frontend", context: context))
        let skill = Skill(name: "React", directoryName: "react")
        context.insert(skill)

        store.setSkill(skill, inScenario: scenario, assigned: true, context: context)
        store.setSkill(skill, inScenario: scenario, assigned: true, context: context)
        XCTAssertEqual(scenario.skillSlugs, ["react"])

        store.setSkill(skill, inScenario: scenario, assigned: false, context: context)
        store.setSkill(skill, inScenario: scenario, assigned: false, context: context)
        XCTAssertTrue(scenario.skillSlugs.isEmpty)

        store.setAgent(.cursor, inScenario: scenario, enabled: false, context: context)
        store.setAgent(.cursor, inScenario: scenario, enabled: false, context: context)
        XCTAssertEqual(scenario.agentRawValues, ["claudeCode", "grok", "codex", "openClaw", "hermes"])

        store.setAgent(.cursor, inScenario: scenario, enabled: true, context: context)
        store.setAgent(.cursor, inScenario: scenario, enabled: true, context: context)
        XCTAssertEqual(scenario.agentRawValues, PlatformTarget.allCases.map(\.rawValue))
    }

    @MainActor
    func testUnknownAgentSurvivesEnable() throws {
        let context = try makeContext()
        let scenario = Scenario(name: "Forward Compatible")
        scenario.agentRawValues = [PlatformTarget.cursor.rawValue, "nonexistent-agent-fixture"]
        context.insert(scenario)

        store.setAgent(.codex, inScenario: scenario, enabled: true, context: context)

        XCTAssertEqual(
            scenario.agentRawValues,
            [PlatformTarget.cursor.rawValue, PlatformTarget.codex.rawValue, "nonexistent-agent-fixture"]
        )
    }

    @MainActor
    func testUnknownAgentSurvivesDisable() throws {
        let context = try makeContext()
        let scenario = Scenario(name: "Forward Compatible")
        scenario.agentRawValues = [
            PlatformTarget.claudeCode.rawValue,
            PlatformTarget.cursor.rawValue,
            "nonexistent-agent-fixture"
        ]
        context.insert(scenario)

        store.setAgent(.cursor, inScenario: scenario, enabled: false, context: context)

        XCTAssertEqual(
            scenario.agentRawValues,
            [PlatformTarget.claudeCode.rawValue, "nonexistent-agent-fixture"]
        )
    }

    @MainActor
    func testKnownAgentsKeepAllCasesOrder() throws {
        let context = try makeContext()
        let scenario = Scenario(name: "Ordered")
        scenario.agentRawValues = [
            "nonexistent-agent-fixture",
            PlatformTarget.cursor.rawValue,
            PlatformTarget.claudeCode.rawValue
        ]
        context.insert(scenario)

        store.setAgent(.codex, inScenario: scenario, enabled: true, context: context)

        XCTAssertEqual(
            scenario.agentRawValues,
            [
                PlatformTarget.claudeCode.rawValue,
                PlatformTarget.cursor.rawValue,
                PlatformTarget.codex.rawValue,
                "nonexistent-agent-fixture"
            ]
        )
    }

    @MainActor
    func testLegacyAgentsSurviveCarryWithoutRebuildingScenarios() throws {
        let tempDir = NSTemporaryDirectory() + "PensieveScenarioRoundTrip-\(UUID().uuidString)"
        let fileService = FileService()
        try fileService.createDirectory(at: tempDir)
        defer { try? fileService.deleteFile(at: tempDir) }

        let manifestService = ManifestService(fileService: fileService)
        let roundTripStore = ScenarioStore(
            manifestService: manifestService,
            manifestRoot: tempDir,
            defaults: defaults
        )
        let sourceContext = try makeContext()
        let scenario = Scenario(name: "Synced")
        scenario.agentRawValues = [PlatformTarget.cursor.rawValue, "nonexistent-agent-fixture"]
        sourceContext.insert(scenario)
        let legacy = "id: \(scenario.id.uuidString)\nname: Synced\nagents:\n  - nonexistent-agent-fixture\n"
        try fileService.writeFile(at: tempDir + "/manifest/scenarios/legacy.yaml", content: legacy)

        roundTripStore.setAgent(.codex, inScenario: scenario, enabled: true, context: sourceContext)
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/manifest/scenarios/legacy.yaml"), legacy)

        let rebuiltContext = try makeContext()
        let rebuild = StoreRebuildService(fileService: fileService, manifestService: manifestService)
        let result = rebuild.rebuild(fromRoot: tempDir, context: rebuiltContext)
        XCTAssertFalse(result.storeUnreadable)
        XCTAssertEqual(result.scenariosInserted, 0)
        XCTAssertTrue(try rebuiltContext.fetch(FetchDescriptor<Scenario>()).isEmpty)
        XCTAssertEqual(
            scenario.agentRawValues,
            [PlatformTarget.cursor.rawValue, PlatformTarget.codex.rawValue, "nonexistent-agent-fixture"]
        )
    }

    @MainActor
    func testDeleteClearsMatchingActiveReferenceAndLeavesNonMatchingReference() throws {
        let context = try makeContext()
        let active = try XCTUnwrap(store.create(name: "Active", context: context))
        let inactive = try XCTUnwrap(store.create(name: "Inactive", context: context))

        store.setActiveScenarioID(active.id)
        store.delete(active, context: context)

        XCTAssertNil(store.activeScenarioID())
        XCTAssertEqual(try scenarioCount(in: context), 1)

        let otherID = UUID()
        store.setActiveScenarioID(otherID)
        store.delete(inactive, context: context)

        XCTAssertEqual(store.activeScenarioID(), otherID)
        XCTAssertEqual(try scenarioCount(in: context), 0)
    }

    @MainActor
    func testEveryMutationRegeneratesManifest() throws {
        let context = try makeContext()
        let scenario = try XCTUnwrap(store.create(name: "Mutating", context: context))
        let skill = Skill(name: "Swift", directoryName: "swift")
        context.insert(skill)
        XCTAssertEqual(manifest.writtenSnapshots.count, 1)

        store.rename(scenario, to: "Renamed", context: context)
        store.setSkill(skill, inScenario: scenario, assigned: true, context: context)
        store.setAgent(.cursor, inScenario: scenario, enabled: false, context: context)
        store.delete(scenario, context: context)

        XCTAssertEqual(manifest.writtenSnapshots.count, 5)
        XCTAssertEqual(manifest.writtenSnapshots.last?.scenarios, [])
    }

    @MainActor
    func testScenariosContainingSkillSlugFilters() throws {
        let context = try makeContext()
        let frontend = try XCTUnwrap(store.create(name: "Frontend", context: context))
        let backend = try XCTUnwrap(store.create(name: "Backend", context: context))
        let react = Skill(name: "React", directoryName: "react")
        context.insert(react)

        store.setSkill(react, inScenario: frontend, assigned: true, context: context)

        let matches = store.scenarios(containingSkillSlug: "react", context: context)

        XCTAssertEqual(matches.map(\.name), ["Frontend"])
        XCTAssertFalse(matches.contains { $0.id == backend.id })
    }
}
