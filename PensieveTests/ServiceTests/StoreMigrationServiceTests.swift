import SwiftData
import XCTest
import Yams
@testable import Pensieve

final class StoreMigrationServiceTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var manifest: ManifestService!
    private var skillStore: SkillStore!
    private var service: StoreMigrationService!

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveMigrationTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        manifest = ManifestService(fileService: fileService)
        skillStore = SkillStore(fileService: fileService, baseDir: tempDir + "/skills")
        service = StoreMigrationService(fileService: fileService, manifestService: manifest, skillStore: skillStore)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
    }

    @MainActor
    @discardableResult
    private func seedSkill(_ context: ModelContext, name: String, description: String = "",
                           dir: String, importedFrom: String? = nil, tags: [String] = [],
                           scope: SkillScope = .user, cursor: CursorAdapterConfig? = nil) -> Skill {
        let skill = Skill(name: name, skillDescription: description, tags: tags, scope: scope,
                          directoryName: dir, cursorConfig: cursor, importedFrom: importedFrom)
        context.insert(skill)
        return skill
    }

    private func writeRawFile(dir: String, content: String) throws {
        try fileService.writeFile(at: tempDir + "/skills/\(dir)/SKILL.md", content: content)
    }

    private func readFile(dir: String) throws -> String {
        try fileService.readFile(at: tempDir + "/skills/\(dir)/SKILL.md")
    }

    // MARK: - Backfill correctness

    @MainActor
    func testMigrationWritePreservesProjectIntent() throws {
        let context = try makeContext()
        context.insert(MachineDeployIntent(
            machineID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
            skillSlug: "durable-intent",
            platformRaw: "codex",
            projectKey: "github.com/owner/project"
        ))
        try context.save()

        let result = service.migrateIfNeeded(fromRoot: tempDir, context: context)

        XCTAssertTrue(result.manifestWritten)
        XCTAssertEqual(try manifest.read(fromRoot: tempDir).deployIntents.first?.projectKey,
                       "github.com/owner/project")
    }

    @MainActor
    func testBodyOnlySkillGainsFrontmatterFromSwiftData() throws {
        let context = try makeContext()
        seedSkill(context, name: "My Skill", description: "A description", dir: "my-skill")
        try writeRawFile(dir: "my-skill", content: "# Just a body\nNo frontmatter.")

        let result = service.migrateIfNeeded(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsMigrated, 1)

        let parsed = SkillParser.parse(try readFile(dir: "my-skill"))
        XCTAssertTrue(parsed.hasRequiredFrontmatter)
        XCTAssertEqual(parsed.name, "My Skill")
        XCTAssertEqual(parsed.description, "A description")
    }

    @MainActor
    func testImportedDescriptionFromFileNotOverwrittenByEmptySwiftData() throws {
        let context = try makeContext()
        // Legacy import: SwiftData description is EMPTY; the real description lives in the file frontmatter.
        let skill = seedSkill(context, name: "Humanizer", description: "", dir: "humanizer",
                              importedFrom: "claude-code")
        try writeRawFile(dir: "humanizer",
                         content: SkillSerializer.serialize(name: "Humanizer",
                                                            description: "Removes AI slop", body: "# H"))

        let result = service.migrateIfNeeded(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsMigrated, 1)
        // The file description is preserved AND backfilled onto the row (NOT clobbered by the empty field).
        XCTAssertEqual(skill.skillDescription, "Removes AI slop")
        XCTAssertEqual(SkillParser.parse(try readFile(dir: "humanizer")).description, "Removes AI slop")
    }

    @MainActor
    func testImportedNameDiffersAdoptsFrontmatterName() throws {
        let context = try makeContext()
        // Legacy import: SwiftData name is the DIRECTORY entry; the frontmatter name is authoritative.
        let skill = seedSkill(context, name: "humanizer", description: "d", dir: "humanizer",
                              importedFrom: "claude-code")
        try writeRawFile(dir: "humanizer",
                         content: SkillSerializer.serialize(name: "Humanizer Pro", description: "d", body: "# H"))

        _ = service.migrateIfNeeded(fromRoot: tempDir, context: context)
        XCTAssertEqual(skill.name, "Humanizer Pro")   // adopted the frontmatter name, row backfilled
    }

    @MainActor
    func testAuthoredNamePrefersSwiftData() throws {
        let context = try makeContext()
        // Authored (importedFrom == nil): the user's SwiftData name wins over a stale file name.
        let skill = seedSkill(context, name: "User Chosen", description: "d", dir: "user-chosen")
        try writeRawFile(dir: "user-chosen",
                         content: SkillSerializer.serialize(name: "Stale File Name", description: "d", body: "# B"))

        _ = service.migrateIfNeeded(fromRoot: tempDir, context: context)
        XCTAssertEqual(skill.name, "User Chosen")
        XCTAssertEqual(SkillParser.parse(try readFile(dir: "user-chosen")).name, "User Chosen")
    }

    // MARK: - Non-empty invariant survives rebuild

    @MainActor
    func testLegacyNoDescriptionGetsNameAndSurvivesRebuild() throws {
        let context = try makeContext()
        // No description anywhere: SwiftData empty, file body-only.
        seedSkill(context, name: "Orphan", description: "", dir: "orphan")
        try writeRawFile(dir: "orphan", content: "# Body only")

        _ = service.migrateIfNeeded(fromRoot: tempDir, context: context)
        let parsed = SkillParser.parse(try readFile(dir: "orphan"))
        XCTAssertEqual(parsed.description, "Orphan")   // description == name fallback
        XCTAssertTrue(parsed.hasRequiredFrontmatter)

        // The description==name skill must be ADMITTED on a fresh-machine rebuild (the non-empty invariant).
        let fresh = try makeContext()
        let rebuild = StoreRebuildService(fileService: fileService, manifestService: manifest)
            .rebuild(fromRoot: tempDir, context: fresh)
        XCTAssertEqual(rebuild.skillsInserted, 1)
        let rebuilt = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(rebuilt.name, "Orphan")
        XCTAssertEqual(rebuilt.skillDescription, "Orphan")
    }

    // MARK: - Overlay + idempotence + round-trip

    @MainActor
    func testOverlayWrittenFromSwiftData() throws {
        let context = try makeContext()
        seedSkill(context, name: "Swift Style", description: "Swift rules", dir: "swift-style",
                  importedFrom: "cursor", tags: ["swift", "review"], scope: .project,
                  cursor: CursorAdapterConfig(description: "Swift rules", globs: ["**/*.swift"], alwaysApply: false))
        try writeRawFile(dir: "swift-style",
                         content: SkillSerializer.serialize(name: "Swift Style", description: "Swift rules", body: "# S"))

        let result = service.migrateIfNeeded(fromRoot: tempDir, context: context)
        XCTAssertTrue(result.manifestWritten)

        let overlay = try XCTUnwrap(try manifest.read(fromRoot: tempDir).skills.first { $0.slug == "swift-style" })
        XCTAssertEqual(overlay.tags, ["review", "swift"])
        XCTAssertEqual(overlay.scope, .project)
        XCTAssertEqual(overlay.origin, .imported(from: "cursor"))
        XCTAssertEqual(overlay.cursor?.description, "Swift rules")
    }

    @MainActor
    func testSecondRunIsNoOp() throws {
        let context = try makeContext()
        seedSkill(context, name: "Idempotent", description: "d", dir: "idempotent")
        try writeRawFile(dir: "idempotent", content: "# Body")
        _ = service.migrateIfNeeded(fromRoot: tempDir, context: context)

        let second = service.migrateIfNeeded(fromRoot: tempDir, context: context)
        XCTAssertEqual(second.skillsMigrated, 0)   // already canonical + already backfilled
    }

    @MainActor
    func testMigrationNormalizesIdentityAndPreservesEveryOtherEntryAndInterKeyComment() throws {
        let context = try makeContext()
        seedSkill(context, name: "Correct Name", description: "Correct description", dir: "preserved")
        let original = """
        ---
        license: Apache-2.0
        name: Stale Name
        description: Stale description
        # This documents allowed-tools below.
          # This indented comment also documents allowed-tools.
        allowed-tools:
          - Read
        metadata:
          owner: upstream
        ---

        Body
        """ + "\n"
        try writeRawFile(dir: "preserved", content: original)

        let first = service.migrateIfNeeded(fromRoot: tempDir, context: context)
        let rewritten = try readFile(dir: "preserved")
        XCTAssertEqual(first.skillsMigrated, 1)
        XCTAssertEqual(
            rewritten,
            original
                .replacingOccurrences(of: "name: Stale Name", with: "name: Correct Name")
                .replacingOccurrences(of: "description: Stale description", with: "description: Correct description")
        )
        XCTAssertTrue(rewritten.contains("# This documents allowed-tools below."))
        XCTAssertTrue(rewritten.contains("  # This indented comment also documents allowed-tools.\nallowed-tools:"))

        let second = service.migrateIfNeeded(fromRoot: tempDir, context: context)
        XCTAssertEqual(second.skillsMigrated, 0)
        XCTAssertEqual(try readFile(dir: "preserved"), rewritten)
    }

    @MainActor
    func testMigrationLeavesUntrustworthyFrontmatterUnchangedAndWarns() throws {
        let context = try makeContext()
        seedSkill(context, name: "Correct", description: "Correct description", dir: "flow")
        let original = "---\n{name: Stale, description: Old, license: MIT}\n---\nBody\n"
        try writeRawFile(dir: "flow", content: original)

        let result = service.migrateIfNeeded(fromRoot: tempDir, context: context)

        XCTAssertEqual(try readFile(dir: "flow"), original)
        XCTAssertTrue(result.warnings.contains { $0.contains("flow") && $0.contains("could not be split safely") })
    }

    @MainActor
    func testMigrationDoesNotWarnWhenUntrustworthyIdentityAlreadyMatches() throws {
        let context = try makeContext()
        seedSkill(context, name: "Match", description: "Already correct", dir: "flow-match")
        let original = "---\n{name: Match, description: Already correct, license: MIT}\n---\nBody\n"
        try writeRawFile(dir: "flow-match", content: original)

        let result = service.migrateIfNeeded(fromRoot: tempDir, context: context)

        XCTAssertEqual(result.skillsMigrated, 0)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(try readFile(dir: "flow-match"), original)
    }
}

