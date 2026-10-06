import Foundation
import XCTest
@testable import Pensieve

final class StoreDirectorySwapFileServiceTests: XCTestCase {
    func testUninterceptedOperationsKeepRealFilesystemSemantics() throws {
        let files = FileService()
        let root = TestTemporaryDirectory.path + "directory-swap-forwarding-" + UUID().uuidString
        try files.createDirectory(at: root)
        defer { try? files.deleteDirectory(at: root) }
        let wrapped: FileServiceProtocol = StoreDirectorySwapFileService(
            wrapped: files, directory: root + "/victim", outsideDirectory: root + "/outside"
        )
        let path = root + "/bytes"
        let alias = root + "/alias"
        let bytes = Data([0xff, 0, 0x73])
        try files.writeData(at: path, data: bytes)
        try files.createSymlink(at: alias, pointingTo: path)

        XCTAssertEqual(wrapped.realPath(at: alias), files.realPath(at: path), "Resolve the real link target")
        XCTAssertEqual(try wrapped.resolveRealPath(at: alias), files.realPath(at: path))
        XCTAssertEqual(wrapped.fileIdentity(at: alias, followingLinks: true),
                       files.fileIdentity(at: path, followingLinks: true))
        XCTAssertNotNil(wrapped.regularFileMetadata(at: path))
        XCTAssertEqual(try wrapped.entryTypeWithoutFollowingLinks(at: alias), .symlink)
        XCTAssertTrue(try wrapped.entryExistsWithoutFollowingLinks(at: alias))
        XCTAssertEqual(try wrapped.readRegularFileData(at: path, maximumBytes: 3), bytes)
        let headerPath = root + "/header"
        let header = Data("---\nname: fixture\n---\n".utf8)
        try files.writeData(at: headerPath, data: header)
        XCTAssertEqual(try wrapped.readRegularFileHeader(at: headerPath, maximumBytes: 128), header)
        XCTAssertEqual(try wrapped.readRegularFileData(at: path, maximumBytes: 3, containedIn: root), bytes)
        XCTAssertThrowsError(try wrapped.readRegularFileData(at: alias, maximumBytes: 3, containedIn: root),
                             "The wrapper must preserve the real no-follow read boundary")
        XCTAssertNoThrow(try wrapped.writeData(at: path, data: Data([0, 1])))
        XCTAssertEqual(try files.readData(at: path), Data([0, 1]), "Byte writes must reach the real file")
        XCTAssertNoThrow(try wrapped.touchRegularFile(at: path, date: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(files.regularFileMetadata(at: path)?.modificationDate, Date(timeIntervalSince1970: 100))
    }
}
