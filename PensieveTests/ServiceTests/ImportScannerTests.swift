import XCTest
@testable import Pensieve

final class ImportScannerTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = (TestTemporaryDirectory.path as NSString)
            .appendingPathComponent("PensieveImportScannerTests-" + UUID().uuidString)
        fileService = FileService()
        try fileService.createDirectory(at: tempDir)
    }

    override func tearDownWithError() throws {
        if fileService.directoryExists(at: tempDir) {
            try fileService.deleteDirectory(at: tempDir)
        }
        fileService = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Grok Scanning

    func testGrokSkillDiscovered() throws {
        let skillsDir = tempDir + "/grok/skills"
        let entryDir = skillsDir + "/directory-entry"
        let skillPath = entryDir + "/SKILL.md"
        try fileService.writeFile(
            at: skillPath,
            content: "---\nname: frontmatter-name\ndescription: Grok fixture\n---\n# Grok body\n"
        )

        let skill = try XCTUnwrap(makeScanner(grokSkillsDir: skillsDir).scan().first)

        XCTAssertEqual(skill.name, "frontmatter-name")
        XCTAssertEqual(skill.body, "# Grok body")
        XCTAssertEqual(skill.sourcePlatform, "grok")
        XCTAssertEqual(skill.sourcePath, skillPath)
        XCTAssertEqual(skill.skillDescription, "Grok fixture")
    }

    func testGrokSkillWithoutFrontmatterDiscovered() throws {
        let skillsDir = tempDir + "/grok/skills"
        let skillPath = skillsDir + "/bare-grok/SKILL.md"
        let content = "# Bare Grok body\n"
        try fileService.writeFile(at: skillPath, content: content)

        let skill = try XCTUnwrap(makeScanner(grokSkillsDir: skillsDir).scan().first)

        XCTAssertEqual(skill.name, "bare-grok")
        XCTAssertEqual(skill.body, content)
        XCTAssertEqual(skill.sourcePlatform, "grok")
        XCTAssertEqual(skill.sourcePath, skillPath)
        XCTAssertNil(skill.skillDescription)
    }

    func testGrokPensieveSymlinkSkipped() throws {
        let skillsDir = tempDir + "/grok/skills"
        let canonicalDir = tempDir + "/.pensieve/skills/deployed-grok"
        try fileService.writeFile(
            at: canonicalDir + "/SKILL.md",
            content: "---\nname: deployed-grok\ndescription: Deployed fixture\n---\nbody\n"
        )
        try fileService.createSymlink(
            at: skillsDir + "/deployed-grok",
            pointingTo: canonicalDir
        )

        XCTAssertTrue(makeScanner(grokSkillsDir: skillsDir).scan().isEmpty)
    }

    func testGrokDirectoryWithoutSkillFileIgnored() throws {
        let skillsDir = tempDir + "/grok/skills"
        try fileService.createDirectory(at: skillsDir + "/not-a-skill")

        XCTAssertTrue(makeScanner(grokSkillsDir: skillsDir).scan().isEmpty)
    }

    func testGrokMissingDirectoryIsQuiet() {
        let missingDir = tempDir + "/missing-grok-skills"

        XCTAssertTrue(makeScanner(grokSkillsDir: missingDir).scan().isEmpty)
    }

    func testCodexSkillDiscoveredAndSystemDirSkipped() throws {
        let skillsDir = tempDir + "/codex/skills"
        let skillPath = skillsDir + "/probe-codex/SKILL.md"
        let systemPath = skillsDir + "/.system/SKILL.md"
        try fileService.writeFile(
            at: skillPath,
            content: "---\nname: probe-codex\ndescription: Codex fixture\n---\n# Body\n"
        )
        try fileService.writeFile(
            at: systemPath,
            content: "---\nname: system\ndescription: System fixture\n---\n# System\n"
        )

        let results = makeScanner(
            grokSkillsDir: tempDir + "/missing-grok-skills",
            codexSkillsDir: skillsDir
        ).scan()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourcePlatform, "codex")
        XCTAssertEqual(results.first?.sourcePath, skillPath)
        XCTAssertFalse(results.contains { $0.sourcePath == systemPath })
    }

    func testFrontmatterTagsAreDiscovered() throws {
        let skillsDir = tempDir + "/claude/skills"
        let taggedPath = skillsDir + "/tagged/SKILL.md"
        let barePath = skillsDir + "/bare/SKILL.md"
        try fileService.writeFile(
            at: taggedPath,
            content: "---\nname: tagged\ndescription: Tagged fixture\ntags: [a, b]\n---\n# Body\n"
        )
        try fileService.writeFile(at: barePath, content: "# Bare\n")
        let scanner = ImportScanner(
            fileService: fileService,
            claudeSkillsDir: skillsDir,
            grokSkillsDir: tempDir + "/missing-grok-skills",
            cursorRulesDir: tempDir + "/missing-cursor-rules",
            codexSkillsDir: tempDir + "/missing-codex-skills",
            storeRoot: TestPaths.storeRoot
        )

        let results = scanner.scan()

        XCTAssertEqual(results.first { $0.sourcePath == taggedPath }?.tags, ["a", "b"])
        XCTAssertEqual(results.first { $0.sourcePath == barePath }?.tags, [])
    }

    func testScanFolderAcceptsASkillOrAFolderOfSkillsNeverDeeper() throws {
        let scanner = makeScanner(grokSkillsDir: tempDir + "/missing-grok-skills")
        let skillFolder = tempDir + "/A"
        try fileService.writeFile(
            at: skillFolder + "/SKILL.md",
            content: "---\nname: A\ndescription: A fixture\n---\n# A\n"
        )

        let single = scanner.scanFolder(skillFolder)

        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.first?.sourcePath, skillFolder + "/SKILL.md")
        XCTAssertEqual(single.first?.sourcePlatform, "folder")

        let collection = tempDir + "/B"
        for name in ["x", "y"] {
            try fileService.writeFile(
                at: collection + "/\(name)/SKILL.md",
                content: "---\nname: \(name)\ndescription: \(name) fixture\n---\n# \(name)\n"
            )
        }
        try fileService.writeFile(
            at: collection + "/z/deeper/SKILL.md",
            content: "---\nname: deeper\ndescription: Deep fixture\n---\n# Deep\n"
        )

        let grouped = scanner.scanFolder(collection)

        XCTAssertEqual(Set(grouped.map(\.sourcePath)), [
            collection + "/x/SKILL.md",
            collection + "/y/SKILL.md"
        ])
        XCTAssertFalse(grouped.contains { $0.sourcePath.contains("/z/") })

        let empty = tempDir + "/empty"
        try fileService.createDirectory(at: empty)
        XCTAssertTrue(scanner.scanFolder(empty).isEmpty)
    }

    func testScanFolderRefusesTheLibraryItself() throws {
        let store = tempDir + "/store"
        let skills = store + "/skills"
        try fileService.writeFile(
            at: skills + "/a/SKILL.md",
            content: "---\nname: a\ndescription: Store fixture\n---\n# A\n"
        )
        let scanner = ImportScanner(
            fileService: fileService,
            claudeSkillsDir: tempDir + "/missing-claude-skills",
            grokSkillsDir: tempDir + "/missing-grok-skills",
            cursorRulesDir: tempDir + "/missing-cursor-rules",
            codexSkillsDir: tempDir + "/missing-codex-skills",
            storeRoot: store
        )
        let linkedStore = tempDir + "/linked-store"
        try fileService.createSymlink(at: linkedStore, pointingTo: skills)

        XCTAssertTrue(scanner.scanFolder(skills).isEmpty)
        XCTAssertTrue(scanner.isInsideStore(store))
        XCTAssertTrue(scanner.isInsideStore(skills))
        XCTAssertTrue(scanner.isInsideStore(linkedStore))
        XCTAssertFalse(scanner.isInsideStore(tempDir + "/store-sibling"))
    }

    func testScanFolderAdmitsNonScalarKeyFileAsWholeOriginalBody() throws {
        let folder = tempDir + "/hostile"
        let content = "---\nname: Hostile\ndescription: Hostile\nmeta:\n  ? [x]\n  : y\n---\nBody\n"
        try fileService.writeFile(at: folder + "/SKILL.md", content: content)

        let candidate = try XCTUnwrap(
            makeScanner(grokSkillsDir: tempDir + "/missing-grok-skills").scanFolder(folder).first
        )

        XCTAssertEqual(candidate.name, "hostile")
        XCTAssertEqual(candidate.body, content)
        XCTAssertNil(candidate.skillDescription)
    }

    // MARK: - Duplicate Detection

    func testFindDuplicatesIdentical() {
        let a = DiscoveredSkill(
            name: "skill-a",
            body: "same content here",
            sourcePlatform: "claude-code",
            sourcePath: "/a"
        )
        let b = DiscoveredSkill(
            name: "skill-b",
            body: "same content here",
            sourcePlatform: "cursor",
            sourcePath: "/b"
        )

        let groups = ImportScanner.findDuplicates([a, b])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
    }

    func testFindDuplicatesDifferent() {
        let a = DiscoveredSkill(
            name: "skill-a",
            body: "completely different content alpha beta gamma",
            sourcePlatform: "claude-code",
            sourcePath: "/a"
        )
        let b = DiscoveredSkill(
            name: "skill-b",
            body: "nothing in common one two three four five",
            sourcePlatform: "cursor",
            sourcePath: "/b"
        )

        let groups = ImportScanner.findDuplicates([a, b])
        XCTAssertEqual(groups.count, 0)
    }

    func testSimilarityIdentical() {
        let score = ImportScanner.similarity("hello world", "hello world")
        XCTAssertEqual(score, 1.0)
    }

    func testSimilarityEmpty() {
        let score = ImportScanner.similarity("", "")
        XCTAssertEqual(score, 1.0)
    }

    func testSimilarityCompleteDifference() {
        let score = ImportScanner.similarity("alpha beta gamma", "delta epsilon zeta")
        XCTAssertEqual(score, 0.0)
    }

    private func makeScanner(grokSkillsDir: String, codexSkillsDir: String? = nil) -> ImportScanner {
        ImportScanner(
            fileService: fileService,
            claudeSkillsDir: tempDir + "/missing-claude-skills",
            grokSkillsDir: grokSkillsDir,
            cursorRulesDir: tempDir + "/missing-cursor-rules",
            codexSkillsDir: codexSkillsDir ?? tempDir + "/missing-codex-skills",
            storeRoot: tempDir + "/.pensieve"
        )
    }
}
