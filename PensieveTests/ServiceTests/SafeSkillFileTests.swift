import XCTest
@testable import Pensieve

/// PLAN-12 / 12.7 — direct tests for the leaf-symlink guard
/// `SkillStore.safeSkillFile(slug:base:fileService:)`, the companion to `safeSkillDirectory` that
/// closes the recorded C7 leaf residual: a real `skills/<slug>/` directory whose `SKILL.md` LEAF is a
/// symlink pointing outside the store was followed on read. Exercised against a hermetic temp base
/// with the real `FileService` so the symlink behavior is real (not faked).
final class SafeSkillFileTests: XCTestCase {
    private var tempDir: String!
    private var baseDir: String!
    private let fileService = FileService()

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveSafeSkillFileTests-\(UUID().uuidString)"
        baseDir = tempDir + "/skills"
        try FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    /// Happy path: a real dir with a real regular SKILL.md returns `<dir>/SKILL.md`.
    func testHappyPathReturnsSkillFilePath() throws {
        let dir = baseDir + "/ok"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/SKILL.md", contents: Data("body".utf8))
        XCTAssertEqual(
            SkillStore.safeSkillFile(slug: "ok", base: baseDir, fileService: fileService),
            dir + "/SKILL.md"
        )
    }

    /// THE escape test (mutation-probe target): a real dir whose SKILL.md LEAF is a symlink to an
    /// EXISTING file outside the store must return nil. The target must EXIST so that removing the
    /// `isSymlink` leaf guard would make `fileExists` (which follows symlinks) return true and leak the
    /// path — i.e. disabling the guard reddens exactly this test.
    func testSymlinkedLeafReturnsNil() throws {
        let dir = baseDir + "/victim"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let secret = tempDir + "/secret.txt"
        FileManager.default.createFile(atPath: secret, contents: Data("PRIVATE".utf8))
        try FileManager.default.createSymbolicLink(atPath: dir + "/SKILL.md", withDestinationPath: secret)
        XCTAssertNil(SkillStore.safeSkillFile(slug: "victim", base: baseDir, fileService: fileService))
    }

    /// A directory with no SKILL.md at all → nil (an absent leaf is "no readable skill").
    func testAbsentSkillFileReturnsNil() throws {
        let dir = baseDir + "/empty"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertNil(SkillStore.safeSkillFile(slug: "empty", base: baseDir, fileService: fileService))
    }

    /// `SKILL.md` present but as a DIRECTORY, not a regular file → nil (fileExists is false for dirs).
    func testSkillMdDirectoryReturnsNil() throws {
        let dir = baseDir + "/weird"
        try FileManager.default.createDirectory(atPath: dir + "/SKILL.md", withIntermediateDirectories: true)
        XCTAssertNil(SkillStore.safeSkillFile(slug: "weird", base: baseDir, fileService: fileService))
    }

    /// Composition: a symlinked SLUG DIR is rejected by the delegated `safeSkillDirectory` before the
    /// leaf is ever considered.
    func testSymlinkedSlugDirReturnsNil() throws {
        let outside = tempDir + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outside + "/SKILL.md", contents: Data("body".utf8))
        try FileManager.default.createSymbolicLink(atPath: baseDir + "/link", withDestinationPath: outside)
        XCTAssertNil(SkillStore.safeSkillFile(slug: "link", base: baseDir, fileService: fileService))
    }

    /// Composition: an invalid slug component is rejected by the delegated pure component guard.
    func testInvalidComponentReturnsNil() {
        for bad in ["..", ".", "", "foo/bar"] {
            XCTAssertNil(
                SkillStore.safeSkillFile(slug: bad, base: baseDir, fileService: fileService),
                "invalid component \(bad.isEmpty ? "<empty>" : bad) must return nil"
            )
        }
    }

    /// Special-node leaf: a `SKILL.md` that is a FIFO (not a regular file) → nil. `fileExists` would
    /// return true for a FIFO/socket/device (it only filters directories), so this pins the guard on
    /// `isRegularFile` — reverting to `fileExists` reddens exactly this test, and a daemon read of a
    /// FIFO leaf would otherwise block indefinitely. (PLAN-12 / 12.7 Layer-2.)
    func testSpecialNodeLeafReturnsNil() throws {
        let dir = baseDir + "/fifo"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(dir + "/SKILL.md", 0o644), 0, "mkfifo should create the FIFO fixture")
        XCTAssertNil(SkillStore.safeSkillFile(slug: "fifo", base: baseDir, fileService: fileService))
    }
}
