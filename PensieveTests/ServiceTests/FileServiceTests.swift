import Darwin
import XCTest
@testable import Pensieve

final class FileServiceTests: XCTestCase {
    private var fileService: FileService!
    private var tempDir: String!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveFileServiceTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testReplaceItemPreservesDanglingDestinationAndSourceOnFailure() throws {
        let source = tempDir + "/replacement"
        let destination = tempDir + "/dangling"
        let target = tempDir + "/missing"
        try fileService.writeFile(at: source, content: "replacement bytes")
        try fileService.createSymlink(at: destination, pointingTo: target)
        XCTAssertThrowsError(try fileService.replaceItem(at: destination, with: source))
        XCTAssertTrue(fileService.isSymlink(at: destination))
        XCTAssertEqual(try fileService.symlinkTarget(at: destination), target)
        XCTAssertEqual(try fileService.readFile(at: source), "replacement bytes")
        XCTAssertFalse(fileService.fileExists(at: target))
    }

    func testCopyFileFailurePreservesDestinationAndCleansTemporaryFile() throws {
        let source = tempDir + "/source"
        let destination = tempDir + "/destination"
        try fileService.writeData(at: source, data: Data(repeating: 42, count: 128 * 1_024))
        try fileService.writeFile(at: destination, content: "original")
        let identity = fileService.fileIdentity(at: destination, followingLinks: false)
        let entries = try fileService.listDirectory(at: tempDir).sorted()
        let (descriptor, status) = try FileService.openRegularFile(at: source)
        defer { close(descriptor) }
        var chunks = 0
        // Inject failure in the descriptor helper that the public copyFile entry uses.
        XCTAssertThrowsError(try DescriptorFileCopy.copy(from: descriptor, status: status,
                                                        sourcePath: source, to: destination, options: .init()) { _ in
            chunks += 1
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertEqual(chunks, 1)
        XCTAssertTrue(try fileService.readData(at: destination) == Data("original".utf8))
        XCTAssertEqual(fileService.fileIdentity(at: destination, followingLinks: false), identity)
        XCTAssertEqual(try fileService.listDirectory(at: tempDir).sorted(), entries)
    }

    func testSuccessfulCopyDoesNotUnlinkAReusedTemporaryNameAfterRename() throws {
        let source = tempDir + "/source"
        let destination = tempDir + "/destination"
        try fileService.writeFile(at: source, content: "copied bytes")
        try fileService.writeFile(at: destination, content: "previous bytes")
        let (descriptor, status) = try FileService.openRegularFile(at: source)
        defer { close(descriptor) }
        var reused: String?
        var identity: FileIdentity?
        try DescriptorFileCopy.copy(from: descriptor, status: status, sourcePath: source, to: destination,
                                    options: .init(renameFile: { temporary, target in
            let result = Darwin.rename(temporary, target)
            guard result == 0 else { return result }
            reused = temporary
            do { try self.fileService.writeFile(at: temporary, content: "new owner's bytes") } catch {
                XCTFail("Fixture setup: \(error)")
            }
            identity = self.fileService.fileIdentity(at: temporary, followingLinks: false)
            return result
        }))
        let temporary = try XCTUnwrap(reused, "The successful rename must run")
        XCTAssertEqual(try fileService.readFile(at: destination), "copied bytes")
        XCTAssertTrue(fileService.fileExists(at: temporary), "Success must not unlink a name reused after rename")
        XCTAssertEqual(fileService.fileIdentity(at: temporary, followingLinks: false), try XCTUnwrap(identity))
        XCTAssertEqual(try fileService.readFile(at: temporary), "new owner's bytes")
    }

    func testCopyFileReplacesSymlinkWithoutChangingItsTarget() throws {
        let source = tempDir + "/source"
        let target = tempDir + "/target"
        let destination = tempDir + "/destination"
        try fileService.writeExecutableFile(at: source, content: "new bytes")
        try fileService.writeFile(at: target, content: "target bytes")
        for dangling in [false, true] {
            if fileService.fileExists(at: destination) { try fileService.deleteFile(at: destination) }
            try fileService.createSymlink(at: destination, pointingTo: dangling ? tempDir + "/absent" : target)
            XCTAssertNoThrow(try fileService.copyFile(at: source, to: destination))
            XCTAssertTrue(fileService.isRegularFile(at: destination))
            XCTAssertEqual(try fileService.readFile(at: destination), "new bytes")
            XCTAssertTrue(fileService.isUserExecutableFile(at: destination))
            XCTAssertEqual(try fileService.readFile(at: target), "target bytes")
        }
    }

    func testCopyFileReplacesHardLinkedDestinationWithoutOverwritingOtherLinks() throws {
        let source = tempDir + "/source"
        let destination = tempDir + "/destination"
        let other = tempDir + "/other"
        try fileService.writeFile(at: source, content: "new bytes")
        try fileService.writeFile(at: destination, content: "original")
        try FileManager.default.linkItem(atPath: destination, toPath: other)
        let identity = fileService.fileIdentity(at: other, followingLinks: false)
        try fileService.copyFile(at: source, to: destination)
        XCTAssertEqual(try fileService.readFile(at: destination), "new bytes")
        XCTAssertEqual(try fileService.readFile(at: other), "original")
        XCTAssertEqual(fileService.fileIdentity(at: other, followingLinks: false), identity)
        XCTAssertNotEqual(fileService.fileIdentity(at: destination, followingLinks: false), identity)
    }

    func testIsExecutableFileReturnsTrueForExecutableRegularFile() throws {
        let path = tempDir + "/tool"
        try "echo ok".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

        XCTAssertTrue(fileService.isExecutableFile(at: path))
    }

    func testIsExecutableFileReturnsFalseForPlainFile() throws {
        let path = tempDir + "/plain"
        try "not executable".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)

        XCTAssertFalse(fileService.isExecutableFile(at: path))
    }

    func testIsExecutableFileReturnsFalseForDirectory() throws {
        let path = tempDir + "/directory"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        XCTAssertFalse(fileService.isExecutableFile(at: path))
    }

    func testIsExecutableFileReturnsFalseForMissingPath() {
        XCTAssertFalse(fileService.isExecutableFile(at: tempDir + "/missing"))
    }

    /// PLAN-30 / 30.2 review: identity is the volume's, not the spelling's — a link and its
    /// target share it only when the link is followed; nothing there means nil.
    func testFileIdentityFollowsLinksOnlyWhenAsked() throws {
        let target = tempDir + "/target"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: tempDir + "/link", withDestinationPath: target)
        let service = FileService()

        let targetIdentity = try XCTUnwrap(service.fileIdentity(at: target, followingLinks: false))
        XCTAssertEqual(service.fileIdentity(at: tempDir + "/link", followingLinks: true), targetIdentity)
        XCTAssertNotEqual(service.fileIdentity(at: tempDir + "/link", followingLinks: false), targetIdentity)
        XCTAssertNil(service.fileIdentity(at: tempDir + "/absent", followingLinks: false))
    }

