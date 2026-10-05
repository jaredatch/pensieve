import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Pensieve

/// The Content tab's file row in a narrow detail column (PLAN-34 / 34.2, Layer-1): a pop-up button is as
/// wide as its widest item, so one long bundle path must not push the row past the column — the pulldown
/// is capped and gives way, and the full path stays in its menu.
final class SkillContentTabLayoutTests: XCTestCase {
    func testALongFileNameKeepsTheFileRowInsideTheColumn() throws {
        let long = "references/native-app-framework-configuration-best-practices.md"
        var snapshot = DetailContentSnapshot()
        snapshot.inventory.files = [SkillBundleInventory.File(relativePath: "SKILL.md", bytes: 10, tokens: 3),
                                    SkillBundleInventory.File(relativePath: long, bytes: 10, tokens: 3)]
        let base = TestTemporaryDirectory.path + "SkillContentTabLayoutTests-\(UUID().uuidString)"
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: FileService(), baseDir: base))
        let presentation = SkillContentPresentation.resolve(
            selectedFile: "SKILL.md", requestedMode: .rendered, inventory: snapshot.inventory
        )
        let tab = SkillContentTab(skill: Skill(name: "Example", directoryName: "example"), snapshot: snapshot,
                                  library: library, presentation: presentation,
                                  onSelectFile: { _ in }, onSelectMode: { _ in })
        let width: CGFloat = 480
        let host = NSHostingView(rootView: tab.frame(width: width, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let controls = Self.controls(in: host)
        let popUp = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertTrue(controls.contains { $0 is NSSegmentedControl })
        XCTAssertLessThanOrEqual(popUp.frame.width, 240)
        for control in controls {
            let frame = control.convert(control.bounds, to: host)
            XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(type(of: control)) starts left of the column")
            XCTAssertLessThanOrEqual(frame.maxX, width, "\(type(of: control)) ends right of the column")
        }
    }

    func testThePulldownWidensWhenTheListArrives() throws {
        let base = TestTemporaryDirectory.path + "SkillContentTabLayoutTests-\(UUID().uuidString)"
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: FileService(), baseDir: base))
        let skill = Skill(name: "Example", directoryName: "example")
        func tab(_ paths: [String]) -> AnyView {
            var snapshot = DetailContentSnapshot()
            snapshot.inventory.files = paths.map { SkillBundleInventory.File(relativePath: $0, bytes: 10, tokens: 3) }
            let presentation = SkillContentPresentation.resolve(
                selectedFile: "SKILL.md", requestedMode: .rendered, inventory: snapshot.inventory
            )
            return AnyView(SkillContentTab(skill: skill, snapshot: snapshot, library: library,
                                           presentation: presentation,
                                           onSelectFile: { _ in }, onSelectMode: { _ in })
                .frame(width: 480, height: 300))
        }
        func hosted(_ view: AnyView) -> (NSHostingView<AnyView>, NSWindow) {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            return (host, window)
        }
        let full = ["SKILL.md", "references/examples-for-the-audience.md"]
        let (grown, grownWindow) = hosted(tab(["SKILL.md"]))
        grown.rootView = tab(full)
        grown.layoutSubtreeIfNeeded()
        let (fresh, freshWindow) = hosted(tab(full))
        let grownWidth = try XCTUnwrap(Self.controls(in: grown).compactMap { $0 as? NSPopUpButton }.first).frame.width
        let freshWidth = try XCTUnwrap(Self.controls(in: fresh).compactMap { $0 as? NSPopUpButton }.first).frame.width
        XCTAssertEqual(grownWidth, freshWidth, accuracy: 0.5, "the pop-up keeps the width of the list it was built with")
        _ = (grownWindow, freshWindow)
    }

    func testSourceOverflowKeepsTheProductionEditorUsable() throws {
        try assertSourceOverflowKeepsEditorUsable(selectedFile: "SKILL.md")
        try assertSourceOverflowKeepsEditorUsable(selectedFile: "scripts/x.sh")
    }

    private func assertSourceOverflowKeepsEditorUsable(selectedFile: String) throws {
        let fixture = sourceFixture(selectedFile: selectedFile)
        defer { fixture.window.close() }
        let editor = try XCTUnwrap(waitForEditor(in: fixture.host, timeout: 3), selectedFile)
        let popUp = try XCTUnwrap(Self.controls(in: fixture.host).compactMap { $0 as? NSPopUpButton }.first)
        let columnScroller = try XCTUnwrap(Self.nearestScrollView(to: popUp))

        if selectedFile == "scripts/x.sh" {
            XCTAssertEqual(waitForEditorText("echo hi", in: editor, timeout: 3), "echo hi")
        }
        XCTAssertGreaterThan(Self.scrollRange(of: columnScroller), 100, selectedFile)
        XCTAssertFalse(Self.isVisible(popUp, in: columnScroller), selectedFile)
        XCTAssertGreaterThanOrEqual(editor.frame.height, SkillContentTab.sourceEditorMinimumHeight, selectedFile)
        Self.scrollToBottom(columnScroller)
        XCTAssertTrue(Self.isVisible(popUp, in: columnScroller), selectedFile)
        XCTAssertGreaterThanOrEqual(editor.frame.height, SkillContentTab.sourceEditorMinimumHeight, selectedFile)
    }

    private func sourceFixture(selectedFile: String) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let skill = Skill(name: "Example", directoryName: "example")
        let fileService = DeployRecordingFileService()
        fileService.contents[Constants.pensieveSkillsDir + "/example/scripts/x.sh"] = "echo hi"
        let base = TestTemporaryDirectory.path + "SkillContentTabLayoutTests-\(UUID().uuidString)"
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: fileService, baseDir: base),
            fileService: fileService
        )
        var snapshot = DetailContentSnapshot()
        snapshot.inventory.files = [
            .init(relativePath: "SKILL.md", bytes: 10, tokens: 3),
            .init(relativePath: "scripts/x.sh", bytes: 10, tokens: 3)
        ]
        let presentation = SkillContentPresentation.resolve(
            selectedFile: selectedFile,
            requestedMode: .source,
            inventory: snapshot.inventory
        )
        let contentOwnsScroller = DetailView.contentOwnsScroller(tab: .content, presentation: presentation)
        let tab = SkillContentTab(
            skill: skill,
            snapshot: snapshot,
            library: library,
            presentation: presentation,
            onSelectFile: { _ in },
            onSelectMode: { _ in }
        )
        let layout = SkillDetailScrollLayout(skillID: skill.id, contentOwnsScroller: contentOwnsScroller) {
            SkillDescriptionText(text: Self.longDescription, expanded: true)
                .padding(.horizontal, Spacing.lg)
        } tabContent: {
            tab
        }
        let host = NSHostingView(rootView: AnyView(layout.frame(width: 640, height: 480)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private static var longDescription: String {
        (1...40).map { "Line \($0): a long skill description expands with the rest of the detail page." }
            .joined(separator: "\n")
    }

    private func waitForEditor(in host: NSView, timeout: TimeInterval) -> WKWebView? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let editor = Self.views(in: host).compactMap({ $0 as? WKWebView }).first {
                return editor
            }
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        } while Date() < deadline
        return nil
    }

    private func waitForEditorText(_ expected: String, in editor: WKWebView, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastText: String?
        repeat {
            var evaluationFinished = false
            editor.evaluateJavaScript(
                "window.Editor && window.Editor.getContent ? window.Editor.getContent() : null"
            ) { result, _ in
                lastText = result as? String
                evaluationFinished = true
            }
            while !evaluationFinished, Date() < deadline {
                RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
            }
            if lastText == expected { return lastText }
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        } while Date() < deadline
        return lastText
    }

    private static func controls(in view: NSView) -> [NSControl] {
        let own = [view].compactMap { $0 as? NSControl }.filter { $0 is NSPopUpButton || $0 is NSSegmentedControl }
        return own + view.subviews.flatMap { controls(in: $0) }
    }

    private static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private static func nearestScrollView(to view: NSView) -> NSScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView { return scrollView }
            ancestor = current.superview
        }
        return nil
    }

    private static func scrollRange(of scrollView: NSScrollView) -> CGFloat {
        max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height)
    }

    private static func scrollToBottom(_ scrollView: NSScrollView) {
        let origin = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: scrollRange(of: scrollView)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func isVisible(_ view: NSView, in scrollView: NSScrollView) -> Bool {
        let frame = view.convert(view.bounds, to: scrollView.documentView)
        return scrollView.documentVisibleRect.intersects(frame)
    }
}
