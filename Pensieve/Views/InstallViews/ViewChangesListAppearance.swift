import AppKit
import SwiftUI

/// Keep native List selection and accessibility while the measured row artwork paints its one fill.
struct ViewChangesListAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> ViewChangesListAppearanceView { ViewChangesListAppearanceView() }
    func updateNSView(_ view: ViewChangesListAppearanceView, context: Context) {}
}

final class ViewChangesListAppearanceView: NSView {
    private weak var configuredTable: NSTableView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.configureTable()
        }
    }

    private func configureTable() {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                guard table !== configuredTable else { return }
                table.selectionHighlightStyle = .none
                configuredTable = table
                return
            }
            ancestor = view.superview
        }
    }
}
