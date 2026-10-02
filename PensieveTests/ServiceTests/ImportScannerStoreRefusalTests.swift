import XCTest
@testable import Pensieve

/// The store-refusal rules PLAN-30 / 30.2's Layer-2 and own-fix reviews added to `ImportScanner`.
/// A candidate is refused when its path lands in or passes through the library, by the
/// file system's identity, with `..` applied to real parents, in a linear walk.
final class ImportScannerStoreRefusalTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("PensieveImportScannerStoreRefusalTests-" + UUID().uuidString)
        fileService = FileService()
        try fileService.createDirectory(at: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempDir)
        try super.tearDownWithError()
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

    /// PLAN-30 / 30.2 Layer-2: a skill that reaches the store through a symlink — on a child entry
    /// (through an alias, so the target's name never says `.pensieve`) or on the `SKILL.md` itself —
    /// is refused the same as the library itself.
    func testScanFolderRefusesSkillsLinkedIntoTheLibrary() throws {
        let store = tempDir + "/store"
        try fileService.writeFile(
            at: store + "/skills/a/SKILL.md",
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
        try fileService.createSymlink(at: tempDir + "/alias", pointingTo: store + "/skills")
        let collection = tempDir + "/collection"
        try fileService.writeFile(
            at: collection + "/b/SKILL.md",
            content: "---\nname: b\ndescription: Real fixture\n---\n# B\n"
        )
        try fileService.createSymlink(at: collection + "/a", pointingTo: tempDir + "/alias/a")
        let leaf = tempDir + "/leaf"
        try fileService.createDirectory(at: leaf)
        try fileService.createSymlink(at: leaf + "/SKILL.md", pointingTo: store + "/skills/a/SKILL.md")

        XCTAssertEqual(scanner.scanFolder(collection).map(\.sourcePath), [collection + "/b/SKILL.md"])
        XCTAssertTrue(scanner.scanFolder(leaf).isEmpty)
    }

    /// PLAN-30 / 30.2 own-fix review, C7: a deploy link into a canonical `skills/<slug>` that itself
    /// links back OUT of the store is still refused — the chain passes through the library — on a
    /// directory link and on a `SKILL.md` leaf link alike.
    func testImportRefusesLinksThatPassThroughTheLibrary() throws {
        let store = tempDir + "/.pensieve"
        let outside = tempDir + "/outside"
        try fileService.writeFile(
            at: outside + "/a/SKILL.md",
            content: "---\nname: a\ndescription: Outside fixture\n---\n# A\n"
        )
        try fileService.writeFile(at: outside + "/leaf.md", content: "---\nname: leaf\ndescription: Leaf\n---\n# L\n")
        try fileService.createDirectory(at: store + "/skills")
        try fileService.createSymlink(at: store + "/skills/a", pointingTo: outside + "/a")
        try fileService.createDirectory(at: store + "/skills/b")
        try fileService.createSymlink(at: store + "/skills/b/SKILL.md", pointingTo: outside + "/leaf.md")
        let claude = tempDir + "/claude/skills"
        try fileService.createDirectory(at: claude)
        try fileService.createSymlink(at: claude + "/a", pointingTo: store + "/skills/a")
        try fileService.createSymlink(at: claude + "/b", pointingTo: store + "/skills/b")
        let scanner = ImportScanner(
            fileService: fileService,
            claudeSkillsDir: claude,
            grokSkillsDir: tempDir + "/missing-grok-skills",
            cursorRulesDir: tempDir + "/missing-cursor-rules",
            codexSkillsDir: tempDir + "/missing-codex-skills",
            storeRoot: store
        )

        XCTAssertTrue(scanner.scan().isEmpty)
        XCTAssertTrue(scanner.isInsideStore(claude + "/a/SKILL.md"))
        XCTAssertTrue(scanner.isInsideStore(claude + "/b/SKILL.md"))
        XCTAssertFalse(scanner.isInsideStore(outside + "/a/SKILL.md"))
        XCTAssertTrue(scanner.scanFolder(claude + "/a").isEmpty)
        XCTAssertEqual(scanner.scanFolder(outside).count, 1)
    }

    /// Own-fix review round 2: a relative link target applies its `..` to the link's REAL parent, so a
    /// skill reached through an aliased parent that steps up into a sibling `.pensieve` is not the
    /// store's; and a chain of nested aliases costs a walk, not a tree.
    func testIsInsideStoreResolvesRelativeTargetsAgainstTheRealParent() throws {
        let store = tempDir + "/.pensieve"
        try fileService.createDirectory(at: store + "/skills")
        try fileService.writeFile(
            at: tempDir + "/other/.pensieve/skills/a/SKILL.md",
            content: "---\nname: a\ndescription: Not the store\n---\n# A\n"
        )
        try fileService.createDirectory(at: tempDir + "/other/sub")
        try fileService.createSymlink(at: tempDir + "/other/sub/skill", pointingTo: "../.pensieve/skills/a")
        try fileService.createSymlink(at: tempDir + "/alias", pointingTo: tempDir + "/other/sub")
        let scanner = makeScanner(grokSkillsDir: tempDir + "/missing-grok-skills")

        XCTAssertFalse(scanner.isInsideStore(tempDir + "/alias/skill/SKILL.md"))
        XCTAssertEqual(scanner.scanFolder(tempDir + "/alias/skill").count, 1)

        // Eleven nested aliased parents — each `aliasN -> actualN` created INSIDE the previous aliased
        // directory — the shape that made a root-restarting recursion exponential (≈1.5 s per check;
        // the linear walk takes milliseconds).
        var actual: String = tempDir
        var aliased: String = tempDir
        for level in 1...11 {
            try fileService.createDirectory(at: actual + "/actual\(level)")
            try fileService.createSymlink(at: actual + "/alias\(level)", pointingTo: "actual\(level)")
            actual += "/actual\(level)"
            aliased += "/alias\(level)"
        }
        let started = Date()
        XCTAssertFalse(scanner.isInsideStore(aliased + "/x/y/SKILL.md"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)

        try fileService.createSymlink(at: tempDir + "/loop-a", pointingTo: tempDir + "/loop-b")
        try fileService.createSymlink(at: tempDir + "/loop-b", pointingTo: tempDir + "/loop-a")
        XCTAssertTrue(scanner.isInsideStore(tempDir + "/loop-a/SKILL.md"))   // refused, never spun on
    }

    /// Own-fix review round 3: on a case-insensitive volume a differently cased spelling of the store
    /// is the store — a link that names `.PENSIEVE/skills/a` reaches the same directory and is refused
    /// by identity (device and inode), not by spelling, even when that store entry links back out.
    func testIsInsideStoreMatchesTheStoreByIdentityNotSpelling() throws {
        let store = tempDir + "/.pensieve"
        try fileService.createDirectory(at: store + "/skills")
        try fileService.writeFile(
            at: tempDir + "/outside/a/SKILL.md",
            content: "---\nname: a\ndescription: Outside\n---\n# A\n"
        )
        try fileService.createSymlink(at: store + "/skills/a", pointingTo: tempDir + "/outside/a")
        let claude = tempDir + "/claude/skills"
        try fileService.createDirectory(at: claude)
        try fileService.createSymlink(at: claude + "/a", pointingTo: tempDir + "/.PENSIEVE/skills/a")
        let scanner = ImportScanner(
            fileService: fileService,
            claudeSkillsDir: claude,
            grokSkillsDir: tempDir + "/missing-grok-skills",
            cursorRulesDir: tempDir + "/missing-cursor-rules",
            codexSkillsDir: tempDir + "/missing-codex-skills",
            storeRoot: store
        )
        // Only meaningful where the spellings meet the same directory; on a case-sensitive volume
        // `.PENSIEVE` does not exist and the link dangles.
        guard fileService.directoryExists(at: tempDir + "/.PENSIEVE") else { return }

        XCTAssertTrue(scanner.isInsideStore(tempDir + "/.PENSIEVE/skills/a/SKILL.md"))
        XCTAssertTrue(scanner.isInsideStore(claude + "/a/SKILL.md"))
        XCTAssertTrue(scanner.scan().isEmpty)
        XCTAssertTrue(scanner.scanFolder(tempDir + "/.PENSIEVE/skills").isEmpty)
        XCTAssertFalse(scanner.isInsideStore(tempDir + "/outside/a/SKILL.md"))
    }

    /// PLAN-30 / 30.2 Layer-2: a chosen folder that holds a `SKILL.md` is a skill, so an unreadable
    /// one yields nothing — the import never silently widens to the folder's children.
    func testScanFolderWithAnUnreadableSkillFileNeverFallsThroughToChildren() throws {
        let folder = tempDir + "/unreadable"
        try fileService.writeFile(at: folder + "/SKILL.md", content: "# Own\n")
        try fileService.writeFile(
            at: folder + "/child/SKILL.md",
            content: "---\nname: child\ndescription: Child fixture\n---\n# Child\n"
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder + "/SKILL.md")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder + "/SKILL.md") }
        let scanner = makeScanner(grokSkillsDir: tempDir + "/missing-grok-skills")

        XCTAssertTrue(scanner.scanFolder(folder).isEmpty)
        XCTAssertEqual(scanner.scanFolder(folder + "/child").count, 1)
    }
}
