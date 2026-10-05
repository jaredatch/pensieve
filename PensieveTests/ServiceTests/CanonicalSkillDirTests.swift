import XCTest
@testable import Pensieve

/// PLAN-11 / 11.1 — direct tests for the single C7 resolver
/// `SkillStore.safeSkillDirectory(slug:base:fileService:)`, exercised against a hermetic temp base
/// with the real `FileService` so the symlink + realpath-containment behavior is real (not faked).
///
/// Note on gating: the realpath-containment line also happens to reject `..`/`.`/empty, so the
/// end-to-end `testRejects*Component` nil checks below are backstopped and do NOT independently pin
/// the *component* guard. `testComponentGuardShortCircuitsBeforeFilesystemAccess` closes that gap.
final class CanonicalSkillDirTests: XCTestCase {
    private var tempDir: String!
    private var baseDir: String!
    private let fileService = FileService()

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveCanonicalSkillDirTests-\(UUID().uuidString)"
        baseDir = tempDir + "/skills"
        try FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    func testHappyPathReturnsBaseSlugPath() throws {
        try FileManager.default.createDirectory(atPath: baseDir + "/ok", withIntermediateDirectories: true)
        XCTAssertEqual(
            SkillStore.safeSkillDirectory(slug: "ok", base: baseDir, fileService: fileService),
            baseDir + "/ok"
        )
    }

    func testSymlinkedSlugDirReturnsNil() throws {
        let outside = tempDir + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: baseDir + "/victim", withDestinationPath: outside)
        XCTAssertNil(SkillStore.safeSkillDirectory(slug: "victim", base: baseDir, fileService: fileService))
    }

    func testRejectsDotDotComponent() {
        XCTAssertNil(SkillStore.safeSkillDirectory(slug: "..", base: baseDir, fileService: fileService))
    }

    func testRejectsSeparatorComponent() {
        XCTAssertNil(SkillStore.safeSkillDirectory(slug: "foo/bar", base: baseDir, fileService: fileService))
    }

    func testRejectsDotComponent() {
        XCTAssertNil(SkillStore.safeSkillDirectory(slug: ".", base: baseDir, fileService: fileService))
    }

    func testRejectsEmptyComponent() {
        XCTAssertNil(SkillStore.safeSkillDirectory(slug: "", base: baseDir, fileService: fileService))
    }

    /// Guard isolation: each invalid component must be rejected by the PURE component guard *before*
    /// any filesystem access. Because the realpath-containment line also rejects `..`/`.`/empty, the
    /// end-to-end nil tests above cannot distinguish the component guard from that backstop (verified:
    /// removing only the component guard leaves them green). This pins the component guard on its own
    /// — the FileService traps if `isSymlink` is ever reached, so dropping the guard (falling through
    /// to the FS) turns this red for every input, including `..`/`.`/empty.
    func testComponentGuardShortCircuitsBeforeFilesystemAccess() {
        let trap = TrapOnSymlinkFileService()
        for bad in ["..", ".", "", "foo/bar"] {
            XCTAssertNil(
                SkillStore.safeSkillDirectory(slug: bad, base: baseDir, fileService: trap),
                "invalid component \(bad.isEmpty ? "<empty>" : bad) must return nil before any FS access"
            )
        }
    }
}

/// A `FileServiceProtocol` whose `isSymlink` fails the test if it is ever called — used to prove the
/// component guard in `SkillStore.safeSkillDirectory` short-circuits before touching the filesystem.
private struct TrapOnSymlinkFileService: FileServiceProtocol {
    func readFile(at path: String) throws -> String { "" }
    func writeFile(at path: String, content: String) throws {}
    func writeExecutableFile(at path: String, content: String) throws {}
    func deleteFile(at path: String) throws {}
    func fileExists(at path: String) -> Bool { false }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { false }
    func createDirectory(at path: String) throws {}
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
    func symlinkTarget(at path: String) throws -> String { "" }
    func isSymlink(at path: String) -> Bool {
        XCTFail("component guard must reject before any filesystem access — isSymlink called for \(path)")
        return false
    }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String { "" }
}
