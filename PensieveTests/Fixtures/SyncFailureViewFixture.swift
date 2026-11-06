import AppKit
import SwiftData
import SwiftUI
import Vision
import XCTest
@testable import Pensieve

@MainActor
enum SyncFailureViewHost {
    static func mount(_ view: AnyView, size: NSSize = NSSize(width: 500, height: 500)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    static func texts(in view: NSView) -> [String] {
        RenderedViewTestSupport.values(in: view).compactMap { $0 as? Text }.flatMap(RenderedViewTestSupport.strings)
    }

    /// Find a visible label as AddProjectSheetHostTests does, then deliver one real window event pair.
    /// OCR locates the control only; the owning checks observe the production action's result.
    static func clickLabel(_ title: String, in window: NSWindow) throws {
        let content = try XCTUnwrap(window.contentView)
        let bounds = content.bounds
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        content.cacheDisplay(in: bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        let target = title.replacingOccurrences(of: "…", with: "")
        let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        let label = try XCTUnwrap(labels.first { $0.string.contains(target) },
            "Rendered popover labels: \(labels.map(\.string)); content=\(bounds)")
        let range = try XCTUnwrap(label.string.range(of: target))
        let box = try XCTUnwrap(try label.boundingBox(for: range)).boundingBox
        let point = content.convert(NSPoint(x: box.midX * bounds.width,
            y: (content.isFlipped ? 1 - box.midY : box.midY) * bounds.height), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    static func close(_ window: NSWindow) {
        for child in window.childWindows ?? [] {
            child.animationBehavior = .none
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: child.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                _ = child.contentView?.performKeyEquivalent(with: event)
                _ = child.performKeyEquivalent(with: event)
            }
        }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

/// The real runtime and footer share a temporary repository. Synthetic events go through the window;
/// popovers and page arrivals are read only from attached windows and their live rendered content.
@MainActor
final class SyncFailureViewFixture {
    let disk: GitFailureFixture
    let runtime: AppRuntime
    private let popovers = NSHashTable<NSWindow>.weakObjects()
    private(set) var footer: NSWindow?
    var retries = 0
    var settingsOpens = 0
    var sync: SyncModel { runtime.syncModel }
    var saves: ManifestSaveModel { runtime.library.manifestSaves! } // Runtime paths always create the save queue.

    init(reason: String) async throws {
        disk = try GitFailureFixture()
        try disk.seedRepository()
        let sync = SyncModel(git: disk.paths.makeGitService(), root: disk.root, initialState: .error(reason))
        runtime = try AppRuntime(syncModel: sync,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }), paths: disk.paths)
        await runtime.bootstrapTask.value
        sync.installSyncRequest { [weak self] in
            guard let self else { return }
            self.retries += 1
            self.sync.apply(.failed("Retry failed"))
        }
    }

    func mountFooter() {
        footer = SyncFailureViewHost.mount(AnyView(SyncFailureFooterMount(model: sync, saves: saves,
            onOpenSyncSettings: { self.runtime.openSyncSettings(using: { self.settingsOpens += 1 }) })
            .modelContainer(runtime.container)), size: NSSize(width: 320, height: 44))
    }

    func clickFooter() async throws {
        let window = try XCTUnwrap(footer), host = try XCTUnwrap(window.contentView)
        window.makeKeyAndOrderFront(nil)
        await TestWait.until(failureMessage: "Footer line did not render before the click") {
            let texts = SyncFailureViewHost.texts(in: host)
            return ["Sync failed", "Sync now", "Library file damaged", "Repair…"].contains { texts.contains($0) }
        }
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let point = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    func popover() async throws -> NSWindow {
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
            failureMessage: "Click did not attach exactly one popover", diagnostics: {
                "retries=\(self.retries); state=\(self.sync.state); children=\(self.footer?.childWindows?.count ?? 0); "
                    + "text=\(self.footer?.contentView.map(SyncFailureViewHost.texts) ?? [])"
            }, {
            self.footer?.childWindows?.count == 1
        })
        let window = try XCTUnwrap(footer?.childWindows?.first)
        window.animationBehavior = .none
        popovers.add(window)
        XCTAssertTrue(NSStringFromClass(type(of: window)).contains("Popover"))
        return window
    }

    func assertClosed() async {
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
            failureMessage: "Reason popover did not close") { self.footer?.childWindows?.isEmpty != false }
    }

    func press(_ title: String) async throws {
        let window = try await popover()
        try SyncFailureViewHost.clickLabel(title, in: window)
    }

    func cleanup() {
        if let footer { SyncFailureViewHost.close(footer) }
        popovers.allObjects.forEach(SyncFailureViewHost.close)
        popovers.removeAllObjects()
        runtime.commandServer?.stop()
        try? disk.remove()
    }

    static func advice(credential: GitCredential?, ssh: Bool = false) throws -> String {
        let remote = ssh ? "git@example.com:store.git" : "https://fixture.test/store.git"
        return try XCTUnwrap(SyncAuthentication(remote: RemoteURLPolicy.parse(remote), credential: credential).message())
    }
}

/// Match the main window's damage-aware mount, including removing the entire footer on disconnect.
private struct SyncFailureFooterMount: View {
    let model: SyncModel
    let saves: ManifestSaveModel
    let onOpenSyncSettings: () -> Void
    var body: some View {
        if model.showsFooter(saves: saves) {
            SyncStatusView(model: model, saves: saves, onResolve: {}, onOpenSyncSettings: onOpenSyncSettings)
        }
    }
}
