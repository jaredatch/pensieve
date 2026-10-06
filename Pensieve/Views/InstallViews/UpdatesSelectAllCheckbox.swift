import AppKit
import SwiftUI

/// A stock checkbox exposes the presentation's three states without styling native internals.
struct UpdatesSelectAllCheckbox: NSViewRepresentable {
    let title: String
    let selection: UpdatesSheetPresentation.Selection
    let isEnabled: Bool
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        button.allowsMixedState = true
        button.font = DesignTokens.updatesCheckboxFont
        button.setAccessibilityIdentifier("updates-select-all")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.isEnabled = isEnabled
        switch selection {
        case .unchecked: button.state = .off
        case .mixed: button.state = .mixed
        case .checked: button.state = .on
        }
        context.coordinator.selection = selection
        context.coordinator.onChange = onChange
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    final class Coordinator: NSObject {
        var selection: UpdatesSheetPresentation.Selection = .unchecked
        var onChange: (Bool) -> Void
        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
        @objc func changed(_ sender: NSButton) { onChange(selection != .checked) }
    }
}
