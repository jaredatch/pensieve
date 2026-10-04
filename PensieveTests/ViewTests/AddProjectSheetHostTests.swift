import AppKit
import SwiftData
import SwiftUI
import Vision
import XCTest
@testable import Pensieve

@MainActor
final class AddProjectSheetHostTests: XCTestCase {
    func testSheetRefusesMissingPathAndAddsCorrectedDirectoryWithoutRemounting() async throws {
        let root = NSTemporaryDirectory() + "AddProjectSheetHost-\(UUID().uuidString)"
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
        await TestWait.until(timeout: .seconds(3), failureMessage: "The sheet must render the missing-folder reason") {
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
        let root = NSTemporaryDirectory() + "AddProjectRetry-\(UUID().uuidString)"
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
        await TestWait.until(timeout: .seconds(3), failureMessage: "Initial folder preview") { model.isValid }
        try files.deleteDirectory(at: model.path)
        try clickAdd(in: host, window: window)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Failed Add reason") { model.hasIdentityError }
        XCTAssertTrue(created.isEmpty)
        try files.createDirectory(at: model.path)
        try clickAdd(in: host, window: window)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Retry same path must add") { created.count == 1 }
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Project>()), 1)
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
