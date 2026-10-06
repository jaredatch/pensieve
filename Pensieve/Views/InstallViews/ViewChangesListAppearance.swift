import AppKit
import SwiftUI

/// Keep native List selection and accessibility while the measured row artwork paints its one fill.
struct ViewChangesListAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> ViewChangesListAppearanceView { ViewChangesListAppearanceView() }
    func updateNSView(_ view: ViewChangesListAppearanceView, context: Context) { view.configure() }
}

final class ViewChangesListAppearanceView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configure()
    }

    func configure() {
        DispatchQueue.main.async { [weak self] in
            guard let root = self?.window?.contentView else { return }
            Self.table(in: root)?.selectionHighlightStyle = .none
        }
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.table(in: $0) }.first
    }
}
