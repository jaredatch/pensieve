import AppKit
import Observation
import SwiftUI
import WebKit
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
        await TestWait.until(timeout: .seconds(3), failureMessage: "Resolved file link must reach its owner") {
            !selections.isEmpty
        }
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

    func testLongFileLinkPutsFileRowAtViewportTop() async throws {
        let selection = PreviewFileSelection()
        let fixture = navigationFixture(selection: selection, destination: "# Reference\n\n" + paragraphs)
        defer { fixture.window.close() }
        try await followReference(in: fixture, selection: selection)
        let scroller = try pageScroller(in: fixture.host)
        let row = try filePicker(in: fixture.host)
        let rowTop = viewport(of: scroller, in: fixture.window).maxY - row.accessibilityFrame().maxY
        XCTAssertEqual(rowTop, 0, accuracy: 1, "Long linked file must put its file row at the viewport top")
    }

    func testShortFileLinkHasTheSameScrollRangeAsPickerSelection() async throws {
        let linkedSelection = PreviewFileSelection()
        let linked = navigationFixture(selection: linkedSelection, destination: "# Reference\nTiny.")
        defer { linked.window.close() }
        try await followReference(in: linked, selection: linkedSelection)
        let linkedScroller = try pageScroller(in: linked.host)
        let row = try filePicker(in: linked.host)
        XCTAssertTrue(viewport(of: linkedScroller, in: linked.window).contains(row.accessibilityFrame()),
                      "Short linked file must leave the file row inside the viewport")

        let pickedSelection = PreviewFileSelection()
        let picked = navigationFixture(selection: pickedSelection, destination: "# Reference\nTiny.")
        defer { picked.window.close() }
        try pickFile("references/x.md", in: picked.host)
        await waitForReference(in: picked.host, selection: pickedSelection)
        let pickedRange = try scrollRange(of: pageScroller(in: picked.host))
        XCTAssertEqual(pickedRange, 0, accuracy: 1, "Short picked file must fit without page scrolling")
        XCTAssertEqual(scrollRange(of: linkedScroller), pickedRange, accuracy: 1,
                       "Link and picker selection must give a short file the same scroll range")
    }

    func testPickerSelectionKeepsThePageOffset() async throws {
        let selection = PreviewFileSelection()
        let fixture = navigationFixture(selection: selection, destination: "# Reference\n\n" + paragraphs)
        defer { fixture.window.close() }
        try await followReference(in: fixture, selection: selection)
        let scroller = try pageScroller(in: fixture.host)
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scroller.reflectScrolledClipView(scroller.contentView)
        XCTAssertEqual(scroller.contentView.bounds.minY, 200, accuracy: 1)
        try pickFile("SKILL.md", in: fixture.host)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Picker must select SKILL.md") {
            fixture.host.layoutSubtreeIfNeeded()
            return selection.file == "SKILL.md"
        }
        XCTAssertEqual(scroller.contentView.bounds.minY, 200, accuracy: 1,
                       "Picker selection must leave the page offset alone")
    }

    func testSourceAfterLinkFitsLikeSourceWithoutLink() async throws {
        for file in ["SKILL.md", "references/x.md", "scripts/x.sh"] {
            let selection = PreviewFileSelection()
            let linked = navigationFixture(selection: selection, destination: "# Reference\nTiny.")
            defer { linked.window.close() }
            try await followReference(in: linked, selection: selection)
            if file != selection.file { try pickFile(file, in: linked.host) }
            selection.mode = .source
            let editor = try await waitForEditor(in: linked.host)

            let freshSelection = PreviewFileSelection()
            freshSelection.file = file
            freshSelection.mode = .source
            let fresh = navigationFixture(selection: freshSelection, destination: "# Reference\nTiny.")
            defer { fresh.window.close() }
            _ = try await waitForEditor(in: fresh.host)
            let freshRange = try scrollRange(of: pageScroller(in: fresh.host))
            let linkedScroller = try pageScroller(in: linked.host)
            XCTAssertEqual(freshRange, 0, accuracy: 1, "Fresh source must fit; \(file)")
            XCTAssertEqual(scrollRange(of: linkedScroller), freshRange, accuracy: 1,
                           "Source after a link must have no added page scroll range; \(file)")
            XCTAssertGreaterThanOrEqual(editor.frame.height, SkillContentTab.sourceEditorMinimumHeight, file)
        }
    }

    func testScriptFileLinkPutsFileRowAtViewportTopWithTallChrome() async throws {
        let selection = PreviewFileSelection()
        let fixture = hostTab(markdown: paragraphs + "\n\n[Script](./scripts/x.sh)",
                              onSelectFile: { _ in }, openURL: { _ in XCTFail("Script link escaped") },
                              selection: selection, geometry: .init(height: 260, chromeHeight: 400))
        defer { fixture.window.close() }
        let link = try await findLink("Script", in: fixture.host)
        let scroller = try pageScroller(in: fixture.host)
        let screenViewport = viewport(of: scroller, in: fixture.window)
        scroller.contentView.scroll(to: NSPoint(x: 0, y: scrollRange(of: scroller)))
        scroller.reflectScrolledClipView(scroller.contentView)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Script link must finish scrolling into view") {
            fixture.host.layoutSubtreeIfNeeded()
            return screenViewport.contains(link.accessibilityFrame())
        }
        try click(link, in: fixture.window)
        let editor = try await waitForEditor(in: fixture.host)
        let text = await waitForEditorText("echo hi", in: editor, timeout: 3)
        XCTAssertEqual(text, "echo hi", "Script source must load into its read-only editor")
        fixture.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(selection.file, "scripts/x.sh")
        let mode = try XCTUnwrap(views(fixture.host).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(mode.selectedSegment, 1, "A script must open in source mode")
        XCTAssertFalse(mode.isEnabled, "A script cannot switch to rendered mode")
        XCTAssertGreaterThan(scrollRange(of: scroller), 300, "Tall chrome must make the page scroll")
        let row = try filePicker(in: fixture.host)
        let rowTop = screenViewport.maxY - row.accessibilityFrame().maxY
        XCTAssertEqual(rowTop, 0, accuracy: 1, "Linked script must put its file row at the viewport top")
    }

    func testShortBundleLinkBackToSkillKeepsFileRowVisibleWithTallChrome() async throws {
        let selection = PreviewFileSelection()
        selection.file = "references/x.md"
        let fixture = hostTab(markdown: "# Skill\n\n" + paragraphs,
                              onSelectFile: { _ in }, openURL: { _ in XCTFail("Return link escaped") },
                              selection: selection, otherMarkdown: "# Reference\n\n[Skill](../SKILL.md)",
                              geometry: .init(height: 260, chromeHeight: 400))
        defer { fixture.window.close() }
        let link = try await findLink("Skill", in: fixture.host)
        let scroller = try pageScroller(in: fixture.host)
        let screenViewport = viewport(of: scroller, in: fixture.window)
        scroller.contentView.scroll(to: NSPoint(x: 0, y: scrollRange(of: scroller)))
        scroller.reflectScrolledClipView(scroller.contentView)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Return link must finish scrolling into view") {
            fixture.host.layoutSubtreeIfNeeded()
            return screenViewport.contains(link.accessibilityFrame())
        }
        XCTAssertGreaterThan(scroller.contentView.bounds.minY, 100, "Tall chrome must make the short file scroll")
        try click(link, in: fixture.window)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Return link must load SKILL.md's long body") {
            fixture.host.layoutSubtreeIfNeeded()
            return selection.file == "SKILL.md" && self.elements(fixture.host).contains {
                ($0.accessibilityValue() as? String) == "Skill"
            }
        }
        let row = try filePicker(in: fixture.host)
        // From a page too short to scroll the row to the top, scrolling clamps and the row stays visible.
        XCTAssertTrue(screenViewport.insetBy(dx: 0, dy: -1).contains(row.accessibilityFrame()))
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
}