extension StoreMigrationServiceTests {
    @MainActor
    func testMigrationLeavesUnparseableFrontmatterUnchangedAndWarns() throws {
        let context = try makeContext()
        seedSkill(context, name: "New Name", description: "D", dir: "unparseable")
        let original = "---\nname: &identity.v1 A\ndescription: D\nother: *identity.v1\n---\n\nBody\n"
        try writeRawFile(dir: "unparseable", content: original)
        XCTAssertNil(try? Yams.compose(yaml: "name: &identity.v1 A\ndescription: D\nother: *identity.v1"))

        let result = service.migrateIfNeeded(fromRoot: tempDir, context: context)

        XCTAssertEqual(try readFile(dir: "unparseable"), original)
        XCTAssertTrue(result.warnings.contains {
            $0.contains("unparseable") && $0.contains("could not be split safely")
        })
    }

    @MainActor
    func testMigrateThenRebuildPreservesAllFields() throws {
        let context = try makeContext()
        let original = seedSkill(context, name: "Round Trip", description: "rt desc", dir: "round-trip",
                                 importedFrom: "claude-code", tags: ["a", "b"], scope: .project)
        try writeRawFile(dir: "round-trip", content: "# Body only, gains frontmatter on migrate")

        _ = service.migrateIfNeeded(fromRoot: tempDir, context: context)

        // Rebuild into a FRESH store from disk + manifest alone — the store must be self-sufficient.
        let fresh = try makeContext()
        _ = StoreRebuildService(fileService: fileService, manifestService: manifest)
            .rebuild(fromRoot: tempDir, context: fresh)
        let rebuilt = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Skill>()).first)

        XCTAssertEqual(rebuilt.name, "Round Trip")
        XCTAssertEqual(rebuilt.skillDescription, "rt desc")
        XCTAssertEqual(rebuilt.scope, .project)
        XCTAssertEqual(rebuilt.tags, ["a", "b"])
        XCTAssertEqual(rebuilt.importedFrom, "claude-code")
        XCTAssertEqual(rebuilt.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - 07.5 review regressions

    @MainActor
    func testBodyOnlyWithTrailingNewlineIsIdempotent() throws {
        // 07.5 review, BLOCKING #3: a body-only file ending in "\n" must still be a no-op on the second
        // run. `stripFrontmatter` returns a body-only file verbatim (keeping the "\n") but trims a fenced
        // body, so without the migration's explicit body trim the file re-normalizes forever.
        let context = try makeContext()
        seedSkill(context, name: "Trailing", description: "d", dir: "trailing")
        try writeRawFile(dir: "trailing", content: "# Body\n")   // trailing newline

        let first = service.migrateIfNeeded(fromRoot: tempDir, context: context)
        XCTAssertEqual(first.skillsMigrated, 1)
        let second = service.migrateIfNeeded(fromRoot: tempDir, context: context)
        XCTAssertEqual(second.skillsMigrated, 0)   // stable — no perpetual re-normalize
    }

    @MainActor
    func testMissingSkillFileIsSkippedWithWarningNotFabricated() throws {
        // 07.5 review, BLOCKING #1: a skill whose SKILL.md is missing/unreadable must be skipped with a
        // warning — NOT fabricated into an empty-body canonical file (which would destroy real bytes and
        // clobber a file-only description with the name fallback).
        let context = try makeContext()
        seedSkill(context, name: "No File", description: "real desc", dir: "no-file")
        // Intentionally write NO SKILL.md on disk.

        let result = service.migrateIfNeeded(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsMigrated, 0)
        XCTAssertTrue(result.warnings.contains { $0.contains("no-file") })
        XCTAssertFalse(fileService.fileExists(at: tempDir + "/skills/no-file/SKILL.md"))   // not fabricated
    }

    @MainActor
    func testMigrateSkipsSymlinkedSlugDirWithWarning() throws {
        let context = try makeContext()
        seedSkill(context, name: "Original", description: "orig", dir: "victim")
        let outside = tempDir + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let evil = SkillSerializer.serialize(name: "Evil", description: "pwned", body: "# evil")
        try fileService.writeFile(at: outside + "/SKILL.md", content: evil)
        try FileManager.default.createDirectory(atPath: tempDir + "/skills", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: tempDir + "/skills/victim", withDestinationPath: outside)

        let result = service.migrateIfNeeded(fromRoot: tempDir, context: context)

        XCTAssertTrue(result.warnings.contains { $0.contains("victim") && $0.contains("symlink") })
        let skills = try context.fetch(FetchDescriptor<Skill>())
        let victim = try XCTUnwrap(skills.first { $0.directoryName == "victim" })
        XCTAssertEqual(victim.name, "Original")   // NOT read through to "Evil"
    }

    @MainActor
    func testMigrateSkipsRealpathEscapingSlugDirReturningFalse() throws {
        let context = try makeContext()
        seedSkill(context, name: "Original", description: "orig", dir: "victim")
        // A real sibling slug dir the symlink points at — in-store, but not victim's canonical dir.
        try writeRawFile(dir: "decoy",
                         content: SkillSerializer.serialize(name: "Decoy", description: "d", body: "# d"))
        try FileManager.default.createSymbolicLink(
            atPath: tempDir + "/skills/victim", withDestinationPath: tempDir + "/skills/decoy")

        let result = service.migrateIfNeeded(fromRoot: tempDir, context: context)

        // migrateSkill returned false (skipped) — never threw, so the count stays 0 and it warns.
        XCTAssertEqual(result.skillsMigrated, 0)
        XCTAssertTrue(result.warnings.contains { $0.contains("victim") && $0.contains("symlink") })
        let skills = try context.fetch(FetchDescriptor<Skill>())
        let victim = try XCTUnwrap(skills.first { $0.directoryName == "victim" })
        XCTAssertEqual(victim.name, "Original")   // NOT read through to the sibling "Decoy"
    }
}
