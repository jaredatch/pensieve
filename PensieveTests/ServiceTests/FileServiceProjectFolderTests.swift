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

    func testOccupiedSymlinkErrorDescribesItsPathAndExistingEntry() {
        let path = root + "/occupied"
        let description = SymlinkCreationError.occupiedPath(path).localizedDescription
        XCTAssertTrue(description.contains(path), "The error must name the occupied path: \(description)")
        XCTAssertTrue(description.contains("already"), "The error must explain the existing entry: \(description)")
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
        XCTAssertThrowsError(try files.createSymlinkWithoutParents(at: link, pointingTo: target)) { error in
            self.assertOccupied(error, path: link)
        }
        XCTAssertEqual(try files.readFile(at: link), "Compiled bytes")
        try files.deleteFile(at: link)
        try files.createSymlinkWithoutParents(at: link, pointingTo: target)
        try files.createSymlinkWithoutParents(at: link, pointingTo: root + "/absent")
        XCTAssertEqual(try files.symlinkTarget(at: link), root + "/absent")
        XCTAssertEqual(try files.readFile(at: target), "Target bytes")
    }

    func testUnmodeledProjectOperationsThrowWithoutMutatingDouble() throws {
        let double = DeployRecordingFileService()
        XCTAssertThrowsError(try UnmodeledProjectFileService().directoryExistsFollowingLinks(at: root))
        XCTAssertThrowsError(try double.createDirectoryWithoutParents(at: root + "/new"))
        XCTAssertThrowsError(try double.writeFileWithoutParents(at: root + "/file", content: "Bytes"))
        XCTAssertThrowsError(try double.createSymlinkWithoutParents(at: root + "/link", pointingTo: root))
        XCTAssertEqual(try files.listDirectory(at: root), [])
        XCTAssertTrue(double.files.isEmpty)
        XCTAssertTrue(double.symlinks.isEmpty)
    }

    func testBothLinkWritersPreserveRealDirectoriesAndTheirChildren() throws {
        for recursive in [false, true] {
            let path = root + "/occupied-\(recursive)"
            try files.writeFile(at: path + "/child", content: "Preserved")
            let identity = files.fileIdentity(at: path, followingLinks: false)
            XCTAssertThrowsError(try replaceLink(path, recursive: recursive)) { error in
                self.assertOccupied(error, path: path)
            }
            XCTAssertEqual(files.fileIdentity(at: path, followingLinks: false), identity)
            XCTAssertEqual(try files.readFile(at: path + "/child"), "Preserved")
        }
    }

    func testBothLinkWritersPreserveRegularFilesAndReplaceLinksWithoutRemovingTargets() throws {
        let directory = root + "/target-directory"
        try files.writeFile(at: directory + "/child", content: "Target bytes")
        for recursive in [false, true] {
            let path = root + "/replace-\(recursive)"
            try files.writeFile(at: path, content: "Replace")
            let identity = files.fileIdentity(at: path, followingLinks: false)
            XCTAssertThrowsError(try replaceLink(path, recursive: recursive)) { error in
                self.assertOccupied(error, path: path)
            }
            XCTAssertEqual(try files.readFile(at: path), "Replace")
            XCTAssertEqual(files.fileIdentity(at: path, followingLinks: false), identity)
            XCTAssertFalse(files.isSymlink(at: path))
            let link = root + "/replace-link-\(recursive)"
            try files.createSymlinkWithoutParents(at: link, pointingTo: directory)
            try replaceLink(link, recursive: recursive)
            XCTAssertEqual(try files.symlinkTarget(at: link), root + "/absent")
            XCTAssertEqual(try files.readFile(at: directory + "/child"), "Target bytes")
        }
    }

    private func assertOccupied(_ error: Error, path: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case SymlinkCreationError.occupiedPath(let actual) = error else {
            return XCTFail("Expected occupiedPath, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(actual, path, file: file, line: line)
    }

    private func replaceLink(_ path: String, recursive: Bool) throws {
        if recursive {
            try files.createSymlink(at: path, pointingTo: root + "/absent")
        } else {
            try files.createSymlinkWithoutParents(at: path, pointingTo: root + "/absent")
        }
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
        })
        XCTAssertTrue(reachedCreate)
        XCTAssertNotNil(identity)
        XCTAssertEqual(files.fileIdentity(at: path, followingLinks: true), identity)
    }

    func testMkdirCheckpointCannotBypassRealCreation() throws {
        let path = root + "/checkpoint-directory"
        var reachedCheckpoint = false
        try files.createDirectoryWithoutParents(at: path) { directory in
            reachedCheckpoint = true
            XCTAssertEqual(directory, path)
            XCTAssertFalse(try self.files.directoryExistsFollowingLinks(at: directory))
        }
        XCTAssertTrue(reachedCheckpoint)
        XCTAssertTrue(try files.directoryExistsFollowingLinks(at: path), "The real mkdir must still run")
    }

    func testFileAppearingImmediatelyBeforeMkdirIsPreservedAndFails() throws {
        let path = root + "/concurrent-file"
        var reachedCreate = false
        XCTAssertThrowsError(try files.createDirectoryWithoutParents(at: path) { directory in
            XCTAssertFalse(try self.files.directoryExistsFollowingLinks(at: directory))
            reachedCreate = true
            try self.files.writeFile(at: directory, content: "Preserved")
        })
        XCTAssertTrue(reachedCreate)
        XCTAssertEqual(try files.readFile(at: path), "Preserved")
    }
}

/// Required operations stay inert; the new project operations deliberately use protocol defaults.
private struct UnmodeledProjectFileService: FileServiceProtocol {
    func readFile(at path: String) throws -> String { throw CocoaError(.featureUnsupported) }
    func writeFile(at path: String, content: String) throws { throw CocoaError(.featureUnsupported) }
    func deleteFile(at path: String) throws { throw CocoaError(.featureUnsupported) }
    func fileExists(at path: String) -> Bool { false }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { false }
    func createDirectory(at path: String) throws { throw CocoaError(.featureUnsupported) }
    func deleteDirectory(at path: String) throws { throw CocoaError(.featureUnsupported) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws { throw CocoaError(.featureUnsupported) }
    func symlinkTarget(at path: String) throws -> String { throw CocoaError(.featureUnsupported) }
    func isSymlink(at path: String) -> Bool { false }
    func isRegularFile(at path: String) -> Bool { false }
    func listDirectory(at path: String) throws -> [String] { throw CocoaError(.featureUnsupported) }
    func contentsHash(at path: String) throws -> String { throw CocoaError(.featureUnsupported) }
}
