import AppKit
import SwiftData
import SwiftUI
import Vision
import XCTest
@testable import Pensieve

@MainActor
final class AddProjectSheetHostTests: XCTestCase {
    func testSheetRefusesMissingPathAndAddsCorrectedDirectoryWithoutRemounting() async throws {
        let h = try CLILibraryFixture()
        defer { h.stop() }
        try await h.start()
        let root = h.root, files = h.files, container = h.context.container
        let model = AddProjectModel(fileService: files)
        model.name = "Hosted Project"
        model.path = root + "/missing/parent/project"
        var created: [Project] = []
        let host = NSHostingView(rootView: AddProjectSheet(
            model: model,
            onCreated: { created.append($0) }
        ).modelContainer(container).background(Color(nsColor: .windowBackgroundColor)))
        let window = mount(host)
        defer { window.close() }
        // Match the words recognition reads reliably. On the CI runner it read the caption as
        // "Project tolder is missing at /Us…", and the path is truncated, so neither is matched.
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "The sheet must render the missing-folder reason",
                            diagnostics: { self.sheetDiagnostics(host, model) }, {
            (try? self.renderedText(in: host).contains { $0.text.contains("missing at") }) == true
        })
        try clickAdd(in: host, window: window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: root + "/missing"))

        try files.createDirectory(at: root + "/valid")
        let pathField = try XCTUnwrap(textFields(in: host).first { $0.stringValue == model.path })
        pathField.stringValue = root + "/valid"
        pathField.delegate?.controlTextDidChange?(Notification(name: NSTextField.textDidChangeNotification, object: pathField))
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "Editing the sheet's path must update its binding") {
            model.path == root + "/valid"
        }
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "The same sheet must render its corrected status",
                            diagnostics: { self.sheetDiagnostics(host, model) }, {
            (try? self.renderedText(in: host).contains { $0.text.contains("Marker will be created on Add") }) == true
        })
        try clickAdd(in: host, window: window)
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "Add must create the corrected project") { created.count == 1 }
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(created.first?.path, root + "/valid")
        XCTAssertTrue(created.first?.modelContext === container.mainContext, "Registration returns the window context model")
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<Project>()).map(\.path), [root + "/valid"])
        let listed = try await h.run(["project", "list"])
        XCTAssertEqual(listed.data?.array?.first?["path"], .string(root + "/valid"))
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
            onCreated: { created.append($0) }).modelContainer(container)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = mount(host)
        defer { window.close() }
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "Initial folder preview") { model.isValid }
        try files.deleteDirectory(at: model.path)
        try clickAdd(in: host, window: window)
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "Failed Add reason") { model.hasIdentityError }
        XCTAssertTrue(created.isEmpty)
        try files.createDirectory(at: model.path)
        try clickAdd(in: host, window: window)
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "Retry same path must add") { created.count == 1 }
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
            onCreated: { created.append($0) }).modelContainer(container)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = mount(host)
        defer { window.close() }
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "Initial caption",
                            diagnostics: { self.sheetDiagnostics(host, model) }, {
            (try? self.renderedText(in: host).contains { $0.text.contains("Marker will be created") }) == true
        })
        let initialHeight = host.fittingSize.height
        let started = expectation(description: "Pending disk probe")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        h.mapped.beforeProjectProbe = { _ in
            guard !Thread.isMainThread else { return }
            started.fulfill()
            // Keep the probe pending through both the start handoff and the hosted render wait.
            _ = release.wait(timeout: .now() + TestWait.heldFixtureTimeoutSeconds)
        }
        model.path = h.project.path
        await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "Current path shows neutral checking text",
                            diagnostics: { self.sheetDiagnostics(host, model) }, {
            (try? self.renderedText(in: host).contains { $0.text.contains("Checking project folder") }) == true
        })
        XCTAssertEqual(host.fittingSize.height, initialHeight, accuracy: 1,
                       "Pending and completed captions reserve the same status-line height")
        XCTAssertFalse(model.canSubmit, "The real sheet's Add binding is disabled while the current probe is pending")
        try clickAdd(in: host, window: window)
        XCTAssertTrue(created.isEmpty, "The pending sheet cannot add a project")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
        release.signal()
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "Latest path replaces checking text") { model.isValid }
        XCTAssertEqual(model.identityMessage, "Marker will be created on Add")
        try clickAdd(in: host, window: window)
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "Completed preview permits Add") { created.count == 1 }
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
                    onCreated: { created.append($0) }).modelContainer(h.context.container)))
            let window = mount(host)
            defer { window.close() }
            await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                                failureMessage: "Native sheet presents") {
                window.attachedSheet?.contentView != nil
            }
            let sheet = try XCTUnwrap(window.attachedSheet)
            sheet.animationBehavior = .none
            try pressReturn(in: sheet, fieldValue: inPath ? model.path : model.name)
            XCTAssertTrue(created.isEmpty)
            await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                                failureMessage: "Injected debounce scheduled") { delay.scheduled == 1 }
            delay.advance()
            await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                                failureMessage: "Return creates exactly one project") {
                created.count == 1
            }
            // A failed creation wait already reports the cause; avoid a cascading dismissal timeout.
            guard created.count == 1 else { return }
            await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                                failureMessage: "Successful queued Return dismisses") {
                !presentation.presented && window.attachedSheet == nil
            }
            XCTAssertEqual(created.count, 1, "Return creates exactly one project")
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 3)
        }
    }

    private func pressReturn(in sheet: NSWindow, fieldValue: String) throws {
        let content = try XCTUnwrap(sheet.contentView)
        let field = try XCTUnwrap(textFields(in: content).first { $0.stringValue == fieldValue })
        sheet.makeFirstResponder(field)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        sheet.sendEvent(event)
    }

    fileprivate func mount(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
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
    // Recognize a 2x render whatever the display's backing scale. On the CI runner's 1x display,
    // recognition misread the status caption ("Marker will he created on Addi").
    fileprivate func renderedText(in host: NSView) throws -> [(text: String, bounds: CGRect)] {
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((bounds.width * 2).rounded(.up)),
            pixelsHigh: Int((bounds.height * 2).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = bounds.size
        host.cacheDisplay(in: bounds, to: bitmap)
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

    // Names what the wait saw, for a run where the caption never appears (the CI runner).
    fileprivate func sheetDiagnostics(_ host: NSView, _ model: AddProjectModel) -> String {
        let recognized = ((try? renderedText(in: host)) ?? []).map(\.text).joined(separator: " | ")
        return "model: checking=\(model.isCheckingIdentity) message=\(model.identityMessage ?? "nil") "
            + "error=\(model.hasIdentityError) directory=\(model.hasProjectDirectory) path=\(model.path); "
            + "host=\(host.bounds.size) scale=\(host.window?.backingScaleFactor ?? 0); recognized=[\(recognized)]"
    }

    fileprivate func clickAdd(in host: NSView, window: NSWindow) throws {
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

    fileprivate func textFields(in root: NSView) -> [NSTextField] {
        views(in: root).compactMap { $0 as? NSTextField }
    }

    fileprivate func views(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(views(in:))
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

extension AddProjectSheetHostTests {
    func testFailedSaveShowsAlertAndKeepsProjectSheetOpen() async throws {
        let windows = NSHashTable<NSWindow>.weakObjects()
        addTeardownBlock { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: .seconds(TestWait.hostedActionTimeoutSeconds))
            while !windows.allObjects.isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let survivors = windows.allObjects.map {
                "\(type(of: $0)): visible=\($0.isVisible), content=\(String(describing: $0.contentView))"
            }
            XCTAssertTrue(survivors.isEmpty, "Failed-save windows survived teardown: " + survivors.joined(separator: "; "))
        }
        try await exerciseFailedSaveSheet(tracking: windows)
        do {
            try await exerciseFailedSaveSheet(tracking: windows, failsBeforeDismissal: true)
            XCTFail("The failure-path probe must throw before dismissing the alert")
        } catch is FailedSaveProbeError { }
    }

    private enum FailedSaveProbeError: Error { case beforeDismissal }

    private func exerciseFailedSaveSheet(tracking windows: NSHashTable<NSWindow>,
                                         failsBeforeDismissal: Bool = false) async throws {
        let h = try CLILibraryFixture(readOnly: true)
        defer { h.stop() }
        let folder = h.root + "/project"
        try h.files.createDirectory(at: folder)
        let model = AddProjectModel(fileService: h.files)
        model.name = "Unsaved project"
        model.path = folder
        var created: [Project] = []
        let presentation = QueuedProjectSheetPresentation()
        let host = NSHostingView(rootView: QueuedProjectSheetHost(presentation: presentation,
            sheet: AddProjectSheet(model: model, onCreated: { created.append($0) })
                .modelContainer(h.context.container)))
        let window = mount(host)
        windows.add(window)
        defer { window.close() }
        var failure: Error?
        do {
            await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                                failureMessage: "Add Project sheet presents") {
                window.attachedSheet?.contentView != nil && model.isValid
            }
            try await checkAndDismissFailedSave(in: window, model: model, tracking: windows) {
                XCTAssertTrue(presentation.presented)
                XCTAssertTrue(created.isEmpty)
                XCTAssertTrue(try h.context.fetch(FetchDescriptor<Project>()).isEmpty)
                if failsBeforeDismissal { throw FailedSaveProbeError.beforeDismissal }
            }
        } catch { failure = error }
        // On any thrown failure, detach AppKit presentations without relying on finding OK.
        if let sheet = window.attachedSheet, let alert = sheet.attachedSheet { sheet.endSheet(alert) }
        presentation.presented = false
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "Failed-save sheet must detach before its host closes") {
            !presentation.presented && window.attachedSheet == nil
        }
        if let failure { throw failure }
    }

    private func checkAndDismissFailedSave(
        in window: NSWindow, model: AddProjectModel, tracking windows: NSHashTable<NSWindow>,
        whilePresented: () throws -> Void
    ) async throws {
        let sheet = try XCTUnwrap(window.attachedSheet)
        windows.add(sheet)
        sheet.animationBehavior = .none
        try pressReturn(in: sheet, fieldValue: model.name)
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "Failed save must present its error alert") {
            sheet.attachedSheet?.contentView != nil
        }
        let alert = try XCTUnwrap(sheet.attachedSheet)
        windows.add(alert)
        alert.animationBehavior = .none
        let labels = textFields(in: try XCTUnwrap(alert.contentView)).map(\.stringValue)
        XCTAssertTrue(labels.contains("Couldn’t Add Project"), labels.joined(separator: " | "))
        XCTAssertTrue(labels.contains { $0.contains("operation couldn’t be completed") || $0.contains("save") },
                      labels.joined(separator: " | "))
        try whilePresented()
        try await dismissSaveAlert(alert, from: sheet)
    }

    private func dismissSaveAlert(_ alert: NSWindow, from sheet: NSWindow) async throws {
        let buttons = views(in: try XCTUnwrap(alert.contentView)).compactMap { $0 as? NSButton }
        let ok = try XCTUnwrap(buttons.first { $0.title == "OK" })
        ok.performClick(nil)
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "OK must dismiss the failed-save alert") {
            sheet.attachedSheet == nil
        }
    }

}
