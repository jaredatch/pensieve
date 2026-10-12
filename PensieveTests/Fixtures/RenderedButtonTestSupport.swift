import AppKit
import SwiftUI
import XCTest

/// Captures each rendered Button's public configuration and enabled environment, matched to its
/// label through a hidden per-instance marker in the live debug tree. It never evaluates a fresh
/// body or reflects an action. Native pointer/AX dispatch and visual fidelity remain manual checks.
@MainActor
final class RenderedButtonTestSupport {
    struct CapturedButton {
        let configuration: PrimitiveButtonStyleConfiguration
        let enabled: Bool
    }
    private var buttons: [String: CapturedButton] = [:]
    var style: some PrimitiveButtonStyle { ProbeStyle(owner: self) }
    func clear() { buttons.removeAll() }

    func button(titled title: String, in root: NSView) async throws -> CapturedButton {
        var found: CapturedButton?
        await TestWait.until(failureMessage: "Rendered '\(title)' button did not appear", diagnostics: {
            "captured buttons=\(self.buttons.count)"
        }, {
            root.layoutSubtreeIfNeeded()
            found = self.findButton(title, in: root)
            return found != nil
        })
        return try XCTUnwrap(found)
    }

    private func findButton(_ title: String, in view: NSView) -> CapturedButton? {
        func children(_ node: _ViewDebug.Data) -> [_ViewDebug.Data] {
            Mirror(reflecting: node).descendant("childData") as? [_ViewDebug.Data] ?? []
        }
        func value(_ node: _ViewDebug.Data) -> Any? {
            (Mirror(reflecting: node).descendant("data") as? [_ViewDebug.Property: Any])?[.value]
        }
        func texts(_ nodes: [_ViewDebug.Data]) -> [String] {
            nodes.flatMap { node in
                (value(node) as? Text).map(RenderedViewTestSupport.strings) ?? []
            } + nodes.flatMap { texts(children($0)) }
        }
        func find(_ nodes: [_ViewDebug.Data]) -> CapturedButton? {
            for node in nodes {
                if let found = find(children(node)) { return found }
                let labels = texts(children(node))
                let records = labels.compactMap { self.buttons[$0] }
                if labels.contains(title), records.count == 1 {
                    return records.first
                }
            }
            return nil
        }
        if let found = find((view as? RenderedButtonHost)?.renderedButtonData ?? []) { return found }
        return view.subviews.lazy.compactMap { self.findButton(title, in: $0) }.first
    }

    private struct ProbeStyle: PrimitiveButtonStyle {
        let owner: RenderedButtonTestSupport
        @Environment(\.isEnabled) private var enabled
        func makeBody(configuration: Configuration) -> some View {
            ProbeContent(configuration: configuration, enabled: enabled, owner: owner)
        }
    }

    private struct ProbeContent: View {
        let configuration: PrimitiveButtonStyleConfiguration
        let enabled: Bool
        let owner: RenderedButtonTestSupport
        @State private var marker = UUID().uuidString
        var body: some View {
            DefaultButtonStyle().makeBody(configuration: configuration)
                .background { Text(marker).hidden().accessibilityHidden(true) }
                .onAppear { record() }
                .onChange(of: enabled) { _, _ in record() }
        }
        private func record() { owner.buttons[marker] = CapturedButton(configuration: configuration, enabled: enabled) }
    }
}

private protocol RenderedButtonHost { var renderedButtonData: [_ViewDebug.Data] { get } }
extension NSHostingView: RenderedButtonHost {
    fileprivate var renderedButtonData: [_ViewDebug.Data] { _viewDebugData() }
}