    /// `realPath` resolves every link and keeps `/private` (Foundation's resolvers strip it); a path
    /// that does not exist comes back as given.
    func testRealPathResolvesLinksAndKeepsPrivate() throws {
        let target = tempDir + "/target"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: tempDir + "/link", withDestinationPath: target)
        let service = FileService()

        XCTAssertEqual(service.realPath(at: tempDir + "/link"), service.realPath(at: target))
        XCTAssertEqual(service.realPath(at: "/var"), "/private/var")
        XCTAssertEqual(service.realPath(at: tempDir + "/absent"), tempDir + "/absent")
        XCTAssertEqual(try service.resolveRealPath(at: tempDir + "/link"), try service.resolveRealPath(at: target))
        XCTAssertEqual(try service.resolveRealPath(at: "/var"), "/private/var")
        XCTAssertThrowsError(try service.resolveRealPath(at: tempDir + "/absent")) {
            XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual(($0 as NSError).code, Int(ENOENT))
        }
        XCTAssertEqual(try service.entryTypeWithoutFollowingLinks(at: target), .directory)
        XCTAssertEqual(try service.entryTypeWithoutFollowingLinks(at: tempDir + "/link"), .symlink)
        XCTAssertNil(try service.entryTypeWithoutFollowingLinks(at: tempDir + "/absent"))
        try service.writeFile(at: tempDir + "/regular", content: "body")
        XCTAssertEqual(try service.entryTypeWithoutFollowingLinks(at: tempDir + "/regular"), .regular)
    }

    /// Protects 39.1-h and 39.1-k: cache metadata is available only for a regular leaf, never a link.
    func testRegularFileMetadataReturnsSizeAndModificationDateWithoutFollowingLinks() throws {
        let path = tempDir + "/entry"
        let link = tempDir + "/link"
        try "cache".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)

        let metadata = try XCTUnwrap(fileService.regularFileMetadata(at: path))

        XCTAssertEqual(metadata.byteCount, 5)
        XCTAssertNil(fileService.regularFileMetadata(at: link))
    }

    /// Protects 39.1-h and 39.1-k: recency touches update regular files and refuse linked leaves.
    func testTouchRegularFileUpdatesModificationDateAndRefusesLinks() throws {
        let path = tempDir + "/entry"
        let link = tempDir + "/link"
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        try "cache".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)

        try fileService.touchRegularFile(at: path, date: date)

        let metadata = try XCTUnwrap(fileService.regularFileMetadata(at: path))
        XCTAssertEqual(metadata.modificationDate.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertThrowsError(try fileService.touchRegularFile(at: link, date: date.addingTimeInterval(1)))
    }

    /// Protects 39.1-h: protocol defaults for metadata and touch are inert for test doubles.
    func testRegularFileMetadataAndTouchDefaultsDoNotInspectTheHostFileSystem() throws {
        let path = tempDir + "/entry"
        try "cache".write(toFile: path, atomically: true, encoding: .utf8)
        let original = try XCTUnwrap(fileService.regularFileMetadata(at: path)?.modificationDate)
        let double: FileServiceProtocol = InertMetadataFileService()

        XCTAssertNil(double.regularFileMetadata(at: path))
        try double.touchRegularFile(at: path, date: original.addingTimeInterval(-10_000))

        let unchanged = try XCTUnwrap(fileService.regularFileMetadata(at: path)?.modificationDate)
        XCTAssertEqual(unchanged.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 0.001)
    }

    /// Protects 39.1-h: a rounded billionth is carried instead of passing `futimens` an invalid value.
    func testTouchTimestampCarriesOneBillionNanoseconds() {
        let timestamp = FileService.normalizedTimespec(seconds: 41, nanoseconds: 1_000_000_000)

        XCTAssertEqual(timestamp.tv_sec, 42)
        XCTAssertEqual(timestamp.tv_nsec, 0)
    }

    func testUnmodeledBoundedReadDefaultNeverLoadsHostBytes() throws {
        let path = tempDir + "/unmodeled"
        try fileService.writeFile(at: path, content: "Host bytes must not escape through a double")
        let double: FileServiceProtocol = InertMetadataFileService()
        for candidate in [path, tempDir + "/missing"] {
            XCTAssertThrowsError(try double.readRegularFileData(at: candidate, maximumBytes: 1_024)) { error in
                let failure = error as NSError
                XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                XCTAssertEqual(failure.code, CocoaError.featureUnsupported.rawValue,
                               "An unmodeled read must refuse without inspecting \(candidate)")
            }
        }
    }

    func testUnmodeledContainedReadDefaultRefusesHostBytes() throws {
        let path = tempDir + "/contained"
        try fileService.writeFile(at: path, content: "Host bytes must stay behind the modeled boundary")
        let double: FileServiceProtocol = InertMetadataFileService()
        XCTAssertThrowsError(try double.readRegularFileData(at: path, maximumBytes: 1_024, containedIn: tempDir)) { error in
            XCTAssertEqual((error as NSError).code, CocoaError.featureUnsupported.rawValue)
        }
    }
}

private struct InertMetadataFileService: FileServiceProtocol {
    func readFile(at path: String) throws -> String { "" }
    func writeFile(at path: String, content: String) throws {}
    func deleteFile(at path: String) throws {}
    func fileExists(at path: String) -> Bool { false }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { false }
    func createDirectory(at path: String) throws {}
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
    func symlinkTarget(at path: String) throws -> String { "" }
    func isSymlink(at path: String) -> Bool { false }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String { "" }
}
