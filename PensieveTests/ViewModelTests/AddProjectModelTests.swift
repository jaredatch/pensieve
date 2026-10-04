import Darwin
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AddProjectModelTests: XCTestCase {
    func testInvalidPathsRefuseRegistrationAndCorrectedPathAddsInSameModel() throws {
        let root = NSTemporaryDirectory() + "AddProjectModel-\(UUID().uuidString)"
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        try files.createDirectory(at: root)
        try files.writeFile(at: root + "/file", content: "Keep")
        try files.createSymlink(at: root + "/dangling", pointingTo: root + "/missing-target")
        try files.createSymlink(at: root + "/file-link", pointingTo: root + "/file")
        let context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        let model = AddProjectModel(fileService: files)
        model.name = "Project"
        let before = try files.listDirectory(at: root).sorted()
        for suffix in ["missing/parent/project", "file", "dangling", "file-link"] {
            model.path = root + "/" + suffix
            XCTAssertFalse(model.isValid)
            XCTAssertTrue(model.hasIdentityError)
            XCTAssertTrue(model.identityMessage?.contains("folder is missing") == true)
            XCTAssertNil(model.makeProject())
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 0)
            XCTAssertEqual(try files.listDirectory(at: root).sorted(), before)
        }
        let valid = root + "/valid"
        try files.createDirectory(at: valid)
        model.path = valid
        XCTAssertTrue(model.isValid)
        XCTAssertFalse(model.hasIdentityError)
        XCTAssertEqual(model.identityMessage, "Marker will be created on Add")
        XCTAssertFalse(files.fileExists(at: valid + "/.pensieve-project"))
        let project = try XCTUnwrap(model.makeProject())
        registerProject(project, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(project.path, valid)
        XCTAssertEqual(project.identityKind, "marker")
        XCTAssertTrue(files.fileExists(at: valid + "/.pensieve-project"))
    }

    func testLookupFailureExplainsReasonAndLinkedDirectoryIsAcceptedAfterCorrection() throws {
        let root = NSTemporaryDirectory() + "AddProjectLookup-\(UUID().uuidString)"
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        try files.createDirectory(at: root + "/directory")
        try files.createSymlink(at: root + "/linked", pointingTo: root + "/directory")
        let mapped = LinkServiceCanonicalDirectoryFileService(wrapped: files, pathMappings: [], physicalSandbox: root)
        mapped.beforeProjectProbe = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
        let model = AddProjectModel(fileService: mapped)
        model.name = "Linked"
        model.path = root + "/linked"
        XCTAssertFalse(model.isValid)
        XCTAssertTrue(model.identityMessage?.contains("couldn't be checked") == true)
        XCTAssertNil(model.makeProject())
        XCTAssertEqual(try files.listDirectory(at: root + "/directory"), [])
        mapped.beforeProjectProbe = nil
        model.refreshIdentityStatus()
        XCTAssertTrue(model.isValid)
        XCTAssertNotNil(model.makeProject())
        XCTAssertTrue(files.fileExists(at: root + "/directory/.pensieve-project"))
    }

    func testDeletionBeforeSubmitKeepsModelAvailableForCorrectedPath() throws {
        let root = NSTemporaryDirectory() + "AddProjectDeletion-\(UUID().uuidString)"
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        try files.createDirectory(at: root + "/project")
        let model = AddProjectModel(fileService: files)
        model.name = "Deleted"
        model.path = root + "/project"
        XCTAssertTrue(model.isValid)
        try files.deleteDirectory(at: model.path)
        XCTAssertNil(model.makeProject())
        XCTAssertFalse(model.isValid)
        XCTAssertTrue(model.identityMessage?.contains("folder is missing") == true)
        XCTAssertEqual(try files.listDirectory(at: root), [])
        try files.createDirectory(at: root + "/corrected")
        model.path = root + "/corrected"
        XCTAssertTrue(model.isValid)
        XCTAssertNotNil(model.makeProject())
    }
}
