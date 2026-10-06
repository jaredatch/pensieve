import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillPreviewLinkHostTests: XCTestCase {
    func testContentPreviewLinkSelectsResolvedPickerFile() async throws {
        var selections: [String] = [], external: [URL] = []
        let fixture = hostTab(markdown: "[Reference](./references/x.md#part)",
                              onSelectFile: { selections.append($0) }, openURL: { external.append($0) })
        defer { fixture.window.close() }
        let link = try await findLink("Reference", in: fixture.host)
        try click(link, in: fixture.window)
        XCTAssertEqual(selections, ["references/x.md"])
        XCTAssertTrue(external.isEmpty)
    }

    func testContentPreviewFileSchemeReachesNeitherSelectionNorExternalOpener() async throws {
        var selections: [String] = [], external: [URL] = []
        let fixture = hostTab(markdown: "[Blocked](file:///tmp/blocked.md) [Web](https://example.com)",
                              onSelectFile: { selections.append($0) }, openURL: { external.append($0) })
        defer { fixture.window.close() }
        let link = try await findLink("Blocked", in: fixture.host)
        try click(link, in: fixture.window)
        XCTAssertEqual(selections, [])
        XCTAssertEqual(external, [])
        try click(try await findLink("Web", in: fixture.host), in: fixture.window)
        XCTAssertEqual(external.map(\.absoluteString), ["https://example.com"], "The same preview must route live clicks")
    }

    func testLinkedFileResetsScrollButPickerSelectionKeepsOffset() async throws {
        let paragraphs = (1...40).map { "Paragraph \($0). Filling the document." }.joined(separator: "\n\n")
        for destination in ["# Reference\n\n" + paragraphs, "# Reference\nTiny."] {
            try await assertFileNavigation(markdown: paragraphs, destination: destination)
        }
    }

    private func assertFileNavigation(markdown: String, destination: String) async throws {
        let selection = PreviewFileSelection()
        let fixture = hostTab(markdown: markdown + "\n\n[Reference](./references/x.md)",
                              onSelectFile: { _ in }, openURL: { _ in XCTFail("File link escaped") },
                              selection: selection, otherMarkdown: destination)
        defer { fixture.window.close() }
        let link = try await findLink("Reference", in: fixture.host)
        let scroller = try XCTUnwrap(views(fixture.host).compactMap { $0 as? NSScrollView }.first)
        let picker = try XCTUnwrap(views(fixture.host).compactMap { $0 as? NSPopUpButton }.first)
        let viewport = fixture.window.convertToScreen(scroller.convert(scroller.bounds, to: nil))
        let bottom = try XCTUnwrap(scroller.documentView).bounds.height - scroller.contentView.bounds.height
        scroller.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroller.reflectScrolledClipView(scroller.contentView)
        XCTAssertGreaterThan(scroller.contentView.bounds.minY, 500)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Scrolled link must be inside the viewport") {
            fixture.host.layoutSubtreeIfNeeded()
            return viewport.contains(link.accessibilityFrame())
        }
        try click(link, in: fixture.window)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Linked reference must load") {
            fixture.host.layoutSubtreeIfNeeded()
            return selection.file == "references/x.md" && picker.titleOfSelectedItem == "references/x.md"
                && self.elements(fixture.host).contains { ($0.accessibilityValue() as? String) == "Reference" }
        }
        let rowTop = viewport.maxY - picker.accessibilityFrame().maxY
        XCTAssertEqual(rowTop, 0, accuracy: 1, "A linked file must put its file row at the viewport top")

        scroller.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scroller.reflectScrolledClipView(scroller.contentView)
        let offset = scroller.contentView.bounds.minY
        let menu = try XCTUnwrap(picker.menu)
        let item = try XCTUnwrap(menu.items.firstIndex { $0.title == "SKILL.md" })
        menu.performActionForItem(at: item)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Picker must select SKILL.md") {
            fixture.host.layoutSubtreeIfNeeded()
            return selection.file == "SKILL.md" && picker.titleOfSelectedItem == "SKILL.md"
        }
        XCTAssertEqual(scroller.contentView.bounds.minY, offset, accuracy: 1,
                       "Picker selection must leave the page offset alone")
    }

    func testAnchorReaderScrollsEnclosingDetailPageToFirstDuplicate() async throws {
        let paragraphs = (1...40).map { "Paragraph \($0). Filling the document." }.joined(separator: "\n\n")
        let markdown = "[Jump](./SKILL.md#authoring-gate) [Missing](#missing)\n\n" + paragraphs
            + "\n\n## Authoring gate\n\nFirst target\n\n" + paragraphs + "\n\n## Authoring gate\n\nSecond target"
        let fixture = hostTab(markdown: markdown, onSelectFile: { _ in }, openURL: { _ in XCTFail("Anchor escaped") })
        defer { fixture.window.close() }
        let jump = try await findLink("Jump", in: fixture.host)
        let scrollView = try XCTUnwrap(views(fixture.host).compactMap { $0 as? NSScrollView }.first)
        XCTAssertEqual(scrollView.contentView.bounds.minY, 0, accuracy: 1)
        let origin = scrollView.contentView.bounds.origin
        try click(try await findLink("Missing", in: fixture.host), in: fixture.window)
        fixture.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollView.contentView.bounds.origin, origin, "Missing anchors do not move the page")
        try click(jump, in: fixture.window)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Anchor must move the enclosing detail scroller") {
            scrollView.contentView.bounds.minY > 100
        }
        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 100, "Same-document file fragment must scroll")
        let first = try XCTUnwrap(elements(fixture.host).first { ($0.accessibilityValue() as? String) == "First target" })
        let frame = first.accessibilityFrame()
        let viewport = scrollView.convert(scrollView.bounds, to: nil)
        let screenViewport = fixture.window.convertToScreen(viewport)
        XCTAssertTrue(screenViewport.intersects(frame), "First duplicate must be visible after jumping")
    }

    private func hostTab(markdown: String, onSelectFile: @escaping (String) -> Void, openURL: @escaping (URL) -> Void,
                         selection: PreviewFileSelection? = nil, otherMarkdown: String = "# Reference")
        -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let base = NSTemporaryDirectory() + "PreviewLinkHost-" + UUID().uuidString
        let files = DeployRecordingFileService()
        files.contents[Constants.pensieveSkillsDir + "/link-test/references/x.md"] = otherMarkdown
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: files, baseDir: base),
                                            fileService: files, manifestRoot: base)
        let skill = Skill(name: "Link test", directoryName: "link-test")
        var snapshot = DetailContentSnapshot(body: markdown)
        snapshot.inventory.files = ["SKILL.md", "references/x.md"].map {
            .init(relativePath: $0, bytes: 20, tokens: 5)
        }
        let tab = PreviewContentHarness(skill: skill, snapshot: snapshot, library: library,
                                        selection: selection ?? PreviewFileSelection(), onSelectFile: { path in
                                            onSelectFile(path)
                                            selection?.file = path
                                        })
        let layout = SkillDetailScrollLayout(skillID: skill.id, contentOwnsScroller: false,
                                             chrome: { Text("Detail header") }, tabContent: { tab })
        let host = NSHostingView(rootView: AnyView(layout.frame(width: 640, height: 480)
            .environment(\.openURL, OpenURLAction { openURL($0); return .handled })))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func findLink(_ title: String, in host: NSView) async throws -> NSAccessibilityProtocol {
        var found: NSAccessibilityProtocol?
        await TestWait.until(timeout: .seconds(3), failureMessage: "Rendered link \(title) must be accessible") {
            host.layoutSubtreeIfNeeded()
            found = self.elements(host).first {
                $0.accessibilityRole() == .link && [$0.accessibilityTitle(), $0.accessibilityLabel()].contains(title)
            }
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func elements(_ root: NSView) -> [NSAccessibilityProtocol] {
        var pending: [Any] = [root] + NSAccessibility.unignoredChildrenForOnlyChild(from: root)
        var visited: Set<ObjectIdentifier> = [], result: [NSAccessibilityProtocol] = []
        while let candidate = pending.popLast() {
            guard let object = candidate as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted,
                  let element = candidate as? NSAccessibilityProtocol else { continue }
            result.append(element)
            pending.append(contentsOf: element.accessibilityChildren() ?? [])
            if let view = candidate as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return result
    }

    private func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(views)
    }

    private func click(_ link: NSAccessibilityProtocol, in window: NSWindow) throws {
        let frame = link.accessibilityFrame()
        XCTAssertGreaterThan(frame.width, 0, "Click must target the rendered link")
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        window.makeKey()
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1))
        }
        // Selectable Markdown text tracks mouse-up inside mouseDown's nested event loop.
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        window.sendEvent(try event(.leftMouseDown))
    }
}

@Observable
private final class PreviewFileSelection {
    var file = "SKILL.md"
}

private struct PreviewContentHarness: View {
    let skill: Skill
    let snapshot: DetailContentSnapshot
    let library: SkillLibraryViewModel
    let selection: PreviewFileSelection
    let onSelectFile: (String) -> Void

    var body: some View {
        let presentation = SkillContentPresentation.resolve(selectedFile: selection.file, requestedMode: .rendered,
                                                             inventory: snapshot.inventory)
        SkillContentTab(skill: skill, snapshot: snapshot, library: library, presentation: presentation,
                        onSelectFile: onSelectFile, onSelectMode: { _ in })
    }
}
