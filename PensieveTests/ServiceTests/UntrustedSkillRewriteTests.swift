import SwiftData
import XCTest
@testable import Pensieve

final class UntrustedSkillRewriteTests: XCTestCase {
    private var root: String!
    private var files: ImportReadSpy!

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "UntrustedSkillRewrite-" + UUID().uuidString
        files = ImportReadSpy(files: FileService())
        try files.createDirectory(at: root)
    }

    override func tearDownWithError() throws {
        try files.deleteDirectory(at: root)
    }

    @MainActor
    private func context() throws -> ModelContext {
        ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private var store: SkillStore { SkillStore(fileService: files, baseDir: root + "/store/skills") }

    @MainActor
    func testGeneratedMigrationSweepPreservesRefusedFilesAndWarns() throws {
        let context = try context()
        let fixtures = FrontmatterRewriteFixture.sweep
        for (index, fixture) in fixtures.enumerated() {
            let slug = "case-\(index)"
            let skill = Skill(name: "New", skillDescription: "New description", directoryName: slug)
            context.insert(skill)
            try files.writeFile(at: root + "/store/skills/\(slug)/SKILL.md", content: fixture.source)
        }
        files.writtenPaths = []
        let result = StoreMigrationService(
            fileService: files, manifestService: ManifestService(fileService: files), skillStore: store
        ).migrateIfNeeded(fromRoot: root + "/store", context: context)
        for (index, fixture) in fixtures.enumerated() {
            let slug = "case-\(index)"
            let path = root + "/store/skills/\(slug)/SKILL.md"
            let expected: String
            if fixture.trustsEntries {
                expected = fixture.source.replacingOccurrences(of: "name: A", with: "name: New")
                    .replacingOccurrences(of: "description: D", with: "description: New description")
            } else if fixture.header != nil {
                expected = fixture.source
                XCTAssertFalse(files.writtenPaths.contains(path), fixture.label)
                XCTAssertTrue(result.warnings.contains { $0.contains("'\(slug)'") && $0.contains("not normalized") },
                              fixture.label)
            } else {
                let ending = fixture.lineEnding == "\r\n" ? "\r\n" : "\n"
                expected = "---\(ending)name: New\(ending)description: New description\(ending)---"
                    + ending + ending + fixture.source
            }
            XCTAssertEqual(try files.files.readData(at: path), Data(expected.utf8), fixture.label)
        }
    }

    @MainActor
    func testGeneratedImportSweepNormalizesSafeValuesAndKeepsFallbackSource() throws {
        for (index, fixture) in FrontmatterRewriteFixture.sweep.enumerated() {
            let scanner = ImportScanner(
                fileService: files, claudeSkillsDir: root + "/claude", grokSkillsDir: root + "/grok",
                cursorRulesDir: root + "/cursor", codexSkillsDir: root + "/codex", storeRoot: root + "/store"
            )
            let model = ImportViewModel(scanner: scanner, skillStore: store, manifestRoot: root + "/store")
            let context = try context()
            let folder = root + "/source-\(index)"
            try files.writeFile(at: folder + "/SKILL.md", content: fixture.source)
            XCTAssertEqual(model.scanFolder(folder), .found(1), fixture.label)
            // Exercise a real identity change after discovery; both callers use the shared validation.
            let discovered = try XCTUnwrap(model.discoveredSkills.first)
            model.discoveredSkills = [DiscoveredSkill(
                name: "New", body: discovered.body, sourcePlatform: discovered.sourcePlatform,
                sourcePath: discovered.sourcePath, skillDescription: "New description", sourceContent: discovered.sourceContent
            )]
            model.importSelected(context: context)
            XCTAssertNil(model.error, fixture.label)
            let row = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
            let path = root + "/store/skills/\(row.directoryName)/SKILL.md"
            let expected = fixture.trustsEntries
                ? fixture.source.replacingOccurrences(of: "name: A", with: "name: New")
                    .replacingOccurrences(of: "description: D", with: "description: New description")
                : "---\nname: New\ndescription: New description\n---\n\n" + fixture.source
            XCTAssertEqual(try files.files.readData(at: path), Data(expected.utf8), fixture.label)
            let keptFrontmatter = !fixture.trustsEntries && ["\n", "\r\n"].contains(fixture.lineEnding)
            XCTAssertEqual(model.importNotices, keptFrontmatter ? ["New: frontmatter was kept as text."] : [], fixture.label)
        }
    }

    @MainActor
    func testEmbeddedFenceImportKeepsAllSourceBytesAndMigrationRefusesWrites() throws {
        let context = try context()
        var originals: [String: String] = [:]
        for (index, value) in ["description: before---after", "description: '---'",
                               "description: |\n  ---\n  text", "description: D\n# --- comment"].enumerated() {
            for ending in ["\n", "\r\n"] {
                let source = "---\nname: A\n\(value)\nlicense: MIT\n---\nBody\n"
                    .replacingOccurrences(of: "\n", with: ending)
                let slug = "embedded-\(index)-" + (ending == "\r\n" ? "crlf" : "lf")
                let path = root + "/store/skills/\(slug)/SKILL.md"
                originals[path] = source
                let skill = Skill(name: "New", skillDescription: "New description", directoryName: slug)
                context.insert(skill)
                try files.writeFile(at: path, content: source)
                let scanner = ImportScanner(fileService: files, storeRoot: root + "/store")
                let model = ImportViewModel(scanner: scanner, skillStore: store, manifestRoot: root + "/store")
                model.discoveredSkills = [DiscoveredSkill(name: "New", body: SkillParser.stripFrontmatter(source),
                    sourcePlatform: "Claude Code", sourcePath: path, skillDescription: "New description", sourceContent: source)]
                model.selectedSkills = [path]
                let beforeIDs = Set(try context.fetch(FetchDescriptor<Skill>()).map(\.id))
                model.importSelected(context: context)
                XCTAssertNil(model.error)
                let imported = try context.fetch(FetchDescriptor<Skill>()).first { !beforeIDs.contains($0.id) }
                let importedSlug = try XCTUnwrap(imported).directoryName
                XCTAssertEqual(try files.files.readData(at: root + "/store/skills/\(importedSlug)/SKILL.md"),
                               Data(("---\nname: New\ndescription: New description\n---\n\n" + source).utf8))
            }
        }
        files.writtenPaths = []
        let result = StoreMigrationService(fileService: files, manifestService: ManifestService(fileService: files),
                                           skillStore: store).migrateIfNeeded(fromRoot: root + "/store", context: context)
        for skill in try context.fetch(FetchDescriptor<Skill>()) where skill.directoryName.hasPrefix("embedded-") {
            let path = root + "/store/skills/\(skill.directoryName)/SKILL.md"
            XCTAssertEqual(try files.files.readData(at: path), Data(try XCTUnwrap(originals[path]).utf8))
            XCTAssertFalse(files.writtenPaths.contains(path))
            XCTAssertTrue(result.warnings.contains { $0.contains("'\(skill.directoryName)'") && $0.contains("not normalized") })
        }
    }

    @MainActor
    func testGeneratedBodySavesKeepFrontmatterAndExactEditedBytes() throws {
        let model = SkillLibraryViewModel(skillStore: store, fileService: files, manifestRoot: root + "/store")
        let edited = "First\nSecond\r\nThird\rFourth\u{85}Fifth\u{2028}Sixth\u{2029}Last"
        for (index, fixture) in FrontmatterRewriteFixture.sweep.enumerated() {
            let slug = "case-\(index)"
            let path = root + "/store/skills/\(slug)/SKILL.md"
            let skill = Skill(name: "A", skillDescription: "D", directoryName: slug)
            try files.writeFile(at: path, content: fixture.source)
            let ending = fixture.lineEnding == "\r\n" ? "\r\n" : "\n"
            let expectedBody = ["First", "Second", "Third", "Fourth\u{85}Fifth\u{2028}Sixth\u{2029}Last"]
                .joined(separator: ending)
            let header = fixture.header ?? "---\(ending)name: A\(ending)description: D\(ending)---" + ending + ending
            let expected = header + expectedBody + fixture.terminal
            for draft in [edited, edited + "\n", edited + "\r\n\r\n"] {
                XCTAssertTrue(model.updateBody(skill, body: draft).succeeded, fixture.label)
                XCTAssertEqual(try files.files.readData(at: path), Data(expected.utf8), fixture.label)
            }
        }
    }
}
