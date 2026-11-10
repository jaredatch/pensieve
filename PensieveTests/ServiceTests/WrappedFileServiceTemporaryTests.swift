import XCTest
@testable import Pensieve

final class WrappedFileServiceTemporaryTests: XCTestCase {
    func testManifestPublicationThroughWrappersRemovesEmptyNamespace() throws {
        let files = FileService()
        let base = TestTemporaryDirectory.path + "WrappedTemporaryFolders-" + UUID().uuidString
        try files.createDirectory(at: base)
        defer { try? files.deleteDirectory(at: base) }
        let wrappers: [(String, FileServiceProtocol)] = [
            ("ImportReadSpy", ImportReadSpy(files: files)),
            ("FaultyFileService", FaultyFileService(wrapped: files)),
            ("CLIProjectFileService", CLIProjectFileService()),
            ("StoreDirectorySwapFileService", StoreDirectorySwapFileService(
                wrapped: files, directory: base + "/unused", outsideDirectory: base + "/outside"))
        ]
        for (name, wrapper) in wrappers {
            let root = base + "/" + name
            try files.createDirectory(at: root)
            // The production temporary parent is outside the test root; clean any failed assertion's leftovers.
            let namespace = try VendorTemporaryDirectory.namespace(storeRoot: root, fileService: files).parent
            defer { try? files.deleteDirectory(at: namespace) }
            let manifest = ManifestService(fileService: wrapper)
            let snapshot = ManifestSnapshot(schemaVersion: 5,
                categories: [CategoryRecord(name: "Saved category", projectKeys: [], skillSlugs: [])],
                projects: [], skills: [])
            try manifest.write(snapshot, toRoot: root)
            XCTAssertEqual(try ManifestService(fileService: files).read(fromRoot: root).categories.map(\.name),
                           ["Saved category"], name)
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: namespace), name)
        }
    }
}
