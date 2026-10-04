import AppKit
import SwiftUI

/// One sidebar row. A class because NSOutlineView keys rows by Objective-C object identity: a
/// bridged Swift struct is boxed afresh on every data-source call, identity never matches, and
/// AppKit logs "Obj-C `-hash` invoked on a Swift value … severe performance problems". The
/// controller keeps these objects across updates and mutates `title` in place, because a
/// row reload re-requests the cell for the outline's cached item.
final class SidebarOutlineItem: NSObject {
    let section: SidebarSection
    var title: String
    let symbol: String

    init(section: SidebarSection, title: String, symbol: String) {
        self.section = section
        self.title = title
        self.symbol = symbol
    }
}

/// The sidebar as the control Finder's sidebar is made of: an NSOutlineView in `.sourceList`
/// style. Selection appearance (emphasized accent fill; otherwise a light pill with the icon and
/// title tinted accent, in inactive windows too), row height, icon size, and text size are all
/// AppKit's and follow System Settings › Appearance › Sidebar icon size via `rowSizeStyle =
/// .default`. Flat, single-selection, no empty selection. `SidebarOutline` is the SwiftUI wrapper.
@MainActor
final class SidebarOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scrollView = NSScrollView()
    let outlineView = NSOutlineView()
    private(set) var items: [SidebarOutlineItem] = []
    /// Fired for a USER selection change (click, arrow keys). Never fired by `select(_:)`.
    var onSelect: ((SidebarSection) -> Void)?
    private var isApplyingSelection = false
    private let cellIdentifier = NSUserInterfaceItemIdentifier("SidebarOutlineCell")

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        // The source-list look. `selectionHighlightStyle = .sourceList` is this property's
        // macOS 11 predecessor and is deprecated; do not set both.
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = 0
        outlineView.allowsEmptySelection = false
        outlineView.allowsMultipleSelection = false
        outlineView.focusRingType = .none
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // The sidebar column's vibrancy is drawn by SwiftUI behind this view; the outline's default
        // opaque control background would cover it, so both layers must not draw.
        outlineView.backgroundColor = .clear
        outlineView.setAccessibilityLabel("Sidebar")
        outlineView.dataSource = self
        outlineView.delegate = self
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
    }

    /// Replace the rows, then mirror `selection`. Same sections in the same order: the existing
    /// item objects are kept, their title updated in place, and only changed rows are
    /// reloaded (selection kept, no flicker). A different section list: full reload, and a
    /// `selection` the new rows lack keeps the previously selected row instead. Idempotent.
    func apply(items newItems: [SidebarOutlineItem], selection: SidebarSection?) {
        let previousSelection = selectedSection
        if newItems.map(\.section) == items.map(\.section) {
            var changed = IndexSet()
            for (index, new) in newItems.enumerated() {
                let old = items[index]
                if old.title != new.title {
                    old.title = new.title
                    changed.insert(index)
                }
            }
            if !changed.isEmpty {
                outlineView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            }
        } else {
            items = newItems
            // A full reload auto-selects row 0 (empty selection is disallowed) and posts the
            // selection notification from inside reloadData — outside `select`'s guard. Without
            // this flag the Machines row appearing or disappearing would report `.skills` to the
            // binding (probed headless 2026-09-05; the machines-removed test pins it).
            isApplyingSelection = true
            outlineView.reloadData()
            isApplyingSelection = false
        }
        // Asked for a section the new rows lack (SwiftUI's first body after Machines vanished,
        // before ContentView re-routes): keep the row the user had, if it survived; if it was
        // the vanished row itself, AppKit's post-reload fallback (row 0) stands.
        if let selection, !items.contains(where: { $0.section == selection }) {
            select(previousSelection)
        } else {
            select(selection)
        }
    }

    /// Programmatic selection: mirrors SwiftUI state into the outline WITHOUT firing `onSelect`.
    /// `selectRowIndexes` posts the selection-changed notification synchronously for programmatic
    /// changes too, so the flag is what keeps a SwiftUI update from echoing into the binding.
    func select(_ section: SidebarSection?) {
        guard let section, let row = items.firstIndex(where: { $0.section == section }) else { return }
        guard outlineView.selectedRow != row else { return }
        isApplyingSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isApplyingSelection = false
    }

    var selectedSection: SidebarSection? {
        let row = outlineView.selectedRow
        return items.indices.contains(row) ? items[row].section : nil
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? items.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarOutlineItem else { return nil }
        let cell = (outlineView.makeView(withIdentifier: cellIdentifier, owner: nil) as? SidebarOutlineCell)
            ?? SidebarOutlineCell(identifier: cellIdentifier)
        cell.configure(with: item)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let section = selectedSection else { return }
        onSelect?(section)
    }

    /// Type-select (typing "Pr" jumps to Projects) is on by default, but a view-based outline has
    /// no cell to read the string from, so AppKit asks the delegate; without this it matches nothing.
    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?,
                     item: Any) -> String? {
        (item as? SidebarOutlineItem)?.title
    }
}

/// Frame-based cell. With `imageView`/`textField` set as outlets and NO Auto Layout constraints,
/// NSTableCellView sizes the icon, picks the symbol configuration, and sets the text font for the
/// outline's `rowSizeStyle` on its own (probed headless 2026-09-05: small 11pt on a 24pt row,
/// medium 13pt/32pt, large 15pt/40pt), and AppKit tints both outlets accent on an unemphasized
/// selected row.
final class SidebarOutlineCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        addSubview(image)
        addSubview(text)
        imageView = image
        textField = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SidebarOutlineCell is code-only") }

    func configure(with item: SidebarOutlineItem) {
        // Monochrome on purpose: macOS 26 renders some symbols (`display`) hierarchically by default,
        // a filled gray screen beside five outline glyphs; Finder's sidebar glyphs are one weight.
        imageView?.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)?
            .withSymbolConfiguration(.preferringMonochrome())
        textField?.stringValue = item.title
    }
}

/// The row descriptions in the shipped order, Machines only when `showsMachines`.
/// Pure, so the section/title/symbol mapping is testable apart from `SidebarView`.
enum SidebarRows {
    static func items(showsMachines: Bool) -> [SidebarOutlineItem] {
        var rows = [
            SidebarOutlineItem(section: .skills, title: "Skills", symbol: "tray"),
            SidebarOutlineItem(section: .projects, title: "Projects", symbol: "folder"),
            SidebarOutlineItem(section: .categories, title: "Categories", symbol: "square.stack"),
            SidebarOutlineItem(section: .tags, title: "Tags", symbol: "tag")
        ]
        if showsMachines {
            rows.append(SidebarOutlineItem(section: .machines, title: "Machines", symbol: "display"))
        }
        return rows
    }
}

/// SwiftUI host for the AppKit sidebar. The controller is the coordinator; `items` are rebuilt by
/// SwiftUI on every body evaluation and reconciled by `apply`, which keeps the outline's own
/// objects when the sections match. The binding is written only from a user selection.
struct SidebarOutline: NSViewRepresentable {
    let items: [SidebarOutlineItem]
    @Binding var selection: SidebarSection?

    func makeCoordinator() -> SidebarOutlineController { SidebarOutlineController() }

    func makeNSView(context: Context) -> NSScrollView {
        wire(context.coordinator)
        return context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        wire(context.coordinator)
    }

    private func wire(_ controller: SidebarOutlineController) {
        let binding = $selection
        controller.onSelect = { section in
            if binding.wrappedValue != section { binding.wrappedValue = section }
        }
        controller.apply(items: items, selection: selection)
    }
}
