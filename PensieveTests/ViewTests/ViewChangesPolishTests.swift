import AppKit
import CoreText
import SwiftUI
import Vision
import XCTest
@testable import Pensieve

@MainActor
final class ViewChangesPolishTests: XCTestCase {
    func testSidebarStartsClosedForOneChangedFileAndOpenForSeveral() async throws {
        let review = try await makeReview(previews: [preview(count: 1), preview(count: 2), preview(count: 1),
                                                     preview(count: 0)])
        try await expectSidebar(false, review)
        try await review.load(0)
        try await expectSidebar(false, review)
        try await review.load(1)
        try await expectSidebar(true, review)
        _ = try text("file-1.swift", in: review.root)
        try await review.load(2)
        try await expectSidebar(false, review)
        try await review.load(3)
        _ = try text("No File Changes", in: review.root)
        try await expectSidebar(false, review)
        try await review.load(1)
        try await review.load(4) // The fixture's final skill fails its preview operation.
        _ = try text("Couldn't Load Changes", in: review.root)
        try await expectSidebar(false, review)
        try await review.load(1)
        review.model.validate(skills: [], folderRevisions: [review.skills[1].directoryName: 1],
                              context: review.fixture.context)
        await review.settle("Preview No Longer Current")
        try await expectSidebar(false, review)
        review.model.close()
        await review.settle("No Update Selected")
        try await expectSidebar(false, review)
        let gate = TestWait.Gate(owner: self)
        review.operationGate = gate
        review.model.open(skillID: review.skills[1].id, context: review.fixture.context)
        await review.settle("Loading changes…")
        try await expectSidebar(false, review)
        gate.open()
        await review.settle("file-0.swift")
    }

    func testSidebarKeepsYourChoiceUntilNewChangesLoad() async throws {
        let review = try await makeReview(previews: [preview(count: 2), preview(count: 2),
                                                     preview(count: 1), preview(count: 1)])
        try await review.load(0)
        try toggleSidebar(review)
        try await expectSidebar(false, review)
        review.model.selectFile(id: 1)
        await review.settle("folder/file-1.swift")
        try await expectSidebar(false, review)
        review.model.open(skillID: review.skills[0].id, context: review.fixture.context)
        try await expectSidebar(false, review)
        try await review.load(1)
        try await expectSidebar(true, review)
        try await review.load(2)
        try toggleSidebar(review)
        try await expectSidebar(true, review)
        review.model.open(skillID: review.skills[2].id, context: review.fixture.context)
        try await expectSidebar(true, review)
        try await review.load(3)
        try await expectSidebar(false, review)

        for count in [2, 1] {
            let comparison = history(review, skill: count - 1, count: count)
            review.model.openHistory(comparison, context: review.fixture.context)
            await review.settle("file-0.swift")
            try await expectSidebar(count > 1, review)
            try toggleSidebar(review)
            try await expectSidebar(count == 1, review)
            review.model.selectFile(id: count - 1)
            await review.settle(count == 1 ? "file-0.swift" : "folder/file-1.swift")
            review.model.openHistory(comparison, context: review.fixture.context)
            try await expectSidebar(count == 1, review)
            let next = history(review, skill: count + 1, count: count)
            review.model.openHistory(next, context: review.fixture.context)
            await review.settle("file-0.swift")
            try await expectSidebar(count > 1, review)
        }
    }

