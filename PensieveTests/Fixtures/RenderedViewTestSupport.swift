import AppKit
import SwiftUI

@MainActor
enum RenderedViewTestSupport {
    static func strings(in text: Text) -> [String] {
        func strings(_ value: Any, depth: Int) -> [String] {
            if let string = value as? String {
                // SwiftUI's render debug values escape apostrophes in their text payloads.
                return [string.replacingOccurrences(of: "\\'", with: "'")]
            }
            guard depth > 0 else { return [] }
            return Mirror(reflecting: value).children.flatMap { strings($0.value, depth: depth - 1) }
        }
        return Mirror(reflecting: text).descendant("storage").map { strings($0, depth: 8) } ?? []
    }

    /// Read NSHostingView's live render tree. SWIFTUI_VIEW_DEBUG is enabled by the suite wrapper.
    /// Inspect only rendered values/children; never evaluate a new body or substitute model state.
    /// Missing debug data or changed SDK fields fail the owning UI assertions instead of passing empty.
    static func values(in host: NSHostingView<AnyView>) -> [Any] {
        host.layoutSubtreeIfNeeded()
        func values(_ nodes: [_ViewDebug.Data]) -> [Any] {
            nodes.flatMap { node in
                let mirror = Mirror(reflecting: node)
                let properties = mirror.descendant("data") as? [_ViewDebug.Property: Any]
                let children = mirror.descendant("childData") as? [_ViewDebug.Data] ?? []
                return [properties?[.value]].compactMap { $0 } + values(children)
            }
        }
        func hostValues(_ view: NSView) -> [Any] {
            let nodes = (view as? RenderedTestHost)?.renderedTestData ?? []
            return values(nodes) + view.subviews.flatMap(hostValues)
        }
        return hostValues(host)
    }

}

// List cells host their own SwiftUI graphs with different generic root types. Inspect each
// existing host through this test-local adapter; it adds no production hook or model fallback.
private protocol RenderedTestHost {
    var renderedTestData: [_ViewDebug.Data] { get }
}

extension NSHostingView: RenderedTestHost {
    fileprivate var renderedTestData: [_ViewDebug.Data] { _viewDebugData() }
}
