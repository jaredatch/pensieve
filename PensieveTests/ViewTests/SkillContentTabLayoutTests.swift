import AppKit
import SwiftUI
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
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: FileService(), baseDir: base + "/skills"),
            fileWatchService: FileWatchService(rootDir: base + "/skills"), manifestRoot: base
        )
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
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: FileService(), baseDir: base + "/skills"),
            fileWatchService: FileWatchService(rootDir: base + "/skills"), manifestRoot: base
        )
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

    /// The file row sits in equal gaps: the tab strip above it, the file's content below it, and no rule
    /// between the row and the content (the header scrolls, so nothing needs setting off).
    @MainActor
    func testTheFileRowGapBelowMatchesTheGapAbove() async throws {
        let fixture = sourceFixture(selectedFile: "SKILL.md", description: nil, height: 600)
        defer { fixture.window.close() }
        let editor = try await TestWait.waitForEditor(in: fixture.host)
        let popUp = try XCTUnwrap(Self.controls(in: fixture.host).compactMap { $0 as? NSPopUpButton }.first)
        let column = try XCTUnwrap(Self.nearestScrollView(to: popUp)?.documentView)
        let rowFrame = Self.flipped(popUp, in: column)
        let editorFrame = Self.flipped(editor, in: column)

        XCTAssertEqual(rowFrame.minY, DesignTokens.contentRowTop, accuracy: 1)
        XCTAssertEqual(editorFrame.minY - rowFrame.maxY, rowFrame.minY, accuracy: 1)
    }

    @MainActor
    func testSourceOverflowKeepsTheProductionEditorUsable() async throws {
        try await assertSourceOverflowKeepsEditorUsable(selectedFile: "SKILL.md")
        try await assertSourceOverflowKeepsEditorUsable(selectedFile: "scripts/x.sh")
    }

    @MainActor
    private func assertSourceOverflowKeepsEditorUsable(selectedFile: String) async throws {
        let fixture = sourceFixture(selectedFile: selectedFile)
        defer { fixture.window.close() }
        let editor = try await TestWait.waitForEditor(
            in: fixture.host, timeout: .seconds(TestWait.firstRenderTimeoutSeconds)
        )
        let popUp = try XCTUnwrap(Self.controls(in: fixture.host).compactMap { $0 as? NSPopUpButton }.first)
        let columnScroller = try XCTUnwrap(Self.nearestScrollView(to: popUp))

        if selectedFile == "scripts/x.sh" {
            let text = await TestWait.waitForEditorText("echo hi", in: editor,
                                                      timeout: .seconds(TestWait.hostedActionTimeoutSeconds))
            XCTAssertEqual(text, "echo hi")
        }
        XCTAssertGreaterThan(Self.scrollRange(of: columnScroller), 100, selectedFile)
        XCTAssertFalse(Self.isVisible(popUp, in: columnScroller), selectedFile)
        XCTAssertGreaterThanOrEqual(editor.frame.height, SkillContentTab.sourceEditorMinimumHeight, selectedFile)
        Self.scrollToBottom(columnScroller)
        XCTAssertTrue(Self.isVisible(popUp, in: columnScroller), selectedFile)
        XCTAssertGreaterThanOrEqual(editor.frame.height, SkillContentTab.sourceEditorMinimumHeight, selectedFile)
    }

    private func sourceFixture(
        selectedFile: String,
        description: String? = SkillContentTabLayoutTests.longDescription,
        height: CGFloat = 480
    ) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let skill = Skill(name: "Example", directoryName: "example")
        let fileService = DeployRecordingFileService()
        let base = TestTemporaryDirectory.path + "SkillContentTabLayoutTests-\(UUID().uuidString)"
        fileService.contents[base + "/skills/example/scripts/x.sh"] = "echo hi"
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: fileService, baseDir: base + "/skills"),
            fileService: fileService, fileWatchService: FileWatchService(rootDir: base + "/skills"),
            manifestRoot: base
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
            if let description {
                SkillDescriptionText(text: description, expanded: true)
                    .padding(.horizontal, Spacing.lg)
            }
        } tabContent: {
            tab
        }
        let host = NSHostingView(rootView: AnyView(layout.frame(width: 640, height: height)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: height),
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

    private static func controls(in view: NSView) -> [NSControl] {
        let own = [view].compactMap { $0 as? NSControl }.filter { $0 is NSPopUpButton || $0 is NSSegmentedControl }
        return own + view.subviews.flatMap { controls(in: $0) }
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

    /// A view's frame in a container's coordinates, measured from the container's top.
    private static func flipped(_ view: NSView, in container: NSView) -> CGRect {
        let frame = view.convert(view.bounds, to: container)
        guard !container.isFlipped else { return frame }
        return CGRect(x: frame.minX, y: container.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func isVisible(_ view: NSView, in scrollView: NSScrollView) -> Bool {
        let frame = view.convert(view.bounds, to: scrollView.documentView)
        return scrollView.documentVisibleRect.intersects(frame)
    }
}
