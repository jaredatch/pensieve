import XCTest
@testable import Pensieve

extension ProjectIdentityServiceTests {
    func testMarkerCleanupFailureKeepsTheSaveError() throws {
        let root = TestTemporaryDirectory.path + "IdentityCleanup-" + UUID().uuidString
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        try files.createDirectory(at: root)
        for previous in [Optional<String>.none, "unfinished marker"] {
            let marker = root + "/.pensieve-project"
            if let previous { try files.writeFile(at: marker, content: previous) }
            let mapped = LinkServiceCanonicalDirectoryFileService(wrapped: files, pathMappings: [], physicalSandbox: root)
            let saveError = NSError(domain: "RegistrationSave", code: 123)
            var cleanupAttempts = 0
            let failCleanup: (String) throws -> Void = { _ in
                cleanupAttempts += 1
                throw CocoaError(.fileWriteNoPermission)
            }
            XCTAssertThrowsError(try ProjectIdentityService(fileService: mapped).withIdentity(forProjectAt: root) { _ in
                mapped.beforeArtifactDeletion = failCleanup
                mapped.beforeArtifactCreation = failCleanup
                throw saveError
            }) { error in
                XCTAssertEqual(error as NSError, saveError)
            }
            XCTAssertEqual(cleanupAttempts, 1)
            XCTAssertNotNil(ProjectIdentityService.parseMarkerID(from: try files.readFile(at: marker)))
            try files.deleteFile(at: marker)
        }
    }

    func testMarkerWriteReusesTheFirstRootAdmission() throws {
        let root = TestTemporaryDirectory.path + "IdentityAdmission-\(UUID().uuidString)"
        let files = FileService()
        try files.createDirectory(at: root)
        defer { try? files.deleteDirectory(at: root) }
        let mapped = LinkServiceCanonicalDirectoryFileService(wrapped: files, pathMappings: [], physicalSandbox: root)
        var probes: [String] = []
        mapped.beforeProjectProbe = { probes.append($0) }
        let identity = try ProjectIdentityService(fileService: mapped).withIdentity(forProjectAt: root) { $0 }
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
        XCTAssertThrowsError(try ProjectIdentityService(fileService: files).withIdentity(forProjectAt: path) { $0 }) { error in
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
        XCTAssertThrowsError(try ProjectIdentityService(fileService: mapped).withIdentity(forProjectAt: path) { $0 }) { error in
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
