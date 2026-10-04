import AppKit
import XCTest
@testable import Pensieve

@MainActor
final class SidebarOutlineControllerTests: XCTestCase {
    func testApplyBuildsRowsInOrder() {
        let (controller, window) = makeController()
        let titles = ["Skills", "Projects", "Categories", "Tags", "Machines"]

        XCTAssertEqual(controller.outlineView.numberOfRows, 5)
        for (row, title) in titles.enumerated() {
            XCTAssertEqual(cell(controller, row: row)?.textField?.stringValue, title)
            XCTAssertNotNil(cell(controller, row: row)?.imageView?.image)
        }
        withExtendedLifetime(window) {}
    }

    func testUserSelectionReportsSection() {
        let (controller, window) = makeController()
        var selections: [SidebarSection] = []
        controller.onSelect = { selections.append($0) }

        controller.outlineView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        XCTAssertEqual(selections, [.categories])
        XCTAssertEqual(controller.selectedSection, .categories)
        withExtendedLifetime(window) {}
    }

    func testProgrammaticSelectDoesNotEcho() {
        let (controller, window) = makeController()
        var selections: [SidebarSection] = []
        controller.onSelect = { selections.append($0) }

        controller.select(.tags)

        XCTAssertEqual(controller.outlineView.selectedRow, 3)
        XCTAssertTrue(selections.isEmpty)

        controller.select(.tags)

        XCTAssertEqual(controller.outlineView.selectedRow, 3)
        XCTAssertTrue(selections.isEmpty)
        withExtendedLifetime(window) {}
    }

    func testApplySameSectionsKeepsObjectsAndSelection() {
        let (controller, window) = makeController()
        controller.select(.projects)
        let captured = controller.items[1]
        var selections: [SidebarSection] = []
        controller.onSelect = { selections.append($0) }

        controller.apply(items: makeItems(), selection: .projects)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.items[1] === captured)
        XCTAssertEqual(controller.outlineView.selectedRow, 1)
        XCTAssertTrue(selections.isEmpty)
    }

    func testApplyNewSectionsReloadsAndReappliesSelection() {
        let (controller, window) = makeController()
        var selections: [SidebarSection] = []
        controller.onSelect = { selections.append($0) }

        controller.apply(items: makeItems(showsMachines: false), selection: .tags)

        XCTAssertEqual(controller.outlineView.numberOfRows, 4)
        XCTAssertEqual(controller.outlineView.selectedRow, 3)

        controller.apply(items: makeItems(), selection: .tags)

        XCTAssertEqual(controller.outlineView.numberOfRows, 5)
        XCTAssertEqual(controller.outlineView.selectedRow, 3)
        XCTAssertTrue(selections.isEmpty)
        withExtendedLifetime(window) {}
    }

    func testSelectUnknownSectionLeavesSelection() {
        let (controller, window) = makeController()
        controller.select(.projects)
        var selections: [SidebarSection] = []
        controller.onSelect = { selections.append($0) }

        controller.apply(items: makeItems(showsMachines: false), selection: .machines)

        XCTAssertEqual(controller.outlineView.numberOfRows, 4)
        XCTAssertEqual(controller.selectedSection, .projects)
        XCTAssertTrue(selections.isEmpty)
        withExtendedLifetime(window) {}
    }

    func testMachinesRemovedWhileSelectedConvergesWithoutEcho() {
        let (controller, window) = makeController()
        controller.select(.machines)
        XCTAssertEqual(controller.outlineView.selectedRow, 4)
        var selections: [SidebarSection] = []
        controller.onSelect = { selections.append($0) }

        controller.apply(items: makeItems(showsMachines: false), selection: .machines)

        XCTAssertEqual(controller.outlineView.numberOfRows, 4)
        XCTAssertTrue(selections.isEmpty)
        XCTAssertNotNil(controller.selectedSection)
        XCTAssertTrue(controller.items.contains { $0.section == controller.selectedSection })

        controller.apply(items: makeItems(showsMachines: false), selection: .skills)

        XCTAssertEqual(controller.outlineView.selectedRow, 0)
        XCTAssertEqual(controller.selectedSection, .skills)
        XCTAssertTrue(selections.isEmpty)
        withExtendedLifetime(window) {}
    }

    func testFreshControllerAppliesBindingWithoutEcho() {
        let controller = SidebarOutlineController()
        let window = makeWindow(hosting: controller)
        var selections: [SidebarSection] = []
        controller.onSelect = { selections.append($0) }

        controller.apply(items: makeItems(), selection: .tags)

        XCTAssertEqual(controller.outlineView.selectedRow, 3)
        XCTAssertTrue(selections.isEmpty)
        withExtendedLifetime(window) {}
    }
}

