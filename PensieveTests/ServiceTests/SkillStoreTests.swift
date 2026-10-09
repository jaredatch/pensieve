import XCTest
@testable import Pensieve

final class SkillStoreTests: XCTestCase {
    private struct FakeFS: FileServiceProtocol {
        var symlink: Bool
        var body: String

        func readFile(at path: String) throws -> String { body }
        func writeFile(at path: String, content: String) throws {}
        func deleteFile(at path: String) throws {}
        func fileExists(at path: String) -> Bool { true }
        func isExecutableFile(at path: String) -> Bool { false }
        func directoryExists(at path: String) -> Bool { true }
        func createDirectory(at path: String) throws {}
        func deleteDirectory(at path: String) throws {}
        func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
        func symlinkTarget(at path: String) throws -> String { "" }
        func isSymlink(at path: String) -> Bool { symlink }
        func isRegularFile(at path: String) -> Bool { !symlink }
        func listDirectory(at path: String) throws -> [String] { [] }
        func contentsHash(at path: String) throws -> String { "hash" }
    }

    private struct UnlistableFS: FileServiceProtocol {
        func readFile(at path: String) throws -> String { "" }
        func writeFile(at path: String, content: String) throws {}
        func deleteFile(at path: String) throws {}
        func fileExists(at path: String) -> Bool { false }
        func isExecutableFile(at path: String) -> Bool { false }
        func directoryExists(at path: String) -> Bool { true }
        func createDirectory(at path: String) throws {}
        func deleteDirectory(at path: String) throws {}
        func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
        func symlinkTarget(at path: String) throws -> String { "" }
        func isSymlink(at path: String) -> Bool { false }
        func isRegularFile(at path: String) -> Bool { false }
        func listDirectory(at path: String) throws -> [String] { throw DeletionTestError() }
        func contentsHash(at path: String) throws -> String { "" }
    }

    private func tempRoot() throws -> String {
        let root = TestTemporaryDirectory.path + "SkillStoreDelete-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return root
    }

    func testSlugify() {
        XCTAssertEqual(SkillStore.slugify("TypeScript Best Practices"), "typescript-best-practices")
        XCTAssertEqual(SkillStore.slugify("Code Review!!! Guidelines"), "code-review-guidelines")
        XCTAssertEqual(SkillStore.slugify("  leading-trailing  "), "leading-trailing")
        XCTAssertEqual(SkillStore.slugify("UPPER CASE"), "upper-case")
    }

    func testSlugifyPunctuationOnlyFallsBackToSkill() {
        XCTAssertEqual(SkillStore.slugify("!!!"), "skill")
        XCTAssertEqual(SkillStore.slugify("@#$%^&*()"), "skill")
        XCTAssertEqual(SkillStore.slugify("..."), "skill")
    }

    func testSlugifyUnicodeOnlyFallsBackToSkill() {
        XCTAssertEqual(SkillStore.slugify("日本語"), "skill")
        XCTAssertEqual(SkillStore.slugify("😀🎉"), "skill")
        XCTAssertEqual(SkillStore.slugify("Ω≈ç√"), "skill")
    }

    func testSymlinkedSlugDirRejectedForWriteAndReadWithoutTouchingTarget() throws {
        let fileService = FileService()
        let tempDir = TestTemporaryDirectory.path + "PensieveSkillStoreTests-\(UUID().uuidString)"
        let baseDir = tempDir + "/skills"
        let outside = tempDir + "/outside"
        try FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let sentinel = "SENTINEL-OUT-OF-STORE"
        try fileService.writeFile(at: outside + "/SKILL.md", content: sentinel)
        // symlink baseDir/victim -> outside (a symlinked DIRECTORY)
        try FileManager.default.createSymbolicLink(atPath: baseDir + "/victim", withDestinationPath: outside)

        let store = SkillStore(fileService: fileService, baseDir: baseDir, storeRoot: baseDir)

        XCTAssertThrowsError(
            try store.rewriteSkill(
                directoryName: "victim",
                body: "Z",
                preserving: SkillParser.parse("Z"),
                fallbackName: "X",
                fallbackDescription: "Y"
            )
        ) {
            XCTAssertEqual($0 as? SkillStoreError, .invalidDirectory("victim"))
        }
        XCTAssertThrowsError(try store.writeBody(directoryName: "victim", body: "Z")) {
            XCTAssertEqual($0 as? SkillStoreError, .invalidDirectory("victim"))
        }
        // target NOT overwritten through the symlink
        XCTAssertEqual(try fileService.readFile(at: outside + "/SKILL.md"), sentinel)
        // readBody refuses - does NOT return the out-of-store content (the read-through vector)
        XCTAssertThrowsError(try store.readBody(directoryName: "victim")) {
            XCTAssertEqual($0 as? SkillStoreError, .invalidDirectory("victim"))
        }
    }

