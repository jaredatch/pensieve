import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension ViewChangesSceneTests {
    func testListAppearanceStylesOnlyItsOwnTableOnce() async {
        let window = makeWindow(id: "view-changes-own-table")
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        let unrelated = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let own = NSTableView(frame: NSRect(x: 220, y: 0, width: 200, height: 200))
        unrelated.selectionHighlightStyle = .sourceList
        own.selectionHighlightStyle = .sourceList
        root.addSubview(unrelated) // Earlier in the window tree than the sidebar's table.
        root.addSubview(own)
        let row = NSView(frame: own.bounds)
        own.addSubview(row)
        row.addSubview(ViewChangesListAppearanceView(frame: .zero))
        window.contentView = root
        window.orderFront(nil)
        defer { window.close() }
        await drainAppearanceQueue()
        XCTAssertEqual(own.selectionHighlightStyle, .none, "The hook must style its ancestor table")
        XCTAssertEqual(unrelated.selectionHighlightStyle, .sourceList,
                       "A different table earlier in the window tree must keep its own appearance")

        own.selectionHighlightStyle = .regular
        own.removeFromSuperview()
        root.addSubview(own)
        await drainAppearanceQueue()
        XCTAssertEqual(own.selectionHighlightStyle, .regular,
                       "Reattaching the same table must not repeat appearance configuration")
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
        model.open(skillID: skill.id, context: fixture.context)
        await TestWait.until(failureMessage: "selection preview did not finish") { model.state != .loading }
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
        XCTAssertEqual(table.selectionHighlightStyle, .none,
                       "Only the frame's row fill should paint selection; native selection stays enabled")
        XCTAssertGreaterThanOrEqual(table.selectedRow, 0, "The native List must still hold its selected row")
        XCTAssertNotNil(model.selectedFile)
    }

    private func nativeTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.nativeTable(in: $0) }.first
    }
}
