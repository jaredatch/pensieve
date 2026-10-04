import Darwin
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AddProjectModelTests: XCTestCase {
    func testTypingDoesNotWaitForDiskAndLatestPreviewWins() async throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        h.mapped.beforeProjectProbe = { path in
            if path == h.project.path { Thread.sleep(forTimeInterval: 0.2) }
        }
        let model = AddProjectModel(fileService: h.mapped)
        model.name = "Project"
        let start = Date()
        model.path = h.project.path
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "Typing must not wait for a slow mount")
        model.path = h.otherProject.path
        await TestWait.until(timeout: .seconds(3), failureMessage: "Latest preview must be accepted") { model.isValid }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.isValid, "An old missing result must not replace the latest preview")
        XCTAssertEqual(model.identityMessage, "Marker will be created on Add")
    }

    func testEmptyPathNeverSubmitsOrShowsAnError() {
        let model = AddProjectModel()
        model.name = "Project"
        model.path = "  "
        XCTAssertNil(model.makeProject())
        XCTAssertNil(model.identityMessage)
        XCTAssertFalse(model.hasIdentityError)
    }

    func testInvalidPathsRefuseRegistrationAndCorrectedPathAddsInSameModel() async throws {
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
            await TestWait.until(timeout: .seconds(3), failureMessage: "Missing preview") { model.identityMessage != nil }
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
        await TestWait.until(timeout: .seconds(3), failureMessage: "Corrected preview") { model.identityMessage != nil }
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

    func testLookupFailureExplainsReasonAndLinkedDirectoryIsAcceptedAfterCorrection() async throws {
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
        await TestWait.until(timeout: .seconds(3), failureMessage: "Lookup preview") { model.identityMessage != nil }
        XCTAssertFalse(model.isValid)
        XCTAssertTrue(model.identityMessage?.contains("couldn't be checked") == true)
        XCTAssertNil(model.makeProject())
        XCTAssertEqual(try files.listDirectory(at: root + "/directory"), [])
        mapped.beforeProjectProbe = nil
        model.refreshIdentityStatus()
        await TestWait.until(timeout: .seconds(3), failureMessage: "Linked preview") { model.identityMessage != nil }
        XCTAssertTrue(model.isValid)
        XCTAssertNotNil(model.makeProject())
        XCTAssertTrue(files.fileExists(at: root + "/directory/.pensieve-project"))
    }

    func testDeletionBeforeSubmitKeepsModelAvailableForCorrectedPath() async throws {
        let root = NSTemporaryDirectory() + "AddProjectDeletion-\(UUID().uuidString)"
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        try files.createDirectory(at: root + "/project")
        let model = AddProjectModel(fileService: files)
        model.name = "Deleted"
        model.path = root + "/project"
        await TestWait.until(timeout: .seconds(3), failureMessage: "Initial preview") { model.identityMessage != nil }
        XCTAssertTrue(model.isValid)
        try files.deleteDirectory(at: model.path)
        XCTAssertNil(model.makeProject())
        XCTAssertFalse(model.isValid)
        XCTAssertTrue(model.identityMessage?.contains("folder is missing") == true)
        XCTAssertEqual(try files.listDirectory(at: root), [])
        try files.createDirectory(at: root + "/corrected")
        model.path = root + "/corrected"
        await TestWait.until(timeout: .seconds(3), failureMessage: "Replacement preview") { model.identityMessage != nil }
        XCTAssertTrue(model.isValid)
        XCTAssertNotNil(model.makeProject())
    }
}