    func testSidebarFileRowsSitCloseToTheEdgesAndStayCompact() async throws {
        let name = "comment-with-an-extremely-long-filename.swift"
        let files = [name, "scripts/" + name].map { path in
            PinnedSkillFileDiff(change: FileTreeChange(path: path, kind: .modified,
                content: .text(old: "old\n", new: "new\n")),
                result: UnifiedDiff(old: String(repeating: "old\n", count: 1_234),
                                    new: String(repeating: "new\n", count: 1_234)))
        }
        let review = try await makeReview(previews: [PinnedSkillDiff(files: files, unreadFileCount: 0, bytesRead: 0)])
        try await review.load(0)
        let split = try splitView(review)
        let pane = split.arrangedSubviews[0]
        let sidebarHeading = try textValue("2 Changed Files", in: review.root)
        let paneFrame = try XCTUnwrap(sidebarHeading.ancestors.last {
            $0.type == "SwiftUI._SafeAreaInsetsModifier" && $0.frame.width < 300
        }?.frame)
        XCTAssertEqual(paneFrame.width, 240, accuracy: 1)
        let table = try XCTUnwrap(descendants(pane).compactMap { $0 as? NSTableView }.first)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        let listFrame = scroll.convert(scroll.bounds, to: review.root)
        XCTAssertEqual(listFrame.minX, paneFrame.minX, accuracy: 1)
        XCTAssertEqual(listFrame.maxX, paneFrame.maxX, accuracy: 1)
        XCTAssertEqual(table.numberOfRows, 2)
        await TestWait.until(failureMessage: "The sidebar list cells did not appear") {
            table.view(atColumn: 0, row: 1, makeIfNecessary: true) != nil
        }
        var previous: CGRect?
        for index in 0..<2 {
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: index, makeIfNecessary: true))
            let rowFrame = table.convert(table.rect(ofRow: index), to: review.root)
            XCTAssertLessThanOrEqual(rowFrame.height, index == 0 ? 28 : 40,
                "rowHeight=\(table.rowHeight), size=\(table.rowSizeStyle.rawValue), spacing=\(table.intercellSpacing)")
            if let previous { XCTAssertLessThanOrEqual(rowFrame.minY - previous.maxY, 2) }
            previous = rowFrame
            try assertSidebarCell(cell, within: paneFrame, file: files[index], root: review.root)
        }
    }

    func testTitleLinesUpWithTheFilePathClearOfTheSidebar() async throws {
        let review = try await makeReview(previews: [preview(count: 2)])
        try await review.load(0)
        let heading = try toolbarView("changes-heading", review)
        let title = try text(review.model.heading, in: heading)
        let titleFrame = heading.convert(title, to: review.root)
        let path = try text("file-0.swift", in: review.root)
        XCTAssertEqual(titleFrame.minX, path.minX, accuracy: 2)
        let pane = try splitView(review).arrangedSubviews[0]
        let edge = pane.convert(pane.safeAreaRect, to: review.root).maxX
        XCTAssertGreaterThanOrEqual(titleFrame.minX - edge, 16)
        XCTAssertLessThanOrEqual(titleFrame.minX - edge, 18)
        try toggleSidebar(review)
        try await expectSidebar(false, review)
        await review.settle("file-0.swift")
        let closedTitle = heading.convert(try text(review.model.heading, in: heading), to: review.root)
        let button = review.root.convert(review.window.convertFromScreen(try polishSidebarButtonFrame(in: review.window)),
                                         from: nil)
        XCTAssertGreaterThanOrEqual(closedTitle.minX - button.maxX, 8)
    }

    func testFirstChangeStartsRightUnderTheFileHeader() async throws {
        let review = try await makeReview(previews: [preview(count: 2)])
        try await review.load(0)
        let pathValue = try textValue("file-0.swift", in: review.root)
        let header = try XCTUnwrap(pathValue.ancestors.last {
            $0.type == "SwiftUI._FlexFrameLayout" && $0.frame.width > 700
        }?.frame, String(describing: pathValue.ancestors))
        let hunkValue = try textValue("@@ -1,1 +1,1 @@", in: review.root)
        let hunk = try XCTUnwrap(hunkValue.ancestors.last {
            $0.type == "SwiftUI._FlexFrameLayout" && $0.frame.width > 700
        }?.frame)
        XCTAssertEqual(hunk.minY, header.maxY, accuracy: 1)
    }

    func testLineNumberGutterIsAsNarrowAsTheEditors() async throws {
        let review = try await makeReview(previews: [numberPreview(lastOld: 123)])
        try await review.load(0)
        try assertNumberLayout(review, narrow: true)
    }

    func testLongLineNumbersDrawWholeAndKeepTextAligned() async throws {
        let review = try await makeReview(previews: [9_999, 99_999, 999_999].map(numberPreview))
        for index in 0..<3 {
            try await review.load(index)
            try assertNumberLayout(review, narrow: false)
        }
    }

    func testToolbarButtonsUseTheRegularControlSize() async throws {
        let review = try await makeReview(previews: [preview(count: 2)])
        try await review.load(0)
        var frames: [CGRect] = []
        for (identifier, label, prominent) in [("changes-github", "View on GitHub", false),
                                               ("changes-update", "Update", true)] {
            let host = try toolbarView(identifier, review)
            let values = RenderedViewTestSupport.layoutValues(in: host)
            let button = try XCTUnwrap(values.first { String(reflecting: type(of: $0.value)).hasPrefix("SwiftUI.Button<") })
            XCTAssertEqual(button.controlSize, .regular)
            let frame = try XCTUnwrap(button.frame)
            XCTAssertLessThan(frame.height, try largeButtonHeight(label, prominent: prominent))
            let labelFrame = try text(label, in: host)
            XCTAssertGreaterThanOrEqual(labelFrame.width + 0.5, textWidth(label, size: 13, monospaced: false))
            frames.append(host.convert(frame, to: review.root))
            if prominent {
                XCTAssertTrue(values.contains { String(reflecting: $0.value).contains("BorderedProminentButtonStyle") })
                XCTAssertEqual(button.keyboardShortcut, .defaultAction)
            }
        }
        XCTAssertLessThan(frames[0].maxX, frames[1].minX)
        XCTAssertGreaterThanOrEqual(frames[1].maxX, review.root.bounds.maxX - 30)
    }

}

