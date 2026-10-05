import Foundation
import XCTest
@testable import Pensieve

@MainActor
final class AddProjectRoundOneTests: XCTestCase {
    func testTildeExpansionIsProbedAndSavedAsAbsolute() async throws {
        let files = DeployRecordingFileService()
        let expanded = NSHomeDirectory() + "/code/app"
        files.directories.insert(expanded)
        let identities = AddProjectPathIdentity()
        let model = AddProjectModel(fileService: files, identityService: identities, previewDelay: {})
        model.name = "App"
        model.path = "  ~/code/app  "
        await TestWait.until(timeout: .seconds(3), failureMessage: "Expanded path preview") { !model.isCheckingIdentity }
        XCTAssertTrue(model.isValid)
        XCTAssertEqual(identities.previewPaths, [expanded])
        XCTAssertEqual(model.makeProject()?.path, expanded)
        XCTAssertEqual(identities.addPaths, [expanded])
    }

    func testRelativePathIsRefusedWithoutAnyProbeOrAdd() async throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        let identities = AddProjectPathIdentity()
        let probed = expectation(description: "No relative path probe")
        probed.isInverted = true
        let files = FileService(directoryProbe: { _ in probed.fulfill(); return false })
        let model = AddProjectModel(fileService: files, identityService: identities, previewDelay: {})
        model.name = "App"
        model.path = "code/app"
        await TestWait.until(timeout: .seconds(3), failureMessage: "Relative refusal") { !model.isCheckingIdentity }
        XCTAssertEqual(model.identityMessage, "Enter a full path, starting with / or ~/")
        XCTAssertFalse(model.canSubmit)
        XCTAssertNil(model.makeProject())
        XCTAssertTrue(identities.previewPaths.isEmpty)
        XCTAssertTrue(identities.addPaths.isEmpty)
        model.path = "~fixture/code"
        XCTAssertEqual(model.identityMessage, "Enter a full path, starting with / or ~/")
        XCTAssertFalse(model.canSubmit)
        XCTAssertNil(model.makeProject())
        XCTAssertTrue(identities.previewPaths.isEmpty)
        XCTAssertTrue(identities.addPaths.isEmpty)
        await fulfillment(of: [probed], timeout: 0.05)
    }

    func testUnchangedPathKeepsCompletedStatusAndStartsNoProbe() async throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        let delay = ProjectPreviewDelay()
        defer { delay.advance() }
        let model = AddProjectModel(fileService: h.mapped, previewDelay: { await delay.wait() })
        model.name = "App"
        model.path = h.otherProject.path
        await TestWait.until(timeout: .seconds(1), failureMessage: "Initial debounce") { delay.scheduled == 1 }
        delay.advance()
        await TestWait.until(timeout: .seconds(3), failureMessage: "Initial preview") { model.isValid }
        let message = model.identityMessage
        model.path = h.otherProject.path
        XCTAssertEqual(model.identityMessage, message)
        XCTAssertTrue(model.canSubmit)
        XCTAssertFalse(model.isCheckingIdentity)
        delay.advance()
        XCTAssertEqual(delay.scheduled, 1)
    }

    func testReturnDuringDebounceAddsOnceAfterAdmission() async throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        let delay = ProjectPreviewDelay()
        defer { delay.advance() }
        let model = AddProjectModel(fileService: h.mapped, previewDelay: { await delay.wait() })
        model.name = "App"
        model.path = h.otherProject.path
        var added: [Project] = []
        model.submit { added.append($0) }
        model.submit { added.append($0) }
        XCTAssertTrue(added.isEmpty)
        await TestWait.until(timeout: .seconds(1), failureMessage: "Debounce scheduled") { delay.scheduled == 1 }
        delay.advance()
        await TestWait.until(timeout: .seconds(3), failureMessage: "Queued Return creates one project") { added.count == 1 }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.path, h.otherProject.path)
    }

    func testReturnDuringProbeAddsOnceAfterAdmission() async throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        let started = expectation(description: "Probe started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        h.mapped.beforeProjectProbe = { _ in
            if !Thread.isMainThread { started.fulfill(); _ = release.wait(timeout: .now() + 3) }
        }
        let model = AddProjectModel(fileService: h.mapped, previewDelay: {})
        model.name = "App"
        model.path = h.otherProject.path
        await fulfillment(of: [started], timeout: 3)
        var added: [Project] = []
        model.submit { added.append($0) }
        release.signal()
        await TestWait.until(timeout: .seconds(3), failureMessage: "Probe completion submits Return") { added.count == 1 }
        XCTAssertEqual(added.count, 1)
    }

    func testQueuedReturnIsCancelledByEitherEditAndRefusedPath() async throws {
        for edit in ["name", "path", "refused"] {
            let h = try ProjectFolderCallerHarness()
            defer { h.cleanup() }
            let delay = ProjectPreviewDelay()
            defer { delay.advance() }
            let model = AddProjectModel(fileService: h.mapped, previewDelay: { await delay.wait() })
            model.name = "App"
            model.path = edit == "refused" ? h.project.path : h.otherProject.path
            await TestWait.until(timeout: .seconds(1), failureMessage: "Debounce scheduled") { delay.scheduled == 1 }
            var added: [Project] = []
            model.submit { added.append($0) }
            if edit == "name" { model.name = "Changed" }
            if edit == "path" {
                model.path = h.project.path
                await TestWait.until(timeout: .seconds(1), failureMessage: "Edited debounce scheduled") { delay.scheduled == 2 }
            }
            delay.advance()
            await TestWait.until(timeout: .seconds(3), failureMessage: "Preview completed") { !model.isCheckingIdentity }
            XCTAssertTrue(added.isEmpty)
            if edit != "name" { XCTAssertTrue(model.identityMessage?.contains("folder is missing") == true) }
        }
    }
}

/// Lock-protected path capture for the detached preview and main-actor submission; no host I/O.
private final class AddProjectPathIdentity: ProjectIdentityServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var previews: [String] = []
    private var adds: [String] = []
    var previewPaths: [String] { lock.withLock { previews } }
    var addPaths: [String] { lock.withLock { adds } }
    func peekIdentity(forProjectAt path: String) -> ProjectIdentity? {
        lock.withLock { previews.append(path) }
        return ProjectIdentity(kind: .remote, key: "github.com/owner/app")
    }
    func identity(forProjectAt path: String) throws -> ProjectIdentity {
        lock.withLock { adds.append(path) }
        return ProjectIdentity(kind: .remote, key: "github.com/owner/app")
    }
}