extension SkillPreviewLinkHostTests {
    private var paragraphs: String {
        (1...40).map { "Paragraph \($0). Filling the document." }.joined(separator: "\n\n")
    }

    private func navigationFixture(selection: PreviewFileSelection, destination: String)
        -> (host: NSHostingView<AnyView>, window: NSWindow) {
        hostTab(markdown: paragraphs + "\n\n[Reference](./references/x.md)",
                onSelectFile: { _ in }, openURL: { _ in XCTFail("File link escaped") },
                selection: selection, otherMarkdown: destination)
    }

    private func followReference(in fixture: (host: NSHostingView<AnyView>, window: NSWindow),
                                 selection: PreviewFileSelection) async throws {
        let link = try await findLink("Reference", in: fixture.host)
        let scroller = try pageScroller(in: fixture.host)
        let screenViewport = viewport(of: scroller, in: fixture.window)
        scroller.contentView.scroll(to: NSPoint(x: 0, y: scrollRange(of: scroller)))
        scroller.reflectScrolledClipView(scroller.contentView)
        XCTAssertGreaterThan(scroller.contentView.bounds.minY, 500)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Scrolled link must be inside the viewport") {
            fixture.host.layoutSubtreeIfNeeded()
            return screenViewport.contains(link.accessibilityFrame())
        }
        try click(link, in: fixture.window)
        await waitForReference(in: fixture.host, selection: selection)
        // Wait for the link's visible result as well as the selected document.
        let row = try filePicker(in: fixture.host)
        await TestWait.until(timeout: .seconds(3), failureMessage: "Linked file row must finish scrolling into view") {
            fixture.host.layoutSubtreeIfNeeded()
            return screenViewport.intersects(row.accessibilityFrame())
        }
    }

    private func waitForReference(in host: NSView, selection: PreviewFileSelection) async {
        await TestWait.until(timeout: .seconds(3), failureMessage: "Linked or picked reference must load") {
            host.layoutSubtreeIfNeeded()
            return selection.file == "references/x.md"
                && self.elements(host).contains { ($0.accessibilityValue() as? String) == "Reference" }
        }
    }

    private func waitForEditor(in host: NSView) async throws -> WKWebView {
        var editor: WKWebView?
        await TestWait.until(timeout: .seconds(3), failureMessage: "Source editor must finish layout") {
            host.layoutSubtreeIfNeeded()
            editor = self.views(host).compactMap { $0 as? WKWebView }.first
            return editor != nil && editor?.frame.height ?? 0 >= SkillContentTab.sourceEditorMinimumHeight
        }
        return try XCTUnwrap(editor)
    }

    private func waitForEditorText(_ expected: String, in editor: WKWebView, timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var evaluationFinished = false
            var text: String?
            editor.evaluateJavaScript(
                "window.Editor && window.Editor.getContent ? window.Editor.getContent() : null"
            ) { result, _ in
                text = result as? String
                evaluationFinished = true
            }
            while !evaluationFinished, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            guard evaluationFinished else { return nil }
            if text == expected { return text }
            try? await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        return nil
    }

    private func pickFile(_ file: String, in host: NSView) throws {
        let menu = try XCTUnwrap(filePicker(in: host).menu)
        let item = try XCTUnwrap(menu.items.firstIndex { $0.title == file })
        menu.performActionForItem(at: item)
    }

    private func filePicker(in host: NSView) throws -> NSPopUpButton {
        try XCTUnwrap(views(host).compactMap { $0 as? NSPopUpButton }.first)
    }

    private func pageScroller(in host: NSView) throws -> NSScrollView {
        try XCTUnwrap(views(host).compactMap { $0 as? NSScrollView }.first)
    }

    private func scrollRange(of scroller: NSScrollView) -> CGFloat {
        max(0, (scroller.documentView?.bounds.height ?? 0) - scroller.contentView.bounds.height)
    }

    private func viewport(of scroller: NSScrollView, in window: NSWindow) -> CGRect {
        window.convertToScreen(scroller.convert(scroller.bounds, to: nil))
    }

    private func hostTab(markdown: String, onSelectFile: @escaping (String) -> Void, openURL: @escaping (URL) -> Void,
                         selection: PreviewFileSelection? = nil, otherMarkdown: String = "# Reference",
                         geometry: PreviewHostGeometry = PreviewHostGeometry())
        -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let base = NSTemporaryDirectory() + "PreviewLinkHost-" + UUID().uuidString
        let files = DeployRecordingFileService()
        files.contents[Constants.pensieveSkillsDir + "/link-test/references/x.md"] = otherMarkdown
        files.contents[Constants.pensieveSkillsDir + "/link-test/scripts/x.sh"] = "echo hi"
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: files, baseDir: base),
                                            fileService: files, manifestRoot: base)
        let skill = Skill(name: "Link test", directoryName: "link-test")
        var snapshot = DetailContentSnapshot(body: markdown)
        snapshot.inventory.files = ["SKILL.md", "references/x.md", "scripts/x.sh"].map {
            .init(relativePath: $0, bytes: 20, tokens: 5)
        }
        let tab = PreviewContentHarness(skill: skill, snapshot: snapshot, library: library,
                                        selection: selection ?? PreviewFileSelection(), chromeHeight: geometry.chromeHeight,
                                        onSelectFile: { path in
                                            onSelectFile(path)
                                            selection?.file = path
                                        })
        let host = NSHostingView(rootView: AnyView(tab.frame(width: 640, height: geometry.height)
            .environment(\.openURL, OpenURLAction { openURL($0); return .handled })))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: geometry.height),
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

private struct PreviewHostGeometry {
    var height: CGFloat = 480
    var chromeHeight: CGFloat?
}

@Observable
private final class PreviewFileSelection {
    var file = "SKILL.md"
    var mode = SkillContentPresentation.Mode.rendered
}

private struct PreviewContentHarness: View {
    let skill: Skill
    let snapshot: DetailContentSnapshot
    let library: SkillLibraryViewModel
    let selection: PreviewFileSelection
    let chromeHeight: CGFloat?
    let onSelectFile: (String) -> Void

    var body: some View {
        let presentation = SkillContentPresentation.resolve(selectedFile: selection.file, requestedMode: selection.mode,
                                                             inventory: snapshot.inventory)
        SkillDetailScrollLayout(skillID: skill.id,
                              contentOwnsScroller: DetailView.contentOwnsScroller(tab: .content, presentation: presentation)) {
            Text("Detail header").frame(height: chromeHeight)
        } tabContent: {
            SkillContentTab(skill: skill, snapshot: snapshot, library: library, presentation: presentation,
                            onSelectFile: onSelectFile, onSelectMode: { selection.mode = $0 })
        }
    }
}
