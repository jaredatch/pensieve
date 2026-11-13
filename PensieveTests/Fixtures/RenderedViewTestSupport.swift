import AppKit
import SwiftUI

@MainActor
enum RenderedViewTestSupport {
    /// Observe the enabled environment delivered to a real button in a test host.
    struct AvailabilityStyle: PrimitiveButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        func makeBody(configuration: Configuration) -> some View {
            DefaultButtonStyle().makeBody(configuration: configuration)
                .background(HStack {
                    configuration.label
                    Text(isEnabled ? "__enabled_control__" : "__disabled_control__")
                }.hidden())
        }
    }

    /// The hidden probe renders its own label followed by its enabled environment. Read that
    /// pair across the live nested AppKit label hosts; never substitute another button's state.
    static func buttonIsEnabled(_ title: String, in host: NSHostingView<AnyView>) -> Bool? {
        let labels = values(in: host).compactMap { $0 as? Text }.flatMap { strings(in: $0) }
        for (label, state) in zip(labels, labels.dropFirst()) where label == title {
            if state == "__disabled_control__" { return false }
            if state == "__enabled_control__" { return true }
        }
        return nil
    }

    static func strings(in text: Text) -> [String] {
        func strings(_ value: Any, depth: Int) -> [String] {
            if let text = value as? AttributedString { return [String(text.characters)] }
            if let text = value as? NSAttributedString { return [text.string] }
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
    static func values(in host: NSView) -> [Any] {
        nodes(in: host).compactMap { node in
            let properties = Mirror(reflecting: node).descendant("data") as? [_ViewDebug.Property: Any]
            return properties?[.value]
        }
    }

    struct LayoutValue {
        let value: Any
        let frame: CGRect?
        let hasOwnFrame: Bool
        let isEnabled: Bool?
    }

    /// SwiftUI puts geometry on layout-owning nodes; their transparent descendants share it.
    /// Positions are host-relative origins. Convert nested AppKit label hosts into the root's
    /// coordinates so a native button title can be compared with a SwiftUI label.
    static func layoutValues(in root: NSView) -> [LayoutValue] {
        root.layoutSubtreeIfNeeded()
        func walk(_ nodes: [_ViewDebug.Data], in host: NSView, inherited: CGRect?, enabled: Bool?) -> [LayoutValue] {
            nodes.flatMap { node -> [LayoutValue] in
                let mirror = Mirror(reflecting: node)
                let properties = mirror.descendant("data") as? [_ViewDebug.Property: Any] ?? [:]
                let ownFrame: CGRect?
                if let position = properties[.position] as? CGPoint, let size = properties[.size] as? CGSize {
                    ownFrame = host.convert(CGRect(origin: position, size: size), to: root)
                } else {
                    ownFrame = nil
                }
                let frame = ownFrame ?? inherited
                let isEnabled = (properties[.environment] as? EnvironmentValues)?.isEnabled ?? enabled
                let value = properties[.value].map {
                    LayoutValue(value: $0, frame: frame, hasOwnFrame: ownFrame != nil, isEnabled: isEnabled)
                }
                let children = mirror.descendant("childData") as? [_ViewDebug.Data] ?? []
                return (value.map { [$0] } ?? []) + walk(children, in: host, inherited: frame, enabled: isEnabled)
            }
        }
        func hosts(_ view: NSView) -> [LayoutValue] {
            walk((view as? RenderedTestHost)?.renderedTestData ?? [], in: view, inherited: nil, enabled: nil)
                + view.subviews.flatMap(hosts)
        }
        return hosts(root)
    }

    static func nodes(in host: NSView) -> [_ViewDebug.Data] {
        host.layoutSubtreeIfNeeded()
        func flatten(_ nodes: [_ViewDebug.Data]) -> [_ViewDebug.Data] {
            nodes.flatMap { [$0] + flatten(Mirror(reflecting: $0).descendant("childData") as? [_ViewDebug.Data] ?? []) }
        }
        func hostNodes(_ view: NSView) -> [_ViewDebug.Data] {
            flatten((view as? RenderedTestHost)?.renderedTestData ?? []) + view.subviews.flatMap(hostNodes)
        }
        return hostNodes(host)
    }

    static func hasButtonProgress(in host: NSHostingView<AnyView>) -> Bool {
        func containsProgress(_ nodes: [_ViewDebug.Data], insideButton: Bool) -> Bool {
            nodes.contains { node in
                let mirror = Mirror(reflecting: node)
                let properties = mirror.descendant("data") as? [_ViewDebug.Property: Any] ?? [:]
                let valueType = properties[.value].map { String(reflecting: type(of: $0)) } ?? ""
                let button = insideButton || valueType.hasPrefix("SwiftUI.Button<")
                if button && valueType.hasPrefix("SwiftUI.ProgressView<") { return true }
                return containsProgress(mirror.descendant("childData") as? [_ViewDebug.Data] ?? [], insideButton: button)
            }
        }
        host.layoutSubtreeIfNeeded()
        func hasProgress(in view: NSView) -> Bool {
            let nodes = (view as? RenderedTestHost)?.renderedTestData ?? []
            return containsProgress(nodes, insideButton: false) || view.subviews.contains { hasProgress(in: $0) }
        }
        return hasProgress(in: host)
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