extension ViewChangesPolishTests {
    private func makeReview(previews: [PinnedSkillDiff]) async throws -> PolishReview {
        let review = try await PolishReview(previews: previews)
        addTeardownBlock { @MainActor in
            review.operationGate?.open()
            review.window.close()
            review.window.contentView = nil
            try review.fixture.cleanup()
        }
        await review.settle("No Update Selected")
        return review
    }

    private func preview(count: Int) throws -> PinnedSkillDiff {
        try PinnedSkillDiff.build(comparison: FileTreeComparison(
            changes: changes(count: count), unreadFileCount: 0, bytesRead: 0))
    }

    private func changes(count: Int) -> [FileTreeChange] {
        (0..<count).map { index in
            FileTreeChange(path: index == 0 ? "file-0.swift" : "folder/file-\(index).swift",
                           kind: .modified, content: .text(old: "old\n", new: "new\n"))
        }
    }

    private func history(_ review: PolishReview, skill: Int, count: Int) -> HistoryDiffComparison {
        HistoryDiffComparison(skillID: review.skills[skill].id, skillName: review.skills[skill].name,
            sourceID: "polish-\(skill)", subtitle: "Installed → This copy",
            revision: UpstreamHistoryLocalRevision(appWriteRevision: review.fixture.library.appWriteRevision,
                watcherEventSequence: review.fixture.library.watcherEventSequence), changes: changes(count: count))
    }

