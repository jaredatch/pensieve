import XCTest
@testable import Pensieve

extension ProjectIdentityServiceTests {
    func testMarkerWriteReusesTheFirstRootAdmission() throws {
        let root = TestTemporaryDirectory.path + "IdentityAdmission-\(UUID().uuidString)"
        let files = FileService()
        try files.createDirectory(at: root)
        defer { try? files.deleteDirectory(at: root) }
        let mapped = LinkServiceCanonicalDirectoryFileService(wrapped: files, pathMappings: [], physicalSandbox: root)
        var probes: [String] = []
        mapped.beforeProjectProbe = { probes.append($0) }
        let identity = try ProjectIdentityService(fileService: mapped).identity(forProjectAt: root)
        XCTAssertEqual(identity.kind, .marker)
        XCTAssertEqual(probes, [root], "Marker creation must reuse its root admission")
        let marker = try files.readFile(at: root + "/.pensieve-project")
        XCTAssertEqual(ProjectIdentityService.parseMarkerID(from: marker), identity.key)
    }

    func testMissingIdentityPathThrowsAndCreatesNoAncestors() throws {
        let root = TestTemporaryDirectory.path + "MissingIdentity-\(UUID().uuidString)"
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        let path = root + "/nested/project"
        XCTAssertThrowsError(try ProjectIdentityService(fileService: files).identity(forProjectAt: path)) { error in
            guard case ProjectFolderError.missing(let missing) = error else {
                return XCTFail("Expected missing project folder, got \(error)")
            }
            XCTAssertEqual(missing, path)
        }
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: root))
    }

    func testDeletionImmediatelyBeforeMarkerWriteDoesNotRecreateProject() throws {
        let root = TestTemporaryDirectory.path + "DeletedIdentity-\(UUID().uuidString)"
        let files = FileService()
        let path = root + "/project"
        try files.createDirectory(at: path)
        defer { try? files.deleteDirectory(at: root) }
        let mapped = LinkServiceCanonicalDirectoryFileService(wrapped: files, pathMappings: [], physicalSandbox: root)
        var writes = 0
        mapped.beforeArtifactCreation = { artifact in
            XCTAssertEqual(artifact, path + "/.pensieve-project")
            writes += 1
            try files.deleteDirectory(at: path)
        }
        XCTAssertThrowsError(try ProjectRegistration.makeProject(
            name: "Deleted", path: path, using: ProjectIdentityService(fileService: mapped)
        )) { error in
            guard case ProjectFolderError.missing(let missing) = error else {
                return XCTFail("Expected missing project folder, got \(error)")
            }
            XCTAssertEqual(missing, path)
        }
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: path))
        XCTAssertEqual(try files.listDirectory(at: root), [])
    }
}