    func testRealSlugDirRoundTripsThroughGuard() throws {
        let fileService = FileService()
        let tempDir = TestTemporaryDirectory.path + "PensieveSkillStoreTests-\(UUID().uuidString)"
        let baseDir = tempDir + "/skills"
        try FileManager.default.createDirectory(atPath: baseDir + "/ok", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let store = SkillStore(fileService: fileService, baseDir: baseDir, storeRoot: baseDir)
        try store.rewriteSkill(
            directoryName: "ok",
            body: "# Body",
            preserving: SkillParser.parse("# Old"),
            fallbackName: "OK",
            fallbackDescription: "d"
        )
        let raw = try store.readBody(directoryName: "ok")
        XCTAssertTrue(raw.contains("# Body"))
        XCTAssertTrue(raw.contains("name: OK"))
    }

    func testEstimatedTokensZeroForSymlinkedDir() {
        let skill = Skill(name: "S", skillDescription: "d", directoryName: "victim")
        let body = String(repeating: "x", count: 1000)
        XCTAssertEqual(SkillLibraryViewModel.testTokenEstimate(skill, fileService: FakeFS(symlink: true, body: body)), 0)
    }

    func testEstimatedTokensNonZeroForRealDir() {
        let skill = Skill(name: "S", skillDescription: "d", directoryName: "ok")
        let body = String(repeating: "x", count: 1000)
        XCTAssertGreaterThan(SkillLibraryViewModel.testTokenEstimate(skill, fileService: FakeFS(symlink: false, body: body)), 0)
    }

    func testEstimatedTokensReturnsZeroForInvalidDirectoryName() {
        // "../evil" is a traversing component the old `!isSymlink`-only guard accepted; the shared
        // C7 resolver rejects it on component validation, so tokens fall through to 0 even though the
        // non-symlink FakeFS would return a 1000-char body.
        let skill = Skill(name: "S", skillDescription: "d", directoryName: "../evil")
        let body = String(repeating: "x", count: 1000)
        XCTAssertEqual(SkillLibraryViewModel.testTokenEstimate(skill, fileService: FakeFS(symlink: false, body: body)), 0)
    }

    func testCreateSkillAvoidsGivenSlugs() throws {
        let root = try tempRoot(), store = SkillStore(fileService: FileService(), baseDir: root, storeRoot: root)
        XCTAssertEqual(try store.createSkill(name: "Foo", description: "d", body: "b", avoiding: ["foo"]), "foo-2")
        XCTAssertEqual(
            try store.createSkill(name: "Foo", description: "d", body: "b", avoiding: ["foo", "foo-3"]),
            "foo-4"
        )
        XCTAssertEqual(
            try store.createSkill(
                name: "Foo", description: "d", body: "b", avoiding: ["FOO", "Foo-3", "Foo-5"]),
            "foo-6"
        )
        XCTAssertEqual(try store.createSkill(name: "Foo", description: "d", body: "b"), "foo")
        let files = FileService()
        try files.writeFile(at: root + "/BAR", content: "occupant")
        try files.createSymlink(at: root + "/bar-2", pointingTo: root + "/absent")
        try files.createDirectory(at: root + "/bar-3")
        XCTAssertEqual(try store.createSkill(name: "Bar", description: "d", body: "b"), "bar-4")
        XCTAssertEqual(try files.readFile(at: root + "/BAR"), "occupant")
        XCTAssertTrue(files.isSymlink(at: root + "/bar-2"))
        XCTAssertEqual(try files.symlinkTarget(at: root + "/bar-2"), root + "/absent")
        XCTAssertTrue(try files.listDirectory(at: root + "/bar-3").isEmpty)
    }

    func testReadBodyRefusesSymlinkedLeafAndDirectoryLeaf() throws {
        let root = try tempRoot(), fs = FileService(), store = SkillStore(fileService: fs, baseDir: root, storeRoot: root)
        try fs.createDirectory(at: root + "/outside")
        try fs.writeFile(at: root + "/outside/source", content: "body")
        try fs.createDirectory(at: root + "/linked")
        try fs.createSymlink(at: root + "/linked/SKILL.md", pointingTo: root + "/outside/source")
        XCTAssertThrowsError(try store.readBody(directoryName: "linked")) {
            XCTAssertEqual($0 as? SkillStoreError, .unsafeLeaf("linked"))
        }
        XCTAssertTrue(try store.listSkills().contains("linked"))
        try fs.createDirectory(at: root + "/directory/SKILL.md")
        XCTAssertThrowsError(try store.readBody(directoryName: "directory"))
        try fs.createDirectory(at: root + "/plain")
        try fs.writeFile(at: root + "/plain/SKILL.md", content: "plain")
        XCTAssertEqual(try store.readBody(directoryName: "plain"), "plain")
    }

    func testSlugEntryProbeSeesEveryEntryShape() throws {
        let root = try tempRoot(), fs = FileService(), store = SkillStore(fileService: fs, baseDir: root, storeRoot: root)
        XCTAssertFalse(try store.slugEntryExists("absent"))
        try fs.createDirectory(at: root + "/empty")
        try fs.createDirectory(at: root + "/directory-leaf/SKILL.md")
        try fs.createSymlink(at: root + "/dangling", pointingTo: root + "/missing")
        try fs.writeFile(at: root + "/plain-file", content: "x")
        try fs.createDirectory(at: root + "/foo")
        try fs.writeFile(at: root + "/foo/SKILL.md", content: "x")
        for slug in ["empty", "directory-leaf", "dangling", "plain-file", "foo", "FOO"] {
            XCTAssertTrue(try store.slugEntryExists(slug))
        }
        XCTAssertFalse(try store.listSkills().contains("directory-leaf"))
        for slug in [".", "..", "a/b", ".foo"] {
            XCTAssertThrowsError(try store.slugEntryExists(slug))
        }
        let missingStore = SkillStore(fileService: fs, baseDir: root + "/missing-parent", storeRoot: root + "/missing-parent")
        XCTAssertThrowsError(try missingStore.slugEntryExists("foo"))
        XCTAssertThrowsError(try SkillStore(fileService: UnlistableFS(), baseDir: "/x", storeRoot: "/x").slugEntryExists("foo"))
    }

    func testDeleteSkillRefusesTraversingAndSymlinkedNames() throws {
        let root = try tempRoot(), base = root + "/skills", sentinel = root + "/sentinel"
        let fs = FileService(), store = SkillStore(fileService: fs, baseDir: base, storeRoot: base)
        try fs.createDirectory(at: base + "/real")
        try fs.writeFile(at: base + "/real/SKILL.md", content: "real")
        try fs.createDirectory(at: sentinel)
        try fs.writeFile(at: sentinel + "/keep", content: "keep")
        try fs.createSymlink(at: base + "/linked", pointingTo: sentinel)
        for slug in ["..", "a/b", ".", "", "linked"] {
            XCTAssertThrowsError(try store.deleteSkill(directoryName: slug))
            XCTAssertTrue(fs.fileExists(at: sentinel + "/keep"))
            XCTAssertTrue(fs.fileExists(at: base + "/real/SKILL.md"))
        }
        XCTAssertTrue(fs.isSymlink(at: base + "/linked"))
        try store.deleteSkill(directoryName: "real")
        XCTAssertFalse(fs.directoryExists(at: base + "/real"))
    }
}

extension SkillLibraryViewModel {
    /// Builds a library over the test skills folder and returns its token estimate for `skill`.
    static func testTokenEstimate(_ skill: Skill, fileService: FileServiceProtocol) -> Int {
        SkillLibraryViewModel(
            skillStore: SkillStore(fileService: fileService, baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot),
            fileService: fileService, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestRoot: TestPaths.storeRoot
        ).estimatedTokens(skill)
    }
}
