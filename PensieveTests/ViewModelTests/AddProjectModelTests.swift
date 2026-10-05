import Darwin
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AddProjectModelTests: XCTestCase {
    func testReplacingPreviewCancelsOldProbeAndShowsCurrentPathCheckingStatus() async throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        try h.files.createDirectory(at: h.otherProject.path + "/.git")
        try h.files.writeFile(at: h.otherProject.path + "/.git/config",
                             content: "[remote \"origin\"]\nurl = https://github.com/owner/previous.git\n")
        try h.files.createDirectory(at: h.root + "/latest")
        let model = AddProjectModel(fileService: h.mapped, previewDelay: {})
        model.name = "Project"
        model.path = h.otherProject.path
        await TestWait.until(timeout: .seconds(3), failureMessage: "Initial preview") { model.isValid }
        XCTAssertEqual(model.identityMessage, "Git remote: github.com/owner/previous")
        let started = expectation(description: "Old probe started")
        let finished = expectation(description: "Old probe released")
        let release = DispatchSemaphore(value: 0)
        let cancellation = PreviewProbeCancellation()
        defer { release.signal() }
        let pendingPath = h.project.path
        h.mapped.beforeProjectProbe = { path in
            guard path == pendingPath else { return }
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            cancellation.record(Task.isCancelled)
            finished.fulfill()
        }
        model.path = h.project.path
        XCTAssertEqual(model.identityMessage, "Checking project folder…",
                       "Pending text describes the current path, never the previous path's identity")
        XCTAssertFalse(model.hasExistingIdentity, "Checking uses the line's neutral existing style")
        await fulfillment(of: [started], timeout: 3)
        model.path = h.root + "/latest"
        XCTAssertEqual(model.identityMessage, "Checking project folder…",
                       "The current path has neutral text until its own probe finishes")
        release.signal()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertTrue(cancellation.wasCancelled, "Replacing a path cancels its previous disk probe")
        await TestWait.until(timeout: .seconds(3), failureMessage: "Latest preview") { model.isValid }
        XCTAssertEqual(model.identityMessage, "Marker will be created on Add")
    }

    func testTypingBurstStartsOneProbeAfterThePause() async throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        let probes = ProjectPreviewProbeRecorder()
        let delay = ProjectPreviewDelay()
        defer { delay.advance() }
        h.mapped.beforeProjectProbe = { probes.record($0) }
        let model = AddProjectModel(fileService: h.mapped, previewDelay: { await delay.wait() })
        model.name = "Project"
        for (index, suffix) in ["p", "pr", "pro", "proj"].enumerated() {
            model.path = h.root + "/" + suffix
            await TestWait.until(timeout: .seconds(1), failureMessage: "Injected debounce scheduled") {
                delay.scheduled == index + 1
            }
        }
        model.path = h.otherProject.path
        await TestWait.until(timeout: .seconds(1), failureMessage: "Final debounce scheduled") { delay.scheduled == 5 }
        XCTAssertEqual(probes.paths, [], "Typing starts no probe until a short pause")
        delay.advance()
        await TestWait.until(timeout: .seconds(3), failureMessage: "Debounced preview") { model.isValid }
        XCTAssertEqual(probes.paths, [h.otherProject.path], "A burst starts only the latest path's probe")
    }

    func testPendingProbeDisablesAddAndCompletedProbeAllowsSamePathRetry() async throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        let model = AddProjectModel(fileService: h.mapped, previewDelay: {})
        model.name = "Project"
        let started = expectation(description: "Current probe started")
        let release = DispatchSemaphore(value: 0)
        let mainProbes = ProjectPreviewProbeRecorder()
        defer { release.signal() }
        h.mapped.beforeProjectProbe = { path in
            if Thread.isMainThread { mainProbes.record(path) } else {
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
        }
        model.path = h.project.path
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(model.isCheckingIdentity)
        XCTAssertFalse(model.canSubmit, "Add is disabled while the current path's probe is pending")
        XCTAssertNil(model.makeProject(), "Return cannot submit during the current probe")
        XCTAssertEqual(mainProbes.paths, [], "Pending submission never probes the disk on the main actor")
        release.signal()
        await TestWait.until(timeout: .seconds(3), failureMessage: "Current preview completed") { !model.isCheckingIdentity }
        XCTAssertTrue(model.canSubmit, "A completed probe permits Add")
        try h.files.deleteDirectory(at: model.path)
        XCTAssertNil(model.makeProject())
        XCTAssertTrue(model.canSubmit, "A failed Add does not fence a completed same-path probe")
        try h.files.createDirectory(at: model.path)
        XCTAssertNotNil(model.makeProject(), "The same path can be tried again after Finder fixes it")
    }

    func testTypingDoesNotWaitForDiskAndLatestPreviewWins() async throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        let started = expectation(description: "Old disk probe started")
        let finished = expectation(description: "Old disk probe released")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        h.mapped.beforeProjectProbe = { path in
            if path == h.project.path {
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
                finished.fulfill()
            }
        }
        let model = AddProjectModel(fileService: h.mapped, previewDelay: {})
        model.name = "Project"
        let start = Date()
        model.path = h.project.path
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "Typing must not wait for a slow mount")
        await fulfillment(of: [started], timeout: 3)
        model.path = h.otherProject.path
        await TestWait.until(timeout: .seconds(3), failureMessage: "Latest preview must be accepted") { model.isValid }
        release.signal()
        await fulfillment(of: [finished], timeout: 3)
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
        let model = AddProjectModel(fileService: files, previewDelay: {})
        model.name = "Project"
        let before = try files.listDirectory(at: root).sorted()
        for suffix in ["missing/parent/project", "file", "dangling", "file-link"] {
            model.path = root + "/" + suffix
            await TestWait.until(timeout: .seconds(3), failureMessage: "Missing preview") { !model.isCheckingIdentity }
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
        await TestWait.until(timeout: .seconds(3), failureMessage: "Corrected preview") { !model.isCheckingIdentity }
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
        let model = AddProjectModel(fileService: mapped, previewDelay: {})
        model.name = "Linked"
        model.path = root + "/linked"
        await TestWait.until(timeout: .seconds(3), failureMessage: "Lookup preview") { !model.isCheckingIdentity }
        XCTAssertFalse(model.isValid)
        XCTAssertTrue(model.identityMessage?.contains("couldn't be checked") == true)
        XCTAssertNil(model.makeProject())
        XCTAssertEqual(try files.listDirectory(at: root + "/directory"), [])
        mapped.beforeProjectProbe = nil
        model.refreshIdentityStatus()
        await TestWait.until(timeout: .seconds(3), failureMessage: "Linked preview") { !model.isCheckingIdentity }
        XCTAssertTrue(model.isValid)
        XCTAssertNotNil(model.makeProject())
        XCTAssertTrue(files.fileExists(at: root + "/directory/.pensieve-project"))
    }

    func testDeletionBeforeSubmitKeepsModelAvailableForCorrectedPath() async throws {
        let root = NSTemporaryDirectory() + "AddProjectDeletion-\(UUID().uuidString)"
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        try files.createDirectory(at: root + "/project")
        let model = AddProjectModel(fileService: files, previewDelay: {})
        model.name = "Deleted"
        model.path = root + "/project"
        await TestWait.until(timeout: .seconds(3), failureMessage: "Initial preview") { !model.isCheckingIdentity }
        XCTAssertTrue(model.isValid)
        try files.deleteDirectory(at: model.path)
        XCTAssertNil(model.makeProject())
        XCTAssertFalse(model.isValid)
        XCTAssertTrue(model.identityMessage?.contains("folder is missing") == true)
        XCTAssertEqual(try files.listDirectory(at: root), [])
        try files.createDirectory(at: root + "/corrected")
        model.path = root + "/corrected"
        await TestWait.until(timeout: .seconds(3), failureMessage: "Replacement preview") { !model.isCheckingIdentity }
        XCTAssertTrue(model.isValid)
        XCTAssertNotNil(model.makeProject())
    }
}

/// NSLock protects the cancellation flag shared by the disk task and the test actor.
private final class PreviewProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool { lock.withLock { cancelled } }
    func record(_ value: Bool) { lock.withLock { cancelled = value } }
}

/// NSLock protects paths recorded by the disk task and read by the test actor.
private final class ProjectPreviewProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var paths: [String] { lock.withLock { recorded } }
    func record(_ path: String) { lock.withLock { recorded.append(path) } }
}
