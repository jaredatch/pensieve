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
            // LocalizedTextStorage's debug description includes its resolved, formatted text.
            if String(reflecting: type(of: value)).hasSuffix("LocalizedTextStorage"),
               let key = Mirror(reflecting: value).descendant("key", "key") as? String, key.contains("%") {
                let description = String(describing: value)
                if let start = description.range(of: ">: \""), description.hasSuffix("\"") {
                    return [String(description[start.upperBound...].dropLast())]
                }
            }
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
        let controlSize: ControlSize?
        let keyboardShortcut: KeyboardShortcut?
        let ancestors: [(type: String, frame: CGRect)]
    }

    /// SwiftUI puts geometry on layout-owning nodes; their transparent descendants share it.
    /// Scroll content uses its viewport's origin; nested AppKit hosts need conversion to the root.
    /// Keep measured ancestor frames so callers can find a text's actual row or column bounds.
    static func layoutValues(in root: NSView) -> [LayoutValue] {
        root.layoutSubtreeIfNeeded()
        struct Context {
            var frame: CGRect?
            var scrollOrigin: CGPoint = .zero
            var scrollViewport: CGRect?
            var environment: EnvironmentValues?
            var ancestors: [(type: String, frame: CGRect)] = []
        }
        func walk(_ nodes: [_ViewDebug.Data], in host: NSView, context: Context) -> [LayoutValue] {
            nodes.flatMap { node -> [LayoutValue] in
                let mirror = Mirror(reflecting: node)
                let properties = mirror.descendant("data") as? [_ViewDebug.Property: Any] ?? [:]
                var next = context
                let valueType = properties[.value].map { String(reflecting: type(of: $0)) }
                // Scroll content positions start again at zero within the live viewport.
                if valueType?.hasPrefix("SwiftUI.SystemScrollViewContainer<") == true,
                   let viewport = context.scrollViewport {
                    next.scrollOrigin = root.convert(viewport, to: host).origin
                }
                let ownFrame: CGRect?
                if let position = properties[.position] as? CGPoint, let size = properties[.size] as? CGSize {
                    let origin = CGPoint(x: position.x + next.scrollOrigin.x, y: position.y + next.scrollOrigin.y)
                    ownFrame = host.convert(CGRect(origin: origin, size: size), to: root)
                } else {
                    ownFrame = nil
                }
                next.frame = ownFrame ?? context.frame
                if valueType?.hasPrefix("SwiftUI.SystemScrollView<") == true {
                    next.scrollViewport = next.frame
                }
                next.environment = properties[.environment] as? EnvironmentValues ?? context.environment
                let value = properties[.value].map { value in
                    LayoutValue(value: value, frame: next.frame, hasOwnFrame: ownFrame != nil,
                        isEnabled: next.environment?.isEnabled, controlSize: next.environment?.controlSize,
                        keyboardShortcut: next.environment?.keyboardShortcut, ancestors: context.ancestors)
                }
                if let frame = next.frame, let valueType {
                    next.ancestors.append((String(valueType.prefix { $0 != "<" }), frame))
                }
                let children = mirror.descendant("childData") as? [_ViewDebug.Data] ?? []
                return (value.map { [$0] } ?? []) + walk(children, in: host, context: next)
            }
        }

        func hosts(_ view: NSView) -> [LayoutValue] {
            walk((view as? RenderedTestHost)?.renderedTestData ?? [], in: view, context: Context())
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
