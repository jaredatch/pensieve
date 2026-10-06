import AppKit
import SwiftUI

/// Keep native List selection and accessibility while the measured row artwork paints its one fill.
struct ViewChangesListAppearance: NSViewRepresentable {
    let selection: String?
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> ViewChangesListAppearanceView { ViewChangesListAppearanceView() }
    func updateNSView(_ view: ViewChangesListAppearanceView, context: Context) {
        // These List/window changes must repair any style SwiftUI has reapplied.
        _ = selection
        _ = controlActiveState
        _ = colorScheme
        view.updateAppearance()
    }
}

final class ViewChangesListAppearanceView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func updateAppearance() {
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let table = self?.ownTable() else { return }
            // AppKit's plain style has no end padding; the row owns the frame's insets.
            if table.style != .plain { table.style = .plain }
            if table.intercellSpacing.width != 0 {
                table.intercellSpacing.width = 0
                table.sizeLastColumnToFit()
            }
            table.selectionHighlightStyle = .none
        }
    }

    private func ownTable() -> NSTableView? {
        var ancestor = superview
        while let view = ancestor, view !== window?.contentView {
            if let table = view as? NSTableView { return table }
            if let scroll = view as? NSScrollView { return scroll.documentView as? NSTableView }
            // A List background shares a local host with its scroll view, one wrapper deep.
            let scrolls = view.subviews.flatMap { [$0] + $0.subviews }.compactMap { $0 as? NSScrollView }
            if scrolls.count == 1 { return scrolls[0].documentView as? NSTableView }
            ancestor = view.superview
        }
        return nil
    }
}
