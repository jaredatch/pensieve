import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

private let twoRowFrameHeight: CGFloat = 375

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
            if count == 1 { try assertRowColumns(model, fixture: fixture) }
            if count == 2 { try assertInitialTwoRowLayout(model, fixture: fixture) }
            let main = try await hostSheet(model, fixture: fixture)
            defer { Self.closeSheetHost(main) }
            let sheet = try await attachedSheet(to: main, model: model)
            assertStableFrame(sheet)
            let inset = main.frame.maxY - sheet.frame.maxY
            let cap = main.frame.height - inset
            let height = sheet.frame.height
            heights[count] = height
            XCTAssertEqual(main.frame.width, 900, accuracy: 1, "Main width=\(main.frame.width)")
            XCTAssertEqual(main.frame.height, 600, accuracy: 1, "Main height=\(main.frame.height)")
            XCTAssertEqual(sheet.contentView?.bounds.width ?? 0, 480, accuracy: 1, "\(count) rows: sheet=\(sheet.frame)")
            XCTAssertTrue(main.frame.insetBy(dx: -2, dy: -2).contains(sheet.frame),
                          "\(count) rows: whole sheet \(sheet.frame) must fit main \(main.frame), including footer")
            if count == 2 {
                XCTAssertEqual(height, twoRowFrameHeight, accuracy: 2,
                               "Two-row frame measured \(height), expected \(twoRowFrameHeight)±2")
            }
            if count == 12 {
                XCTAssertEqual(height, DesignTokens.updatesMaximumHeight, accuracy: 2,
                               "Twelve rows measured \(height), token maximum=\(DesignTokens.updatesMaximumHeight)")
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

    private func assertInitialTwoRowLayout(_ model: UpdatesViewModel, fixture: UpdateReviewFixture) throws {
        let host = NSHostingView(rootView: UpdatesView(model: model, onViewChanges: { _ in })
            .modelContainer(fixture.container))
        let height = host.fittingSize.height
        XCTAssertEqual(height, twoRowFrameHeight, accuracy: 2,
                       "First two-row layout measured \(height), expected \(twoRowFrameHeight)±2 before attachment")
    }

    private func assertStableFrame(_ sheet: NSWindow) {
        let clock = ContinuousClock()
        var stableSince = clock.now
        var stableReads = 0
        var previous: CGRect?
        var lastHeights: [CGFloat] = []
        let settled = TestWait.until(poll: { sheet.contentView?.layoutSubtreeIfNeeded() }, condition: {
            let frame = sheet.frame
            lastHeights = Array((lastHeights + [frame.height]).suffix(3))
            if previous == frame {
                stableReads += 1
            } else {
                stableReads = 1
                stableSince = clock.now
            }
            previous = frame
            return stableReads >= 3 && stableSince.duration(to: clock.now) >= .milliseconds(50)
        })
        XCTAssertTrue(settled, "Sheet frame did not settle across at least three reads over 50 ms: last heights=\(lastHeights)")
    }

    private func assertRowColumns(_ model: UpdatesViewModel, fixture: UpdateReviewFixture) throws {
        if #available(macOS 26, *) {
            let shown = try XCTUnwrap(UpdatesSheetPresentation(model).rows.first)
            let checkbox = NSHostingView(rootView: Toggle(shown.name, isOn: .constant(true))
                .labelsHidden().toggleStyle(.checkbox).controlSize(.extraLarge)).fittingSize.width
            let name = Text(shown.name).font(DesignTokens.updatesRowName)
                + Text(shown.source).font(DesignTokens.updatesRowSource)
            let textWidth = max(NSHostingView(rootView: name).fittingSize.width,
                                NSHostingView(rootView: Text(shown.commits).font(DesignTokens.updatesRowCommits))
                                    .fittingSize.width)
            let changes = NSHostingView(rootView: Button(shown.changesTitle, action: {})
                .font(DesignTokens.updatesChangesButton).buttonStyle(.borderless).controlSize(.small)).fittingSize.width
            let host = NSHostingView(rootView: UpdatesRowView(model: model, shown: shown, context: fixture.context,
                                                             onViewChanges: { _ in }).controlSize(.extraLarge))
            let width = host.fittingSize.width
            let minimum = max(DesignTokens.updatesRowBodyOffset, checkbox) + textWidth + Spacing.sm + changes
                + DesignTokens.updatesRowPadding.leading + DesignTokens.updatesRowPadding.trailing
            XCTAssertGreaterThanOrEqual(width, minimum - 1,
                "Row width=\(width), checkbox=\(checkbox), body=\(textWidth), minimum=\(minimum): columns cannot overlap")
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        [view].compactMap { $0 as? NSScrollView } + view.subviews.flatMap { scrollViews(in: $0) }
    }
}
