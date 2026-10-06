import SwiftData
import XCTest
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

/// PLAN-07 / 07.6 — the holistic end-to-end gate. Fabricate a store on disk via the real services, run
/// the one-time migration, then rebuild into a FRESH in-memory context from disk + manifest ALONE. The
/// store must be self-sufficient: every synced field survives with no loss, and a second rebuild is a
/// no-op. This is the executable proof that `~/.pensieve` is a complete, portable, rebuildable source of
/// truth (no git — that is PLAN-08).
final class StoreRoundTripTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var manifest: ManifestService!
    private var skillStore: SkillStore!
    private var migration: StoreMigrationService!
    private var rebuildService: StoreRebuildService!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveRoundTripTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        manifest = ManifestService(fileService: fileService)
        skillStore = SkillStore(fileService: fileService, baseDir: tempDir + "/skills")
        migration = StoreMigrationService(fileService: fileService, manifestService: manifest, skillStore: skillStore)
        rebuildService = StoreRebuildService(fileService: fileService, manifestService: manifest)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func writeRawFile(dir: String, content: String) throws {
        try fileService.writeFile(at: tempDir + "/skills/\(dir)/SKILL.md", content: content)
    }

    private func makeSwiftCategory() -> PensieveCategory {
        let category = PensieveCategory(name: "Swift")
        category.skillSlugs = ["swift-style"]
        category.projectKeys = ["git:github.com/me/app"]
        return category
    }

    private func assertSameCreatedAt(_ actual: Skill, _ expected: Skill) {
        XCTAssertEqual(actual.createdAt.timeIntervalSince1970, expected.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    @MainActor
    func testFabricatedStoreSurvivesMigrateThenRebuild() throws {
        // 1) Fabricate a store in a SEED context: an AUTHORED skill and a legacy IMPORTED skill, each with
        //    a body-only SKILL.md on disk (the pre-migration state), plus a category.
        let seed = try makeContext()

        let authored = Skill(name: "Swift Style", skillDescription: "Swift style rules",
                             tags: ["swift", "review"], scope: .user,
                             directoryName: "swift-style", cursorConfig: nil, importedFrom: nil)
        seed.insert(authored)
        try writeRawFile(dir: "swift-style", content: "# Swift Style\nUse two-space indentation.")

        let imported = Skill(name: "Humanizer", skillDescription: "Removes AI slop",
                             tags: ["writing"], scope: .project,
                             directoryName: "humanizer", cursorConfig: nil, importedFrom: "claude-code")
        seed.insert(imported)
        try writeRawFile(dir: "humanizer", content: "# Humanizer\nStrip the AI tells.")

        seed.insert(makeSwiftCategory())

        // 2) Migrate: normalizes each SKILL.md to canonical frontmatter+body and writes the baseline
        //    manifest overlay (skills + category) from SwiftData.
        let migrated = migration.migrateIfNeeded(fromRoot: tempDir, context: seed)
        XCTAssertEqual(migrated.skillsMigrated, 2)
        XCTAssertTrue(migrated.manifestWritten)
        XCTAssertTrue(migrated.warnings.isEmpty)

        // 3) Rebuild into a FRESH context from disk + manifest alone — the store must be self-sufficient.
        let fresh = try makeContext()
        let result = rebuildService.rebuild(fromRoot: tempDir, context: fresh)
        XCTAssertEqual(result.skillsInserted, 2)
        XCTAssertEqual(result.categoriesInserted, 1)
        XCTAssertEqual(result.skillsUpdated, 0)
        XCTAssertEqual(result.skillsRemoved, 0)
        XCTAssertTrue(result.warnings.isEmpty)

        // 4) No metadata loss — name / description / scope / tags / origin / created_at all survive.
        let rebuiltSkills = try fresh.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(rebuiltSkills.count, 2)

        let swift = try XCTUnwrap(rebuiltSkills.first { $0.directoryName == "swift-style" })
        XCTAssertEqual(swift.name, "Swift Style")
        XCTAssertEqual(swift.skillDescription, "Swift style rules")
        XCTAssertEqual(swift.scope, .user)
        XCTAssertEqual(swift.tags, ["review", "swift"])   // overlay lists round-trip sorted
        XCTAssertNil(swift.importedFrom)                  // origin: authored
        assertSameCreatedAt(swift, authored)

        let human = try XCTUnwrap(rebuiltSkills.first { $0.directoryName == "humanizer" })
        XCTAssertEqual(human.name, "Humanizer")
        XCTAssertEqual(human.skillDescription, "Removes AI slop")
        XCTAssertEqual(human.scope, .project)
        XCTAssertEqual(human.tags, ["writing"])
        XCTAssertEqual(human.importedFrom, "claude-code")   // origin: imported
        assertSameCreatedAt(human, imported)

        // The skill files on disk are now canonical (self-describing) — required frontmatter present.
        let swiftRaw = try fileService.readFile(at: tempDir + "/skills/swift-style/SKILL.md")
        XCTAssertTrue(SkillParser.parse(swiftRaw).hasRequiredFrontmatter)

        // 5) The category materialized with its membership intact.
        let rebuiltCategories = try fresh.fetch(FetchDescriptor<PensieveCategory>())
        XCTAssertEqual(rebuiltCategories.count, 1)
        let swiftCat = try XCTUnwrap(rebuiltCategories.first)
        XCTAssertEqual(swiftCat.name, "Swift")
        XCTAssertEqual(swiftCat.skillSlugs, ["swift-style"])
        XCTAssertEqual(swiftCat.projectKeys, ["git:github.com/me/app"])

        // 6) A second rebuild over the already-converged store is an all-zero no-op (idempotence).
        let second = rebuildService.rebuild(fromRoot: tempDir, context: fresh)
        XCTAssertEqual(second, RebuildResult())
    }
}