extension SidebarOutlineControllerTests {
    func testCellFollowsRowSizeStyle() {
        let (controller, window) = makeController()
        let expectations = [
            RowSizeExpectation(style: .small, fontSize: 11, rowHeight: 24),
            RowSizeExpectation(style: .medium, fontSize: 13, rowHeight: 32),
            RowSizeExpectation(style: .large, fontSize: 15, rowHeight: 40)
        ]
        var imageSizes: [NSSize] = []

        for expectation in expectations {
            controller.outlineView.rowSizeStyle = expectation.style
            controller.outlineView.reloadData()
            window.contentView?.layoutSubtreeIfNeeded()
            let rowCell = cell(controller, row: 0)

            XCTAssertEqual(rowCell?.textField?.font?.pointSize, expectation.fontSize)
            XCTAssertEqual(controller.outlineView.rowHeight, expectation.rowHeight)
            let imageSize = rowCell?.imageView?.frame.size ?? .zero
            XCTAssertGreaterThan(imageSize.width, 0)
            XCTAssertGreaterThan(imageSize.height, 0)
            imageSizes.append(imageSize)
        }

        XCTAssertGreaterThan(imageSizes[1].width, imageSizes[0].width)
        XCTAssertGreaterThan(imageSizes[2].width, imageSizes[1].width)
        XCTAssertGreaterThan(imageSizes[1].height, imageSizes[0].height)
        XCTAssertGreaterThan(imageSizes[2].height, imageSizes[1].height)
    }

    func testTypeSelectStringUsesItemTitle() {
        let (controller, window) = makeController()

        for item in controller.items {
            let title = controller.outlineView(
                controller.outlineView,
                typeSelectStringFor: nil,
                item: item
            )
            XCTAssertEqual(title, item.title)
        }
        XCTAssertNil(controller.outlineView(
            controller.outlineView,
            typeSelectStringFor: nil,
            item: NSObject()
        ))
        withExtendedLifetime(window) {}
    }

    func testOutlineDrawsNoBackground() {
        let (controller, window) = makeController()

        XCTAssertEqual(controller.outlineView.backgroundColor, .clear)
        XCTAssertFalse(controller.scrollView.drawsBackground)
        withExtendedLifetime(window) {}
    }

    func testRowsFactoryOrderAndSymbols() {
        let items = SidebarRows.items(showsMachines: true)
        let expected = [
            RowExpectation(section: .skills, title: "Skills", symbol: "tray"),
            RowExpectation(section: .projects, title: "Projects", symbol: "folder"),
            RowExpectation(section: .categories, title: "Categories", symbol: "square.stack"),
            RowExpectation(section: .tags, title: "Tags", symbol: "tag"),
            RowExpectation(section: .machines, title: "Machines", symbol: "display")
        ]

        XCTAssertEqual(items.count, expected.count)
        for (item, expectedRow) in zip(items, expected) {
            XCTAssertEqual(item.section, expectedRow.section)
            XCTAssertEqual(item.title, expectedRow.title)
            XCTAssertEqual(item.symbol, expectedRow.symbol)
        }
    }

    func testRowsFactoryOmitsMachinesWhenHidden() {
        let items = SidebarRows.items(showsMachines: false)

        XCTAssertEqual(items.map(\.section), [.skills, .projects, .categories, .tags])
        XCTAssertFalse(items.contains { $0.section == .machines })
    }
}

private struct RowSizeExpectation {
    let style: NSTableView.RowSizeStyle
    let fontSize: CGFloat
    let rowHeight: CGFloat
}

private struct RowExpectation {
    let section: SidebarSection
    let title: String
    let symbol: String
}

private extension SidebarOutlineControllerTests {
    func makeController() -> (controller: SidebarOutlineController, window: NSWindow) {
        let controller = SidebarOutlineController()
        let window = makeWindow(hosting: controller)
        controller.apply(items: makeItems(), selection: .skills)
        window.contentView?.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    func makeWindow(hosting controller: SidebarOutlineController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.scrollView
        return window
    }

    func cell(_ controller: SidebarOutlineController, row: Int) -> SidebarOutlineCell? {
        controller.scrollView.window?.contentView?.layoutSubtreeIfNeeded()
        let rowCell = controller.outlineView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: true
        ) as? SidebarOutlineCell
        controller.scrollView.window?.contentView?.layoutSubtreeIfNeeded()
        return rowCell
    }

    func makeItems(showsMachines: Bool = true) -> [SidebarOutlineItem] {
        var items = [
            SidebarOutlineItem(section: .skills, title: "Skills", symbol: "tray"),
            SidebarOutlineItem(section: .projects, title: "Projects", symbol: "folder"),
            SidebarOutlineItem(section: .categories, title: "Categories", symbol: "square.stack"),
            SidebarOutlineItem(section: .tags, title: "Tags", symbol: "tag")
        ]
        if showsMachines {
            items.append(SidebarOutlineItem(section: .machines, title: "Machines", symbol: "display"))
        }
        return items
    }
}
