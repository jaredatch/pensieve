import XCTest
@testable import Pensieve

/// The directory walk behind the Overview's Bundle stat and Contents list (PLAN-34 / 34.1), over the real
/// `FileService` in a temp directory: sizes and tokens, hidden entries, symlinks, and the two caps.
final class SkillBundleInventoryTests: XCTestCase {
    private var root = ""
    private let fileService = FileService()

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "SkillBundleInventoryTests-" + UUID().uuidString
        try fileService.createDirectory(at: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ relative: String, _ text: String) throws {
        try fileService.writeFile(at: root + "/" + relative, content: text)
    }

    func testScanListsRegularFilesSortedWithSizes() throws {
        try write("SKILL.md", "# Skill\n")
        try write("scripts/run.sh", "echo hi\n")
        try write("references/api.md", "## API\n\nText.\n")

        let inventory = SkillBundleInventory.scan(root: root, fileService: fileService)

        XCTAssertEqual(inventory.files.map(\.relativePath), ["SKILL.md", "references/api.md", "scripts/run.sh"])
        XCTAssertEqual(inventory.files.map(\.bytes),
                       ["# Skill\n".utf8.count, "## API\n\nText.\n".utf8.count, "echo hi\n".utf8.count])
        XCTAssertEqual(inventory.fileCount, 3)
        XCTAssertEqual(inventory.totalBytes, "# Skill\n".utf8.count + "## API\n\nText.\n".utf8.count + "echo hi\n".utf8.count)
        XCTAssertFalse(inventory.truncated)
    }

    func testTextFilesCarryTokensAndBinariesDoNot() throws {
        let text = String(repeating: "word ", count: 40)
        try write("SKILL.md", text)
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: URL(fileURLWithPath: root + "/logo.bin"))

        let inventory = SkillBundleInventory.scan(root: root, fileService: fileService)

        XCTAssertEqual(inventory.files.first { $0.relativePath == "SKILL.md" }?.tokens, TokenCounter.estimate(text))
        XCTAssertNil(inventory.files.first { $0.relativePath == "logo.bin" }?.tokens)
        XCTAssertEqual(inventory.fileCount, 2)
        XCTAssertEqual(inventory.totalBytes, text.utf8.count + 4)
        XCTAssertEqual(inventory.textFiles.map(\.relativePath), ["SKILL.md"])
    }

    func testHiddenEntriesAreSkipped() throws {
        try write("SKILL.md", "x")
        try write(".DS_Store", "junk")
        try write(".git/config", "[core]")

        let inventory = SkillBundleInventory.scan(root: root, fileService: fileService)

        XCTAssertEqual(inventory.files.map(\.relativePath), ["SKILL.md"])
    }

    func testASymlinkedDirectoryAndASymlinkedFileAreNotFollowed() throws {
        try write("SKILL.md", "x")
        let sibling = root + "-sibling"
        try fileService.createDirectory(at: sibling)
        try fileService.writeFile(at: sibling + "/secret.md", content: "outside")
        defer { try? FileManager.default.removeItem(atPath: sibling) }
        try fileService.createSymlink(at: root + "/linked-dir", pointingTo: sibling)
        try fileService.createSymlink(at: root + "/linked-file.md", pointingTo: sibling + "/secret.md")

        let inventory = SkillBundleInventory.scan(root: root, fileService: fileService)

        XCTAssertEqual(inventory.files.map(\.relativePath), ["SKILL.md"])
    }

    func testTheWalkStopsAtTheFileCapAndSaysSo() throws {
        for index in 0...SkillBundleInventory.maxFiles {
            try write(String(format: "f%04d.txt", index), "x")
        }

        let inventory = SkillBundleInventory.scan(root: root, fileService: fileService)

        XCTAssertEqual(inventory.fileCount, SkillBundleInventory.maxFiles)
        XCTAssertTrue(inventory.truncated)
    }

    func testTheWalkStopsListingOnceTheCapIsSpent() throws {
        for index in 0...SkillBundleInventory.maxFiles {
            try write(String(format: "aaa/f%04d.txt", index), "x")
        }
        try write("bbb/one.md", "b")
        try write("ccc/one.md", "c")
        let counter = ListingCountingFileService()

        let inventory = SkillBundleInventory.scan(root: root, fileService: counter)

        XCTAssertEqual(inventory.fileCount, SkillBundleInventory.maxFiles)
        XCTAssertTrue(inventory.truncated)
        XCTAssertEqual(counter.listings, [root, root + "/aaa"])
    }

    func testTheWalkStopsAtTheDepthCapAndSaysSo() throws {
        var path = root
        for level in 0...SkillBundleInventory.maxDepth {
            path += "/d\(level)"
        }
        try fileService.createDirectory(at: path)
        try fileService.writeFile(at: path + "/deep.md", content: "deep")
        try write("SKILL.md", "x")

        let inventory = SkillBundleInventory.scan(root: root, fileService: fileService)

        XCTAssertEqual(inventory.files.map(\.relativePath), ["SKILL.md"])
        XCTAssertTrue(inventory.truncated)
    }

    func testEmptyDirectoryIsEmpty() {
        let inventory = SkillBundleInventory.scan(root: root, fileService: fileService)

        XCTAssertEqual(inventory, .empty)
        XCTAssertEqual(inventory.fileCount, 0)
        XCTAssertEqual(inventory.totalBytes, 0)
    }

    func testAnUnreadableSubdirectoryMarksTheInventoryTruncated() throws {
        try write("SKILL.md", "x")
        try write("unreadable/secret.md", "s")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/unreadable")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/unreadable")
        }

        let inventory = SkillBundleInventory.scan(root: root, fileService: fileService)

        XCTAssertEqual(inventory.files.map(\.relativePath), ["SKILL.md"])
        XCTAssertTrue(inventory.truncated)
    }

    func testExactlyTheCapFollowedByAnEmptyDirectoryIsNotTruncated() throws {
        for index in 0..<SkillBundleInventory.maxFiles {
            try write(String(format: "f%04d.txt", index), "x")
        }
        try fileService.createDirectory(at: root + "/zzz")

        let inventory = SkillBundleInventory.scan(root: root, fileService: fileService)

        XCTAssertEqual(inventory.fileCount, SkillBundleInventory.maxFiles)
        XCTAssertFalse(inventory.truncated)
    }

    func testANameTheReadRefusesIsNotListed() throws {
        try write("SKILL.md", "x")
        try write("a\\b.md", "backslash")
        try write("bad\u{01}.md", "control")

        let inventory = SkillBundleInventory.scan(root: root, fileService: fileService)

        XCTAssertEqual(inventory.files.map(\.relativePath), ["SKILL.md"])
    }
}

/// The real file service, counting directory listings.
private final class ListingCountingFileService: FileServiceProtocol {
    private let base = FileService()
    private(set) var listings: [String] = []

    func listDirectory(at path: String) throws -> [String] { listings.append(path); return try base.listDirectory(at: path) }
    func readFile(at path: String) throws -> String { try base.readFile(at: path) }
    func readData(at path: String) throws -> Data { try base.readData(at: path) }
    func writeFile(at path: String, content: String) throws { try base.writeFile(at: path, content: content) }
    func deleteFile(at path: String) throws { try base.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { base.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try base.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try base.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try base.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { base.isSymlink(at: path) }
    func isRegularFile(at path: String) -> Bool { base.isRegularFile(at: path) }
    func contentsHash(at path: String) throws -> String { try base.contentsHash(at: path) }
}