    private func numberPreview(lastOld: Int) throws -> PinnedSkillDiff {
        let before = "start\n" + String(repeating: "\n", count: lastOld - 5) + "ending\nmiddle\nold-tail\nlast-line"
        let after = "inserted\n" + before.replacingOccurrences(of: "old-tail", with: "new-tail")
            .replacingOccurrences(of: "ending\n", with: "ending\r\n")
        return try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
            FileTreeChange(path: "file-0.swift", kind: .modified, content: .text(old: before, new: after))
        ], unreadFileCount: 0, bytesRead: before.utf8.count + after.utf8.count))
    }

    private func assertNumberLayout(_ review: PolishReview, narrow: Bool) throws {
        let values = RenderedViewTestSupport.layoutValues(in: review.root)
        XCTAssertFalse(values.isEmpty, "The production window must have a live render tree")
        let startValue = try textValue("start", in: review.root)
        let start = try XCTUnwrap(startValue.frame)
        let edge = try XCTUnwrap(startValue.ancestors.last {
            $0.type == "SwiftUI.HStack" && $0.frame.width > 500
        }?.frame).minX
        let columnWidth = (start.minX - edge - 20) / 2
        if narrow { XCTAssertEqual(columnWidth, 28, accuracy: 0.5) }
        let labels = values.compactMap { value -> (String, RenderedViewTestSupport.LayoutValue)? in
            guard let label = value.value as? Text, value.frame != nil,
                  let string = RenderedViewTestSupport.strings(in: label).first else { return nil }
            return (string, value)
        }
        let rows = values.compactMap { value -> ([String], CGRect)? in
            guard String(reflecting: type(of: value.value)).hasPrefix("SwiftUI.HStack<"),
                  let frame = value.frame else { return nil }
            let strings = rowStrings(value.value, depth: 20)
            guard strings.count == 4, strings[0].isEmpty || Int(strings[0]) != nil,
                  strings[1].isEmpty || Int(strings[1]) != nil, ["", "+", "−"].contains(strings[2]) else { return nil }
            return (strings, frame)
        }
        XCTAssertGreaterThan(rows.count, 4, "Every hunk must render its lines")
        for (strings, row) in rows {
            try assertNumberRow(strings, row: row, labels: labels, edge: edge, columnWidth: columnWidth, textX: start.minX)
        }
        if !narrow {
            let last = try XCTUnwrap(rows.first { $0.0[3] == "last-line" }?.0)
            XCTAssertNotEqual(last[0].count, last[1].count, "Exercise old/new numbers with different digit counts")
        }
        for note in ["\\ No newline at end of file", "Line ending changed: LF → CRLF"] {
            XCTAssertEqual(try text(note, in: review.root).minX, start.minX, accuracy: 0.5)
        }
        _ = try text("new-tail", in: review.root)
        _ = try text("last-line", in: review.root)
    }

    private func assertNumberRow(_ strings: [String], row: CGRect,
                                 labels: [(String, RenderedViewTestSupport.LayoutValue)],
                                 edge: CGFloat, columnWidth: CGFloat, textX: CGFloat) throws {
        for column in 0..<3 {
            guard !strings[column].isEmpty else { continue }
            let value = try XCTUnwrap(labels.first {
                $0.0 == strings[column] && abs(($0.1.frame?.midY ?? .infinity) - row.midY) < 2
            }?.1)
            let frame = try XCTUnwrap(value.frame)
            let bounds = try XCTUnwrap(value.ancestors.last { $0.type == "SwiftUI._FrameLayout" }?.frame)
            XCTAssertEqual(bounds.width, column == 2 ? 20 : columnWidth, accuracy: 0.5)
            XCTAssertEqual(bounds.minX, edge + CGFloat(column) * columnWidth, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(frame.minX + 0.5, bounds.minX)
            XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 0.5, "Each number stays inside its own column")
            if column < 2 {
                XCTAssertGreaterThanOrEqual(frame.width + 0.5, textWidth(strings[column], size: 11))
                XCTAssertEqual(frame.maxX, bounds.maxX, accuracy: 0.5, "Line numbers are right aligned")
            }
        }
        let body = try XCTUnwrap(labels.first {
            $0.0 == strings[3] && abs(($0.1.frame?.midY ?? .infinity) - row.midY) < 2
                && $0.1.ancestors.last { $0.type == "SwiftUI._FrameLayout" }?.frame.height == 18
        }?.1.frame)
        XCTAssertEqual(body.minX, textX, accuracy: 0.5, "Every row keeps one text column across hunks")
    }

    private func assertSidebarCell(_ cell: NSView, within sidebar: CGRect, file: PinnedSkillFileDiff, root: NSView) throws {
        let name = (file.path as NSString).lastPathComponent
        let values = RenderedViewTestSupport.layoutValues(in: cell)
        XCTAssertFalse(values.isEmpty, "A real list cell must have a live render tree")
        let icon = try XCTUnwrap(values.first { $0.value is Image && $0.hasOwnFrame }?.frame)
        XCTAssertLessThanOrEqual(cell.convert(icon, to: root).minX - sidebar.minX, 18)
        let filename = try text(name, in: cell)
        let added = try text("+1,234", in: cell), removed = try text("−1,234", in: cell)
        for (value, string) in [(added, "+1,234"), (removed, "−1,234")] {
            XCTAssertGreaterThanOrEqual(value.width + 0.5, textWidth(string, size: 11))
            XCTAssertGreaterThanOrEqual(value.minX, cell.bounds.minX)
            XCTAssertLessThanOrEqual(value.maxX, cell.bounds.maxX)
        }
        XCTAssertGreaterThanOrEqual(filename.width, 80)
        XCTAssertLessThanOrEqual(filename.maxX, added.minX)
        XCTAssertLessThan(added.maxX, removed.minX)
        XCTAssertLessThanOrEqual(sidebar.maxX - cell.convert(removed, to: root).maxX, 18)
        XCTAssertTrue(sidebar.contains(cell.convert(cell.bounds, to: root)))
        // The production row's actual proposal, not a roomy stand-in for the list cell.
        let rowValue = try XCTUnwrap(values.first {
            String(reflecting: type(of: $0.value)).hasPrefix("SwiftUI.HStack<")
                && rowStrings($0.value, depth: 20).contains(name)
        }?.frame)
        try assertRowInk(file, width: rowValue.width)
    }

    private func rowStrings(_ value: Any, depth: Int) -> [String] {
        if let text = value as? Text { return RenderedViewTestSupport.strings(in: text) }
        guard depth > 0, Mirror(reflecting: value).displayStyle != .class else { return [] }
        return Mirror(reflecting: value).children.flatMap { rowStrings($0.value, depth: depth - 1) }
    }

    private func splitView(_ review: PolishReview) throws -> NSSplitView {
        try XCTUnwrap(descendants(review.root).compactMap { $0 as? NSSplitView }
            .first { $0.isVertical && $0.arrangedSubviews.count == 2 })
    }

    private func expectSidebar(_ open: Bool, _ review: PolishReview) async throws {
        let split = try splitView(review)
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Sidebar should be \(open ? "open" : "closed")") {
            split.layoutSubtreeIfNeeded()
            return split.isSubviewCollapsed(split.arrangedSubviews[0]) != open
        }
        XCTAssertEqual(!split.isSubviewCollapsed(split.arrangedSubviews[0]), open)
    }

    private func toggleSidebar(_ review: PolishReview) throws {
        let split = try splitView(review)
        let controller = try XCTUnwrap(sequence(first: split.nextResponder, next: { $0?.nextResponder })
            .compactMap { $0 as? NSSplitViewController }.first)
        XCTAssertTrue(NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: controller, from: nil))
    }

    private func toolbarView(_ id: String, _ review: PolishReview) throws -> NSView {
        try XCTUnwrap(review.window.toolbar?.items.first { $0.itemIdentifier.rawValue.contains(id) }?.view)
    }

    private func text(_ string: String, in root: NSView) throws -> CGRect {
        try XCTUnwrap(textValue(string, in: root).frame)
    }

    private func textValue(_ string: String, in root: NSView) throws -> RenderedViewTestSupport.LayoutValue {
        let values = RenderedViewTestSupport.layoutValues(in: root)
        XCTAssertFalse(values.isEmpty, "Missing live render data while finding \(string)")
        return try XCTUnwrap(values.filter {
            guard let text = $0.value as? Text else { return false }
            return RenderedViewTestSupport.strings(in: text).contains(string) && ($0.frame?.width ?? 0) > 0
        }.max { left, right in
            (left.ancestors.map { $0.frame.width }.max() ?? 0) < (right.ancestors.map { $0.frame.width }.max() ?? 0)
        }, "Missing rendered text: \(string); " + values.compactMap { value in
            (value.value as? Text).map { "\(RenderedViewTestSupport.strings(in: $0)) \(value.frame as Any)" }
        }.joined(separator: "; "))
    }

    private func textWidth(_ string: String, size: CGFloat, monospaced: Bool = true) -> CGFloat {
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

}
