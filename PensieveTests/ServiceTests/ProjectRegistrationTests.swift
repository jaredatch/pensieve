import SwiftData
import XCTest
@testable import Pensieve

final class ProjectRegistrationTests: XCTestCase {
    func testRegistrationDoesNotForceCastSavedModels() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try FileService().readFile(at: root.appendingPathComponent("Pensieve/Services/ProjectOperations.swift").path)
        XCTAssertFalse(source.contains("as!"), "Registration must report a failed model cast instead of trapping")
    }

    func testMakeProjectStoresRemoteIdentity() throws {
        let root = TestTemporaryDirectory.path + "ProjectRemote-\(UUID().uuidString)"
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        try files.writeFile(at: root + "/.git/config", content: "[remote \"origin\"]\nurl = git@github.com:owner/repo.git\n")
        let project = try ProjectRegistration.makeProject(name: "Remote", path: root)
        XCTAssertEqual(project.identityKey, "github.com/owner/repo")
        XCTAssertEqual(project.identityKind, "remote")
    }

    func testMakeProjectStoresMarkerIdentity() throws {
        let root = TestTemporaryDirectory.path + "ProjectMarker-\(UUID().uuidString)"
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        let uuid = "11111111-2222-3333-4444-555555555555"
        try files.writeFile(at: root + "/.pensieve-project", content: "id = \(uuid)\nformat_version = 1\n")
        let project = try ProjectRegistration.makeProject(name: "Local", path: root)
        XCTAssertEqual(project.identityKey, uuid)
        XCTAssertEqual(project.identityKind, "marker")
    }

    @MainActor
    func testRegistrationPropagatesIdentityFailure() throws {
        let root = TestTemporaryDirectory.path + "ProjectIdentityFailure-\(UUID().uuidString)"
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        try files.createDirectory(at: root)
        let project = try ProjectRegistration.makeProject(name: "Pending", path: root)
        let mapped = LinkServiceCanonicalDirectoryFileService(wrapped: files, pathMappings: [], physicalSandbox: root)
        mapped.beforeArtifactCreation = { _ in throw StubError.identityUnavailable }
        let context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        XCTAssertThrowsError(try ProjectRegistration.register(project, context: context, files: mapped) {
            context.insert($0)
            try context.save()
            return $0
        }) { error in
            XCTAssertTrue(error is StubError)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertFalse(files.fileExists(at: root + "/.pensieve-project"))
    }
}

private enum StubError: Error {
    case identityUnavailable
}
