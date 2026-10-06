import AppKit
import SwiftUI

/// Read only the hosting sheet and its parent geometry, leaving native controls and appearance alone.
struct UpdatesSheetWindowSize: NSViewRepresentable {
    let onMeasure: (CGFloat) -> Void

    func makeNSView(context: Context) -> UpdatesSheetSizeView {
        let view = UpdatesSheetSizeView(frame: .zero)
        view.onMeasure = onMeasure
        return view
    }

    func updateNSView(_ view: UpdatesSheetSizeView, context: Context) {
        view.onMeasure = onMeasure
        view.measureAfterLayout()
    }
}

final class UpdatesSheetSizeView: NSView {
    var onMeasure: ((CGFloat) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        measureAfterLayout()
    }

    func measureAfterLayout() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let parent = window?.sheetParent else { return }
            onMeasure?(min(DesignTokens.mainWindowMinimumHeight, parent.contentLayoutRect.height))
        }
    }
}
