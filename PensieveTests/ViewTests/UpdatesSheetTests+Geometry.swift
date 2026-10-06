import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension UpdatesSheetTests {
    func testRenderedSheetGrowsFromOneToThreeRowsAndTwelveRowsReachScrollingCap() async throws {
        var heights: [Int: CGFloat] = [:]
        for count in [1, 2, 3, 12] {
            let fixture = try UpdateReviewFixture()
            defer { try? fixture.cleanup() }
            let skills = try (1...count).map { try fixture.skill("geometry-\($0)") }
            let rows = try skills.enumerated().map {
                try UpdatesViewModel.makeRow(skill: $0.element, driftedLocally: $0.offset == 1)
            }
            let model = fixture.sheet(rows: rows)
            model.present(library: fixture.library)
            await model.loadAndReport(context: fixture.context)
            let main = hostSheet(model, fixture: fixture)
            defer { main.close() }
            let sheet = try await attachedSheet(to: main, model: model)
            let cap = min(600, main.contentLayoutRect.height)
            await TestWait.until(failureMessage: "\(count) rows: sheet measured \(sheet.frame.height), cap=\(cap)") {
                sheet.frame.height <= cap + 2
            }
            sheet.contentView?.layoutSubtreeIfNeeded()
            let height = sheet.frame.height
            heights[count] = height
            XCTAssertEqual(main.frame.width, 900, accuracy: 1, "Main width=\(main.frame.width)")
            XCTAssertEqual(main.frame.height, 600, accuracy: 1, "Main height=\(main.frame.height)")
            XCTAssertEqual(sheet.contentView?.bounds.width ?? 0, 480, accuracy: 1, "\(count) rows: sheet=\(sheet.frame)")
            XCTAssertTrue(main.frame.insetBy(dx: -2, dy: -2).contains(sheet.frame),
                          "\(count) rows: whole sheet \(sheet.frame) must fit main \(main.frame), including footer")
            if count == 2 { XCTAssertEqual(height, 375, accuracy: 2, "Two-row frame measured \(height), expected 375±2") }
            if count == 12 {
                XCTAssertEqual(height, cap, accuracy: 2, "Twelve rows measured \(height), maximum attached height=\(cap)")
                let scroll = try XCTUnwrap(scrollViews(in: try XCTUnwrap(sheet.contentView)).first,
                                           "Twelve rows measured \(height): a native row scroller must exist")
                let document = try XCTUnwrap(scroll.documentView)
                let range = document.bounds.height - scroll.contentView.bounds.height
                XCTAssertGreaterThan(range, 0,
                                     "Twelve rows measured \(height): document=\(document.bounds), viewport=\(scroll.bounds)")
                scroll.contentView.scroll(to: NSPoint(x: 0, y: range))
                scroll.reflectScrolledClipView(scroll.contentView)
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "Twelve rows measured \(height): row scrolling must move")
            }
        }
        let one = try XCTUnwrap(heights[1]), two = try XCTUnwrap(heights[2])
        let three = try XCTUnwrap(heights[3]), twelve = try XCTUnwrap(heights[12])
        XCTAssertLessThan(one, two, "One=\(one), two=\(two)")
        XCTAssertLessThan(two, three, "Two=\(two), three=\(three)")
        XCTAssertLessThan(three, twelve, "Three=\(three), cap=\(twelve)")
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        [view].compactMap { $0 as? NSScrollView } + view.subviews.flatMap { scrollViews(in: $0) }
    }
}
