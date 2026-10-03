import SwiftData
import XCTest
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

/// Wraps a real `FileService`, optionally throwing for one `readFile` path and/or one `listDirectory`
/// path — models transient I/O on a present file or an existing directory.
private struct FaultyFileService: FileServiceProtocol {
    struct Boom: Error {}
    let wrapped: FileService
    var failReadPath: String?
    var failListPath: String?

    func readFile(at path: String) throws -> String {
        if path == failReadPath { throw Boom() }
        return try wrapped.readFile(at: path)
    }
    func writeFile(at path: String, content: String) throws { try wrapped.writeFile(at: path, content: content) }
    func deleteFile(at path: String) throws { try wrapped.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { wrapped.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { wrapped.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { wrapped.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try wrapped.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try wrapped.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try wrapped.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try wrapped.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func listDirectory(at path: String) throws -> [String] {
        if path == failListPath { throw Boom() }
        return try wrapped.listDirectory(at: path)
    }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
}

final class StoreRebuildServiceTests: XCTestCase {
    var tempDir: String!
    var fileService: FileService!
    var manifest: ManifestService!
    var service: StoreRebuildService!

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveRebuildTests-\(UUID().uuidString)"
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
    func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func writeSkillFile(slug: String, name: String, description: String, body: String = "# Body") throws {
        let content = SkillSerializer.serialize(name: name, description: description, body: body)
        try fileService.writeFile(at: tempDir + "/skills/\(slug)/SKILL.md", content: content)
    }

    private func writeRawSkillFile(slug: String, content: String) throws {
        try fileService.writeFile(at: tempDir + "/skills/\(slug)/SKILL.md", content: content)
    }

    func writeManifest(skills: [SkillOverlay] = [],
                       categories: [CategoryRecord] = [],
                       projects: [ProjectIdentityRecord] = []) throws {
        let snapshot = ManifestSnapshot(
            schemaVersion: 1,
            categories: categories,

            projects: projects,
            skills: skills
        )
        try manifest.write(snapshot, toRoot: tempDir)
    }

    func overlay(_ slug: String, scope: SkillScope = .user, tags: [String] = [],
                 origin: SkillOrigin = .authored,
                 createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> SkillOverlay {
        SkillOverlay(slug: slug, createdAt: createdAt, scope: scope, tags: tags,
                     cursor: nil, agents: [], origin: origin)
    }

    // MARK: - Bootstrap + idempotence

    @MainActor
    func testBootstrapInsertsSkillsAndCategories() throws {
        let context = try makeContext()
        try writeSkillFile(slug: "swift-style", name: "Swift Style", description: "Swift rules")
        try writeSkillFile(slug: "humanizer", name: "Humanizer", description: "Removes AI slop")
        try writeManifest(
            skills: [overlay("swift-style", scope: .user, tags: ["swift", "review"],
                             origin: .imported(from: "claude-code")),
                     overlay("humanizer", scope: .project, tags: [])],
            categories: [CategoryRecord(name: "Swift", projectKeys: ["git:github.com/me/app"],
                                        skillSlugs: ["swift-style"])]
        )

        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertEqual(result.skillsInserted, 2)
        XCTAssertEqual(result.categoriesInserted, 1)
        XCTAssertEqual(result.skillsUpdated, 0)
        XCTAssertEqual(result.skillsRemoved, 0)
        XCTAssertTrue(result.warnings.isEmpty)

        let skills = try context.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(skills.count, 2)
        let swift = try XCTUnwrap(skills.first { $0.directoryName == "swift-style" })
        XCTAssertEqual(swift.name, "Swift Style")
        XCTAssertEqual(swift.skillDescription, "Swift rules")
        XCTAssertEqual(swift.scope, .user)
        XCTAssertEqual(swift.tags, ["review", "swift"])   // overlay lists come back sorted from disk
        XCTAssertEqual(swift.importedFrom, "claude-code")
        XCTAssertEqual(swift.createdAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.5)

        let categories = try context.fetch(FetchDescriptor<PensieveCategory>())
        XCTAssertEqual(categories.count, 1)
        XCTAssertEqual(categories.first?.skillSlugs, ["swift-style"])
        XCTAssertEqual(categories.first?.projectKeys, ["git:github.com/me/app"])
    }

    @MainActor
    func testSecondRebuildIsIdempotentAllZero() throws {
        let context = try makeContext()
        try writeSkillFile(slug: "swift-style", name: "Swift Style", description: "Swift rules")
        try writeManifest(skills: [overlay("swift-style", tags: ["swift"])],
                          categories: [CategoryRecord(name: "Swift", projectKeys: [], skillSlugs: ["swift-style"])])
        _ = service.rebuild(fromRoot: tempDir, context: context)

        let second = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(second, RebuildResult())   // all-zero counts, no warnings, no mutation
    }

    // MARK: - Upstream add / delete

    @MainActor
    func testUpstreamAddInsertsNewSkill() throws {
        let context = try makeContext()
        try writeSkillFile(slug: "swift-style", name: "Swift Style", description: "Swift rules")
        try writeManifest(skills: [overlay("swift-style")])
        _ = service.rebuild(fromRoot: tempDir, context: context)

        try writeSkillFile(slug: "humanizer", name: "Humanizer", description: "Removes AI slop")
        try writeManifest(skills: [overlay("swift-style"), overlay("humanizer")])

        let result = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsInserted, 1)
        XCTAssertEqual(result.skillsUpdated, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).count, 2)
    }

    @MainActor
    func testUpstreamDeleteRemovesOrphanedSkill() throws {
        let context = try makeContext()
        try writeSkillFile(slug: "swift-style", name: "Swift Style", description: "Swift rules")
        try writeSkillFile(slug: "humanizer", name: "Humanizer", description: "Removes AI slop")
        try writeManifest(skills: [overlay("swift-style"), overlay("humanizer")])
        _ = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).count, 2)

        try FileManager.default.removeItem(atPath: tempDir + "/skills/humanizer")
        try writeManifest(skills: [overlay("swift-style")])

        let result = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsRemoved, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).map { $0.directoryName }, ["swift-style"])
    }

    @MainActor
    func testMetadataChangeUpdatesOverlayFields() throws {
        let context = try makeContext()
        try writeSkillFile(slug: "swift-style", name: "Swift Style", description: "Swift rules")
        try writeManifest(skills: [overlay("swift-style", scope: .user, tags: ["swift"])])
        _ = service.rebuild(fromRoot: tempDir, context: context)

        try writeManifest(skills: [overlay("swift-style", scope: .project, tags: ["review", "swift"])])
        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertEqual(result.skillsUpdated, 1)
        XCTAssertEqual(result.skillsInserted, 0)
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(skill.scope, .project)
        XCTAssertEqual(skill.tags, ["review", "swift"])
    }

    // MARK: - Required-frontmatter admission

    @MainActor
    func testBodyOnlyFileIsSkippedWithWarning() throws {
        let context = try makeContext()
        try writeRawSkillFile(slug: "bodyonly", content: "# Just a body\nNo frontmatter here.")
        try writeManifest(skills: [])

        let result = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsInserted, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("bodyonly") })
    }

    @MainActor
    func testNoDescriptionFileIsSkippedWithWarning() throws {
        let context = try makeContext()
        try writeRawSkillFile(slug: "nodesc", content: "---\nname: No Desc\n---\n\n# Body")
        try writeManifest(skills: [])

        let result = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsInserted, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("nodesc") })
    }

    @MainActor
    func testMalformedYAMLFileIsSkippedWithWarning() throws {
        let context = try makeContext()
        // Unclosed flow sequence -> Yams throws -> parser falls back to all-body -> not admitted.
        try writeRawSkillFile(slug: "broken", content: "---\nname: [unclosed\ndescription: x\n---\n\n# Body")
        try writeManifest(skills: [])

        let result = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsInserted, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("broken") })
    }

    @MainActor
    func testNameEqualsDescriptionIsAdmitted() throws {
        let context = try makeContext()
        // The 07.2 create/import fallback: description == name. Both non-empty -> admitted.
        try writeSkillFile(slug: "minimal", name: "Minimal", description: "Minimal")
        try writeManifest(skills: [overlay("minimal")])

        let result = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsInserted, 1)
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(skill.name, "Minimal")
        XCTAssertEqual(skill.skillDescription, "Minimal")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    @MainActor
    func testOverlayWithoutFilesEmitsWarning() throws {
        let context = try makeContext()
        // Manifest lists 'ghost' but there is no skills/ghost/SKILL.md (corruption signal).
        try writeManifest(skills: [overlay("ghost")])

        let result = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsInserted, 0)
        XCTAssertTrue(result.warnings.contains { $0.contains("ghost") })
    }

    // MARK: - No phantom projects; category delete

    @MainActor
    func testProjectsAreNotMaterialized() throws {
        let context = try makeContext()
        try writeSkillFile(slug: "swift-style", name: "Swift Style", description: "Swift rules")
        try writeManifest(
            skills: [overlay("swift-style")],
            categories: [CategoryRecord(name: "Swift", projectKeys: ["git:github.com/me/app"],
                                        skillSlugs: ["swift-style"])],
            projects: [ProjectIdentityRecord(identityKey: "git:github.com/me/app", identityKind: "remote", name: "App")]
        )

        let result = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.categoriesInserted, 1)
        // No path-less phantom Project rows are invented: projects are registered locally.
        XCTAssertTrue(try context.fetch(FetchDescriptor<Project>()).isEmpty)
    }

    @MainActor
    func testCategoryRemovedWhenAbsentFromManifest() throws {
        let context = try makeContext()
        try writeManifest(categories: [
            CategoryRecord(name: "Swift", projectKeys: [], skillSlugs: []),
            CategoryRecord(name: "Docs", projectKeys: [], skillSlugs: [])
        ])
        _ = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PensieveCategory>()).count, 2)

        try writeManifest(categories: [CategoryRecord(name: "Swift", projectKeys: [], skillSlugs: [])])
        let result = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.categoriesRemoved, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PensieveCategory>()).map { $0.name }, ["Swift"])
    }

    // MARK: - 07.4 review regressions (safe degradation)

    @MainActor
    func testUnreadableManifestPreservesLocalStateAndWarns() throws {
        // 07.4 review, BLOCKING #2: a newer-schema (unreadable) manifest must NOT drive a destructive
        // reconcile. An empty-snapshot rebuild would reset overlay-backed fields + delete every
        // category. The service must bail, warn, and mutate nothing.
        let context = try makeContext()
        try writeSkillFile(slug: "swift-style", name: "Swift Style", description: "Swift rules")
        try writeManifest(skills: [overlay("swift-style", scope: .project, tags: ["swift"])],
                          categories: [CategoryRecord(name: "Swift", projectKeys: [], skillSlugs: ["swift-style"])])
        _ = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PensieveCategory>()).count, 1)

        try fileService.writeFile(at: tempDir + "/manifest/manifest.yaml", content: "schema_version: 999\n")
        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertEqual(result.skillsInserted, 0)
        XCTAssertEqual(result.skillsUpdated, 0)
        XCTAssertEqual(result.skillsRemoved, 0)
        XCTAssertEqual(result.categoriesInserted, 0)
        XCTAssertEqual(result.categoriesUpdated, 0)
        XCTAssertEqual(result.categoriesRemoved, 0)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(result.storeUnreadable, "a newer/unreadable-schema bail must flag storeUnreadable")
        XCTAssertEqual(try context.fetch(FetchDescriptor<PensieveCategory>()).count, 1)
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(skill.scope, .project)        // overlay-backed field NOT reset to .user
        XCTAssertEqual(skill.tags, ["swift"])        // NOT reset to []
    }

    @MainActor
    func testPresentButUnreadableSkillFileIsNotDeleted() throws {
        let context = try makeContext()
        try writeSkillFile(slug: "swift-style", name: "Swift Style", description: "Swift rules")
        try writeManifest(skills: [overlay("swift-style", tags: ["swift"])])
        _ = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).count, 1)

        let unreadable = FaultyFileService(wrapped: fileService,
                                           failReadPath: tempDir + "/skills/swift-style/SKILL.md")
        let guardedService = StoreRebuildService(fileService: unreadable,
                                                 manifestService: ManifestService(fileService: unreadable))
        let result = guardedService.rebuild(fromRoot: tempDir, context: context)

        XCTAssertEqual(result.skillsRemoved, 0)      // NOT deleted on a read failure
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).count, 1)   // row preserved
        XCTAssertTrue(result.warnings.contains { $0.contains("could not be read") })
    }
}
extension StoreRebuildServiceTests {
    @MainActor
    func testRebuildDropsOrphanRowWhenManifestListsNoSkills() throws {
        let context = try makeContext()
        context.insert(Skill(name: "Orphan", skillDescription: "d", directoryName: "orphan"))
        try context.save()
        try writeManifest(skills: [])
        let result = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsRemoved, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
        XCTAssertEqual(result.skillsInserted, 0)
    }
    @MainActor
    func testCorruptCategoryFileBailsWithoutDeleting() throws {
        let context = try makeContext()
        try writeManifest(categories: [CategoryRecord(name: "Swift", projectKeys: [], skillSlugs: [])])
        _ = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PensieveCategory>()).count, 1)
        let categoryDir = tempDir + "/manifest/categories"
        let categoryFile = try XCTUnwrap(try fileService.listDirectory(at: categoryDir).first { $0.hasSuffix(".yaml") })
        try fileService.writeFile(at: categoryDir + "/" + categoryFile, content: ":\n  - [\n")
        let result = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertTrue(result.storeUnreadable)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PensieveCategory>()).count, 1)
    }
    @MainActor
    func testSkillsListingFailureDoesNotDeleteRows() throws {
        let context = try makeContext()
        try writeSkillFile(slug: "swift-style", name: "Swift Style", description: "Swift rules")
        try writeManifest(skills: [overlay("swift-style")])
        _ = service.rebuild(fromRoot: tempDir, context: context)
        let failing = FaultyFileService(wrapped: fileService, failListPath: tempDir + "/skills")
        let guarded = StoreRebuildService(fileService: failing, manifestService: ManifestService(fileService: failing))
        let result = guarded.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsRemoved, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).map { $0.directoryName }, ["swift-style"])
        XCTAssertTrue(result.warnings.contains { $0.contains("Couldn't list the skills directory") })
    }
    @MainActor
    func testCategoriesListingFailureBailsWithoutDeleting() throws {
        let context = try makeContext()
        try writeManifest(categories: [CategoryRecord(name: "Swift", projectKeys: [], skillSlugs: [])])
        _ = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PensieveCategory>()).count, 1)
        let failing = FaultyFileService(wrapped: fileService, failListPath: tempDir + "/manifest/categories")
        let guarded = StoreRebuildService(fileService: failing, manifestService: ManifestService(fileService: failing))
        let result = guarded.rebuild(fromRoot: tempDir, context: context)
        XCTAssertTrue(result.storeUnreadable)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PensieveCategory>()).count, 1)
    }
}
