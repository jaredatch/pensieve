import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Pensieve

extension ViewChangesSceneTests {
    func testListAppearanceRestoresSingleHighlightWithoutTouchingAnotherTable() async {
        let window = makeWindow(id: "view-changes-own-table")
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        let unrelated = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let own = NSTableView(frame: NSRect(x: 220, y: 0, width: 200, height: 200))
        unrelated.selectionHighlightStyle = .sourceList
        own.selectionHighlightStyle = .sourceList
        root.addSubview(unrelated) // Earlier in the window tree than the sidebar's table.
        let sidebar = NSView(frame: own.frame)
        let scroll = NSScrollView(frame: sidebar.bounds)
        scroll.documentView = own
        sidebar.addSubview(scroll)
        let hook = ViewChangesListAppearanceView(frame: .zero)
        sidebar.addSubview(hook) // List-level hook: no file row is needed.
        root.addSubview(sidebar)
        window.contentView = root
        window.orderFront(nil)
        defer { window.close() }
        await drainAppearanceQueue()
        XCTAssertEqual(own.selectionHighlightStyle, .none, "The List-level hook must style its own empty table")
        XCTAssertEqual(unrelated.selectionHighlightStyle, .sourceList,
                       "A different table earlier in the window tree must keep its own appearance")

        own.selectionHighlightStyle = .regular
        hook.viewDidMoveToWindow()
        await drainAppearanceQueue()
        XCTAssertEqual(own.selectionHighlightStyle, .none,
                       "A style reset must be repaired so only the frame highlight paints")
        XCTAssertEqual(unrelated.selectionHighlightStyle, .sourceList)
        own.selectionHighlightStyle = .sourceList
        hook.viewDidChangeEffectiveAppearance()
        await drainAppearanceQueue()
        XCTAssertEqual(own.selectionHighlightStyle, .none, "Appearance changes must retain the single highlight")
        XCTAssertEqual(unrelated.selectionHighlightStyle, .sourceList)
    }

    private func drainAppearanceQueue() async {
        let drained = expectation(description: "appearance queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
    }

    func testNativeFileListSelectionUsesOnlyTheFrameHighlight() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let skill = try fixture.skill("single-highlight")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let model = ViewChangesViewModel(library: fixture.library, operations: fixture.operations(rows: [row]))
        let window = makeWindow(id: "view-changes-highlight")
        window.contentView = NSHostingView(rootView: ViewChangesView(model: model, library: fixture.library, onUpdate: {})
            .modelContainer(fixture.container))
        window.orderFront(nil)
        defer { window.close() }
        await TestWait.until(failureMessage: "native file list did not render") {
            self.nativeTable(in: window.contentView) != nil
        }
        let table = try XCTUnwrap(nativeTable(in: window.contentView))
        await TestWait.until(timeout: .seconds(5), failureMessage: "native selection appearance did not settle") {
            table.selectionHighlightStyle == .none
        }
        XCTAssertEqual(table.selectionHighlightStyle, .none, "An empty native List must already have one highlight treatment")
        model.open(skillID: skill.id, context: fixture.context)
        await TestWait.until(failureMessage: "selection preview did not finish") { model.state != .loading }
        await TestWait.until(failureMessage: "native List must select the loaded preview") { table.selectedRow >= 0 }
        XCTAssertEqual(table.selectionHighlightStyle, .none,
                       "Only the frame's row fill should paint selection; native selection stays enabled")
        XCTAssertGreaterThanOrEqual(table.selectedRow, 0, "The native List must still hold its selected row")
        XCTAssertNotNil(model.selectedFile)
        table.selectionHighlightStyle = .sourceList
        model.selectFile(path: "scripts/setup.sh")
        await TestWait.until(timeout: .seconds(5), failureMessage: "selection update must restore the single highlight") {
            table.selectionHighlightStyle == .none
        }
        XCTAssertEqual(table.selectionHighlightStyle, .none, "A native style reset cannot add a second highlight")
    }

    func testLongFileRowKeepsFullCountsAtFrameSidebarWidth() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let skill = try fixture.skill("long-row-layout")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let path = "scripts-with-a-very-long-folder-name-TAIL/comment-with-an-extremely-long-filename.swift"
        let preview = PinnedSkillDiff(comparison: FileTreeComparison(changes: [
            FileTreeChange(path: path, kind: .modified, content: .text(
                old: String(repeating: "old\n", count: 1_234), new: String(repeating: "new\n", count: 1_234)))
        ], unreadFileCount: 0, bytesRead: 9_872))
        let file = try XCTUnwrap(preview.files.first)
        XCTAssertEqual(file.linesAdded, 1_234)
        XCTAssertEqual(file.linesRemoved, 1_234)
        let model = ViewChangesViewModel(library: fixture.library,
                                        operations: fixture.operations(rows: [row], preview: preview))
        model.open(skillID: skill.id, context: fixture.context)
        await TestWait.until(failureMessage: "long row preview did not finish") { model.state != .loading }
        let window = makeWindow(id: "view-changes-long-row")
        window.contentView = NSHostingView(rootView: ViewChangesView(model: model, library: fixture.library, onUpdate: {})
            .modelContainer(fixture.container))
        window.orderFront(nil)
        defer { window.close() }
        await TestWait.until(failureMessage: "long row list did not render") {
            self.nativeTable(in: window.contentView)?.numberOfRows == 1
        }
        let table = try XCTUnwrap(nativeTable(in: window.contentView))
        await drainAppearanceQueue()
        table.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertEqual(cell.bounds.width, 208, accuracy: 2,
                       "The native row must use the 240 pt sidebar minus its two 16 pt frame margins; " +
                       "table \(table.frame), cell \(cell.frame), columns \(table.tableColumns.map(\.width))")
        let rendered = try renderedRowText(file, width: min(208, cell.bounds.width)).replacingOccurrences(of: ",", with: "")
        XCTAssertEqual(rendered.components(separatedBy: "1234").count - 1, 2,
                       "Both +1234 and −1234 must render in full; got: \(rendered)")
        XCTAssertTrue(rendered.contains(".swift"), "The long filename must keep its suffix with middle truncation: \(rendered)")
        XCTAssertTrue(rendered.contains("TAIL"), "The folder must keep its suffix with middle truncation: \(rendered)")
    }

    private func renderedRowText(_ file: PinnedSkillFileDiff, width: CGFloat) throws -> String {
        let renderer = ImageRenderer(content: ViewChangesFileRow(file: file, selected: true)
            .frame(width: width).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 4
        let image = try XCTUnwrap(renderer.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func nativeTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.nativeTable(in: $0) }.first
    }
}
