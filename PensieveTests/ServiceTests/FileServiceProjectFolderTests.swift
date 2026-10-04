import Darwin
import XCTest
@testable import Pensieve

final class FileServiceProjectFolderTests: XCTestCase {
    private let files = FileService()
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "FileServiceProjectFolderTests-\(UUID().uuidString)"
        try files.createDirectory(at: root)
    }

    override func tearDownWithError() throws {
        try files.deleteDirectory(at: root)
    }

    func testDirectoryProbeFollowsLinksAndDistinguishesNonDirectories() throws {
        let directory = root + "/directory"
        let file = root + "/file"
        try files.createDirectory(at: directory)
        try files.writeFile(at: file, content: "Bytes")
        try files.createSymlink(at: root + "/directory-link", pointingTo: directory)
        try files.createSymlink(at: root + "/file-link", pointingTo: file)
        try files.createSymlink(at: root + "/dangling", pointingTo: root + "/absent")
        XCTAssertTrue(try files.directoryExistsFollowingLinks(at: directory))
        XCTAssertTrue(try files.directoryExistsFollowingLinks(at: root + "/directory-link"))
        for path in [root + "/absent", file, file + "/child", root + "/file-link", root + "/dangling"] {
            XCTAssertFalse(try files.directoryExistsFollowingLinks(at: path))
        }
    }

    func testDirectoryProbePreservesPermissionFailure() throws {
        let parent = root + "/parent"
        try files.createDirectory(at: parent + "/project")
        XCTAssertEqual(chmod(parent, 0), 0)
        defer { XCTAssertEqual(chmod(parent, 0o700), 0) }
        XCTAssertThrowsError(try files.directoryExistsFollowingLinks(at: parent + "/project")) { error in
            let posix = error as NSError
            XCTAssertEqual(posix.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(posix.code, Int(EACCES))
        }
    }

    func testNonrecursiveCreationPrimitivesNeverCreateMissingParents() throws {
        let parent = root + "/absent/project"
        XCTAssertThrowsError(try files.createDirectoryWithoutParents(at: parent + "/child"))
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: root + "/absent"))
        XCTAssertThrowsError(try files.createSymlinkWithoutParents(at: parent + "/link", pointingTo: root))
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: root + "/absent"))
        XCTAssertThrowsError(try files.writeFileWithoutParents(at: parent + "/rule.mdc", content: "Rule"))
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: root + "/absent"))
    }

    func testNonrecursiveWritesReplaceArtifactsAndPreserveLinkTargets() throws {
        let target = root + "/target"
        let link = root + "/link"
        try files.writeFile(at: target, content: "Target bytes")
        try files.createSymlinkWithoutParents(at: link, pointingTo: target)
        try files.writeFileWithoutParents(at: link, content: "Compiled bytes")
        XCTAssertFalse(files.isSymlink(at: link))
        XCTAssertEqual(try files.readFile(at: link), "Compiled bytes")
        XCTAssertEqual(try files.readFile(at: target), "Target bytes")
        try files.createSymlinkWithoutParents(at: link, pointingTo: target)
        try files.createSymlinkWithoutParents(at: link, pointingTo: root + "/absent")
        XCTAssertEqual(try files.symlinkTarget(at: link), root + "/absent")
        XCTAssertEqual(try files.readFile(at: target), "Target bytes")
    }

    func testUnmodeledProjectOperationsThrowWithoutMutatingDouble() throws {
        let double = DeployRecordingFileService()
        XCTAssertThrowsError(try double.directoryExistsFollowingLinks(at: root))
        XCTAssertThrowsError(try double.createDirectoryWithoutParents(at: root + "/new"))
        XCTAssertThrowsError(try double.writeFileWithoutParents(at: root + "/file", content: "Bytes"))
        XCTAssertThrowsError(try double.createSymlinkWithoutParents(at: root + "/link", pointingTo: root))
        XCTAssertEqual(try files.listDirectory(at: root), [])
        XCTAssertTrue(double.files.isEmpty)
        XCTAssertTrue(double.symlinks.isEmpty)
    }

    func testDirectoryAppearingImmediatelyBeforeMkdirIsReused() throws {
        let path = root + "/concurrent"
        var reachedCreate = false
        var identity: FileIdentity?
        XCTAssertNoThrow(try files.createDirectoryWithoutParents(at: path) { directory in
            XCTAssertFalse(try self.files.directoryExistsFollowingLinks(at: directory))
            reachedCreate = true
            try self.files.createDirectory(at: directory)
            identity = self.files.fileIdentity(at: directory, followingLinks: true)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        })
        XCTAssertTrue(reachedCreate)
        XCTAssertNotNil(identity)
        XCTAssertEqual(files.fileIdentity(at: path, followingLinks: true), identity)
    }

    func testFileAppearingImmediatelyBeforeMkdirIsPreservedAndFails() throws {
        let path = root + "/concurrent-file"
        var reachedCreate = false
        XCTAssertThrowsError(try files.createDirectoryWithoutParents(at: path) { directory in
            XCTAssertFalse(try self.files.directoryExistsFollowingLinks(at: directory))
            reachedCreate = true
            try self.files.writeFile(at: directory, content: "Preserved")
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        })
        XCTAssertTrue(reachedCreate)
        XCTAssertEqual(try files.readFile(at: path), "Preserved")
    }
}
