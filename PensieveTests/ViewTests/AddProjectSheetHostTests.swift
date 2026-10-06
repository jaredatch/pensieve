import AppKit
import SwiftData
import SwiftUI
import Vision
import XCTest
@testable import Pensieve

@MainActor
final class AddProjectSheetHostTests: XCTestCase {
    func testSheetRefusesMissingPathAndAddsCorrectedDirectoryWithoutRemounting() async throws {
        let root = TestTemporaryDirectory.path + "AddProjectSheetHost-\(UUID().uuidString)"
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        try files.createDirectory(at: root)
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AddProjectModel(fileService: files)
        model.name = "Hosted Project"
        model.path = root + "/missing/parent/project"
        var created: [Project] = []
        let host = NSHostingView(rootView: AddProjectSheet(
            model: model, manifestService: ManifestService(fileService: files), manifestRoot: root + "/store",
            onCreated: { created.append($0) }
        ).modelContainer(container).background(Color(nsColor: .windowBackgroundColor)))
        let window = mount(host)
        defer { window.close() }
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                            failureMessage: "The sheet must render the missing-folder reason") {
            (try? self.renderedText(in: host).contains { $0.text.contains("Project folder is missing") }) == true
        }
        try clickAdd(in: host, window: window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: root + "/missing"))

        try files.createDirectory(at: root + "/valid")
        let pathField = try XCTUnwrap(textFields(in: host).first { $0.stringValue == model.path })
        pathField.stringValue = root + "/valid"
        pathField.delegate?.controlTextDidChange?(Notification(name: NSTextField.textDidChangeNotification, object: pathField))
        await TestWait.until(timeout: .seconds(3), failureMessage: "Editing the sheet's path must update its binding") {
            model.path == root + "/valid"
        }
        await TestWait.until(timeout: .seconds(3), failureMessage: "The same sheet must render its corrected status") {
            (try? self.renderedText(in: host).contains { $0.text.contains("Marker will be created on Add") }) == true
        }
        try clickAdd(in: host, window: window)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Add must create the corrected project") { created.count == 1 }
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(created.first?.path, root + "/valid")
        XCTAssertTrue(files.fileExists(at: root + "/valid/.pensieve-project"))
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: root + "/missing"))
    }

    func testFailedAddCanRetrySamePathAfterFinderRestoresFolder() async throws {
        let root = TestTemporaryDirectory.path + "AddProjectRetry-\(UUID().uuidString)"
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        try files.createDirectory(at: root + "/project")
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AddProjectModel(fileService: files)
        model.name = "Retry"
        model.path = root + "/project"
        var created: [Project] = []
        let host = NSHostingView(rootView: AddProjectSheet(model: model,
            manifestService: ManifestService(fileService: files), manifestRoot: root + "/store",
            onCreated: { created.append($0) }).modelContainer(container)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = mount(host)
        defer { window.close() }
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                            failureMessage: "Initial folder preview") { model.isValid }
        try files.deleteDirectory(at: model.path)
        try clickAdd(in: host, window: window)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Failed Add reason") { model.hasIdentityError }
        XCTAssertTrue(created.isEmpty)
        try files.createDirectory(at: model.path)
        try clickAdd(in: host, window: window)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Retry same path must add") { created.count == 1 }
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Project>()), 1)
    }

    func testPendingProbeShowsCheckingWithoutHeightChangeAndDisablesAdd() async throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AddProjectModel(fileService: h.mapped)
        model.name = "Pending"
        model.path = h.otherProject.path
        var created: [Project] = []
        let host = NSHostingView(rootView: AddProjectSheet(model: model,
            manifestService: ManifestService(fileService: h.files), manifestRoot: h.root + "/store",
            onCreated: { created.append($0) }).modelContainer(container)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = mount(host)
        defer { window.close() }
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                            failureMessage: "Initial caption") {
            (try? self.renderedText(in: host).contains { $0.text.contains("Marker will be created") }) == true
        }
        let initialHeight = host.fittingSize.height
        let started = expectation(description: "Pending disk probe")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        h.mapped.beforeProjectProbe = { _ in
            guard !Thread.isMainThread else { return }
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        model.path = h.project.path
        await fulfillment(of: [started], timeout: 3)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Current path shows neutral checking text") {
            (try? self.renderedText(in: host).contains { $0.text.contains("Checking project folder") }) == true
        }
        XCTAssertEqual(host.fittingSize.height, initialHeight, accuracy: 1,
                       "Pending and completed captions reserve the same status-line height")
        XCTAssertFalse(model.canSubmit, "The real sheet's Add binding is disabled while the current probe is pending")
        try clickAdd(in: host, window: window)
        XCTAssertTrue(created.isEmpty, "The pending sheet cannot add a project")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
        release.signal()
        await TestWait.until(timeout: .seconds(3), failureMessage: "Latest path replaces checking text") { model.isValid }
        XCTAssertEqual(model.identityMessage, "Marker will be created on Add")
        try clickAdd(in: host, window: window)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Completed preview permits Add") { created.count == 1 }
    }

    func testReturnFromEitherFieldDuringDebounceRegistersOnceAndDismissesSheet() async throws {
        for inPath in [false, true] {
            let h = try ProjectFolderCallerHarness()
            defer { h.cleanup() }
            let delay = ProjectPreviewDelay()
            defer { delay.advance() }
            let model = AddProjectModel(fileService: h.mapped, previewDelay: { await delay.wait() })
            model.name = "Queued"
            model.path = h.otherProject.path
            let presentation = QueuedProjectSheetPresentation()
            var created: [Project] = []
            let host = NSHostingView(rootView: QueuedProjectSheetHost(presentation: presentation,
                sheet: AddProjectSheet(model: model,
                    manifestService: ManifestService(fileService: h.files), manifestRoot: h.root + "/store",
                    onCreated: { created.append($0) }).modelContainer(h.context.container)))
            let window = mount(host)
            defer { window.close() }
            await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                                failureMessage: "Native sheet presents") {
                window.attachedSheet?.contentView != nil
            }
            let sheet = try XCTUnwrap(window.attachedSheet)
            let content = try XCTUnwrap(sheet.contentView)
            let value = inPath ? model.path : model.name
            let field = try XCTUnwrap(textFields(in: content).first { $0.stringValue == value })
            sheet.makeFirstResponder(field)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36))
            sheet.sendEvent(event)
            XCTAssertTrue(created.isEmpty)
            await TestWait.until(timeout: .seconds(1), failureMessage: "Injected debounce scheduled") { delay.scheduled == 1 }
            delay.advance()
            await TestWait.until(timeout: .seconds(3), failureMessage: "Return creates exactly one project") {
                created.count == 1
            }
            await TestWait.until(timeout: .seconds(3), failureMessage: "Successful queued Return dismisses") {
                !presentation.presented && window.attachedSheet == nil
            }
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 3)
            XCTAssertEqual(created.count, 1)
        }
    }

    private func mount(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    // SwiftUI's virtual accessibility children are absent in this in-process host. Recognize
    // the actual live render, then send mouse events at Add's rendered position.
    private func renderedText(in host: NSView) throws -> [(text: String, bounds: CGRect)] {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).flatMap { observation -> [(String, CGRect)] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            var result = [(candidate.string, observation.boundingBox)]
            if candidate.string != "Add", candidate.string.hasSuffix("Add"),
               let range = candidate.string.range(of: "Add", options: .backwards),
               let word = try? candidate.boundingBox(for: range) {
                result.append(("Add", word.boundingBox))
            }
            return result
        }
    }

    private func clickAdd(in host: NSView, window: NSWindow) throws {
        let add = try XCTUnwrap(renderedText(in: host).filter { $0.text == "Add" }
            .min { $0.bounds.midY < $1.bounds.midY })
        let bounds = host.bounds
        let y = host.isFlipped ? 1 - add.bounds.midY : add.bounds.midY
        let point = host.convert(NSPoint(x: add.bounds.midX * bounds.width, y: y * bounds.height), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }
    }

    private func textFields(in root: NSView) -> [NSTextField] {
        [root].compactMap { $0 as? NSTextField } + root.subviews.flatMap(textFields(in:))
    }
}

@Observable
private final class QueuedProjectSheetPresentation {
    var presented = true
}

private struct QueuedProjectSheetHost<Content: View>: View {
    @Bindable var presentation: QueuedProjectSheetPresentation
    let sheet: Content
    var body: some View {
        Text("Projects").sheet(isPresented: $presentation.presented) { sheet }
    }
}
